[CmdletBinding()]
param(
    [string]$RootPath,
    [switch]$Repair,
    [switch]$NoState,
    [string]$ReportOut
)

$ErrorActionPreference = 'Stop'
$VideoExtensions = @('.mp4','.mov','.mkv','.m4v','.avi','.insv','.lrv')
$RepoRoot = Split-Path -Parent $PSScriptRoot
$FFprobe = (Get-Command ffprobe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $FFprobe) {
    foreach ($candidate in @('C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffprobe.exe','C:\ffmpeg\ffprobe.exe')) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $FFprobe = $candidate; break }
    }
}
if (-not $FFprobe) { throw 'No se encontro ffprobe; no es posible validar los videos.' }
if ($Repair -and $NoState) { throw 'NoState es solo para auditorias de lectura; no puede combinarse con Repair.' }

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Read-Host 'Ruta raiz que contiene los proyectos'
}
$RootPath = $RootPath.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) { throw "La ruta no existe: $RootPath" }
$RootPath = (Get-Item -LiteralPath $RootPath).FullName

if (-not $ReportOut) {
    $logDir = Join-Path $RepoRoot 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $ReportOut = Join-Path $logDir ("integridad_proxies_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
}

$results = [Collections.Generic.List[object]]::new()
$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function Get-MediaFiles([string]$Path, [bool]$Recurse = $true) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -File -Recurse:$Recurse -ErrorAction SilentlyContinue | Where-Object {
        $VideoExtensions -contains $_.Extension.ToLowerInvariant()
    })
}

function Get-RelativePath([string]$Base, [string]$Path) {
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ($pathFull.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $pathFull.Substring($baseFull.Length)
    }
    return [IO.Path]::GetFileName($pathFull)
}

function New-SourceRecord([IO.FileInfo]$File, [string]$ProjectPath, [string]$Alias) {
    [pscustomobject]@{
        Path = Get-RelativePath $ProjectPath $File.FullName
        Alias = $Alias
        Length = [long]$File.Length
        LastWriteUtc = $File.LastWriteTimeUtc.ToString('o')
    }
}

function Test-MediaFile([string]$Path) {
    try {
        $previousPreference=$ErrorActionPreference
        $ErrorActionPreference='Continue'
        try{
            $json = & $FFprobe -v error -select_streams v:0 -show_entries 'stream=index,duration:format=duration' -of json -- $Path 2>$null
            $probeCode=$LASTEXITCODE
        }finally{$ErrorActionPreference=$previousPreference}
        if ($probeCode -ne 0 -or -not $json) { throw 'ffprobe no pudo leer el archivo.' }
        $data = $json | ConvertFrom-Json
        if (@($data.streams).Count -eq 0) { throw 'No contiene una pista de video.' }
        $durationText = if (@($data.streams)[0].duration) { @($data.streams)[0].duration } else { $data.format.duration }
        $duration = 0.0
        if (-not [double]::TryParse([string]$durationText, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$duration) -or $duration -le 0) {
            throw 'La duracion no es valida.'
        }
        return [pscustomobject]@{ Valid=$true; Duration=$duration; Error='' }
    } catch {
        return [pscustomobject]@{ Valid=$false; Duration=0.0; Error=$_.Exception.Message }
    }
}

function New-FinalGroup([string]$Path, [object[]]$Parts, [int]$ExpectedCount) {
    [pscustomobject]@{ Path=$Path; Parts=@($Parts); ExpectedCount=$ExpectedCount }
}

function New-CameraProfile([string]$Id, [string]$Name, [string]$ProjectPath,
    [object[]]$SourceRecords, [string[]]$ProxyRoots, [object[]]$FinalGroups) {
    [pscustomobject]@{
        Id=$Id; Name=$Name; ProjectPath=$ProjectPath
        Sources=@($SourceRecords | Sort-Object Path)
        ProxyRoots=@($ProxyRoots | Where-Object { $_ })
        FinalGroups=@($FinalGroups)
    }
}

function Get-Profiles([IO.DirectoryInfo]$Project) {
    $profiles = [Collections.Generic.List[object]]::new()
    $p = $Project.FullName
    $projectName = $Project.Name
    $stateRoot = Join-Path $p '.proxy-integrity'
    function Test-KnownCamera([string]$CameraId) {
        return Test-Path -LiteralPath (Join-Path $stateRoot ($CameraId + '.json')) -PathType Leaf
    }

    $vuze = Join-Path $p '100VUZXR'
    $vuzeSources = @(Get-MediaFiles $vuze $false | Where-Object Extension -ieq '.mp4')
    if ($vuzeSources.Count -or (Test-KnownCamera 'CAM-01')) {
        $proxyRoot = Join-Path $vuze 'Proxy VUZE RAW'
        $records = @($vuzeSources | ForEach-Object { New-SourceRecord $_ $p $_.BaseName })
        $parts = @(Get-MediaFiles $proxyRoot $true | Where-Object Name -like '* VuzeRawProxy.mp4')
        $groups = @(New-FinalGroup (Join-Path $p "$projectName VUZE RAW PROXY Complete.mp4") $parts $vuzeSources.Count)
        $profiles.Add((New-CameraProfile 'CAM-01' 'VUZE' $p $records @($proxyRoot) $groups))
    }

    $qoo = Join-Path $p '100QOOCAM'
    $qooInput = Join-Path $qoo 'KDOutput'
    $qooSources = @(Get-MediaFiles $qooInput $true)
    if ($qooSources.Count -or (Test-KnownCamera 'CAM-02')) {
        $proxyRoot = Join-Path $qoo 'Proxies'; $rightRoot = Join-Path $qoo 'Right25'
        $records = @($qooSources | ForEach-Object { New-SourceRecord $_ $p $_.BaseName })
        $parts = @(Get-MediaFiles $rightRoot $true | Where-Object Name -like '*_right_*.mp4')
        $groups = @(New-FinalGroup (Join-Path $p "$projectName QOOCAM RAW Proxy Complete.mp4") $parts $qooSources.Count)
        $profiles.Add((New-CameraProfile 'CAM-02' 'QOOCAM' $p $records @($proxyRoot,$rightRoot) $groups))
    }

    $gopro = Join-Path $p '100GOPRO'; $goproProxy = Join-Path $gopro 'Proxy GOPRO RAW'
    $goproSources = @(Get-MediaFiles $gopro $true | Where-Object {
        -not $_.FullName.StartsWith(($goproProxy.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
    })
    if ($goproSources.Count -or (Test-KnownCamera 'CAM-03')) {
        $records = @($goproSources | ForEach-Object { New-SourceRecord $_ $p $_.BaseName })
        $parts = @(Get-MediaFiles $goproProxy $true | Where-Object Name -like '* GOPROProxy.mp4')
        $groups = @(New-FinalGroup (Join-Path $p "$projectName GOPRO RAW PROXY Complete.mp4") $parts $goproSources.Count)
        $profiles.Add((New-CameraProfile 'CAM-03' 'GOPRO' $p $records @($goproProxy) $groups))
    }

    $gear = Join-Path $p '101PHOTO'
    $gearSources = @(Get-MediaFiles $gear $false | Where-Object Extension -ieq '.mp4')
    if ($gearSources.Count -or (Test-KnownCamera 'CAM-04')) {
        $proxyRoot = Join-Path $gear 'Proxy GEAR 360 RAW'
        $records = @($gearSources | ForEach-Object { New-SourceRecord $_ $p $_.BaseName })
        $parts = @(Get-MediaFiles $proxyRoot $true | Where-Object Name -like '* Gear360Proxy.mp4')
        $groups = @(New-FinalGroup (Join-Path $p "$projectName GEAR 360 RAW PROXY Complete.mp4") $parts $gearSources.Count)
        $profiles.Add((New-CameraProfile 'CAM-04' 'GEAR 360' $p $records @($proxyRoot) $groups))
    }

    $dji = Join-Path $p 'CAM_001'
    if ((Test-Path -LiteralPath $dji -PathType Container) -or (Test-KnownCamera 'CAM-05')) {
        $djiDirect = @(Get-ChildItem -LiteralPath $dji -File -ErrorAction SilentlyContinue)
        $leftSources = @($djiDirect | Where-Object Extension -ieq '.lrf')
        $dualSources = @($djiDirect | Where-Object Extension -in @('.mp4','.mov'))
        if ($leftSources.Count -or $dualSources.Count -or (Test-KnownCamera 'CAM-05')) {
            $leftRoot=Join-Path $dji 'Proxy DJI OSMO RAW'; $dualRoot=Join-Path $dji 'Proxy DJI OSMO DUAL'
            $allSources=@($leftSources)+@($dualSources)
            $records=@($allSources|ForEach-Object{New-SourceRecord $_ $p $_.BaseName})
            $groups=@()
            if($leftSources.Count){$groups+=New-FinalGroup (Join-Path $p "$projectName DJI OSMO RAW Proxy Complete.mp4") @(Get-MediaFiles $leftRoot $true|Where-Object Name -like '*_DJIProxy_LEFT_*.mp4') $leftSources.Count}
            if($dualSources.Count){$groups+=New-FinalGroup (Join-Path $p "$projectName DJI OSMO DUAL Preview Complete.mp4") @(Get-MediaFiles $dualRoot $true|Where-Object Name -like '*_DJI_DUAL_PREVIEW_*.mp4') $dualSources.Count}
            $profiles.Add((New-CameraProfile 'CAM-05' 'DJI OSMO' $p $records @($leftRoot,$dualRoot) $groups))
        }
    }

    $insta = Join-Path $p 'Camera01'
    $instaSources = @()
    if(Test-Path -LiteralPath $insta){$instaSources=@(Get-ChildItem -LiteralPath $insta -File -Filter '*_00_*.insv' -ErrorAction SilentlyContinue)}
    if($instaSources.Count -or (Test-KnownCamera 'CAM-06')){
        $proxyRoot=Join-Path $insta 'Proxy INSTA RAW'
        $records=@($instaSources|ForEach-Object{New-SourceRecord $_ $p $_.BaseName})
        $parts=@(Get-MediaFiles $proxyRoot $true|Where-Object Name -notlike '* INSTA RAW PROXY Complete.mp4')
        $groups=@(New-FinalGroup (Join-Path $p "$projectName INSTA RAW PROXY Complete.mp4") $parts $instaSources.Count)
        $profiles.Add((New-CameraProfile 'CAM-06' 'INSTA EVO' $p $records @($proxyRoot) $groups))
    }

    $tarsier=Join-Path $p 'Tarsier'; $tarsierInput=Join-Path $tarsier 'Videos'
    $tarsierSources=@(Get-MediaFiles $tarsierInput $true)
    if($tarsierSources.Count -or (Test-KnownCamera 'CAM-07')){
        $proxyRoot=Join-Path $tarsier 'Proxies'; $rightRoot=Join-Path $tarsier 'Right25'
        $records=@($tarsierSources|ForEach-Object{New-SourceRecord $_ $p $_.BaseName})
        $parts=@(Get-MediaFiles $rightRoot $true|Where-Object Name -like '*_right_*.mp4')
        $groups=@(New-FinalGroup (Join-Path $p "$projectName TARSIER RAW Proxy Complete.mp4") $parts $tarsierSources.Count)
        $profiles.Add((New-CameraProfile 'CAM-07' 'TARSIER' $p $records @($proxyRoot,$rightRoot) $groups))
    }

    $dateDirs=@(Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue|Where-Object Name -match '^\d{4}_\d{2}_\d{2}$')
    $techeRecords=[Collections.Generic.List[object]]::new(); $techeRoots=[Collections.Generic.List[string]]::new(); $techeParts=[Collections.Generic.List[object]]::new(); $techeClipCount=0
    foreach($date in $dateDirs){
        $proxyRoot=Join-Path $date.FullName 'Proxy TECHE RAW'; $techeRoots.Add($proxyRoot)
        foreach($clip in (Get-ChildItem -LiteralPath $date.FullName -Directory -Filter 'VIDEO_TECHE_*' -ErrorAction SilentlyContinue)){
            $clipMedia=@(Get-MediaFiles $clip.FullName $false)
            if($clipMedia|Where-Object Name -match '(?i)TechePrev'){$techeClipCount++}
            foreach($file in $clipMedia){$techeRecords.Add((New-SourceRecord $file $p $clip.Name))}
        }
        foreach($file in (Get-MediaFiles $proxyRoot $true|Where-Object Name -match '(?i)(__TecheMain_proxy| TECHEProxy)\.mp4$')){$techeParts.Add($file)}
    }
    if($techeRecords.Count -or (Test-KnownCamera 'CAM-08')){
        $groups=@(New-FinalGroup (Join-Path $p "$projectName TECHE RAW Proxy Complete.mp4") @($techeParts) $techeClipCount)
        $profiles.Add((New-CameraProfile 'CAM-08' 'TECHE' $p @($techeRecords) @($techeRoots) $groups))
    }

    $go3=Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue|Where-Object Name -match '(?i)^Insta\s*Go\s*3?$'|Select-Object -First 1
    if($go3 -or (Test-KnownCamera 'CAM-09')){
        if(-not $go3){$go3=[IO.DirectoryInfo](Join-Path $p 'Insta Go 3')}
        $go3Sources=@(Get-ChildItem -LiteralPath $go3.FullName -File -ErrorAction SilentlyContinue|Where-Object Extension -ieq '.lrv')
        if($go3Sources.Count -or (Test-KnownCamera 'CAM-09')){
            $records=@($go3Sources|ForEach-Object{New-SourceRecord $_ $p $_.BaseName})
            $groups=@(New-FinalGroup (Join-Path $p "$projectName GO3 RAW PROXY Complete.mp4") @() 0)
            $profiles.Add((New-CameraProfile 'CAM-09' 'INSTA GO 3' $p $records @() $groups))
        }
    }
    return @($profiles)
}

function Compare-Sources([object[]]$Old, [object[]]$Current) {
    $oldMap=@{}; $newMap=@{}
    foreach($r in @($Old)){$oldMap[[string]$r.Path.ToLowerInvariant()]=$r}
    foreach($r in @($Current)){$newMap[[string]$r.Path.ToLowerInvariant()]=$r}
    $changed=[Collections.Generic.List[object]]::new()
    foreach($key in $oldMap.Keys){
        if(-not $newMap.ContainsKey($key)){$changed.Add($oldMap[$key]);continue}
        $a=$oldMap[$key];$b=$newMap[$key]
        if([long]$a.Length-ne[long]$b.Length -or [string]$a.LastWriteUtc-ne[string]$b.LastWriteUtc){$changed.Add($a);$changed.Add($b)}
    }
    foreach($key in $newMap.Keys){if(-not $oldMap.ContainsKey($key)){$changed.Add($newMap[$key])}}
    return @($changed)
}

function Test-NameContainsAlias([string]$Name,[string[]]$Aliases){
    foreach($alias in $Aliases){if($alias -and $Name.IndexOf($alias,[StringComparison]::OrdinalIgnoreCase)-ge 0){return $true}}
    return $false
}

function Move-ToQuarantine([string]$Path,[object]$Profile){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    $relative=Get-RelativePath $Profile.ProjectPath $Path
    $destination=Join-Path $Profile.ProjectPath ("archive\proxy-integrity\{0}\{1}\{2}" -f $runStamp,$Profile.Id,$relative)
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force|Out-Null
    if(Test-Path -LiteralPath $destination){$destination+="."+[guid]::NewGuid().ToString('N')}
    Move-Item -LiteralPath $Path -Destination $destination
    return $destination
}

$projects=@(Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction Stop|Where-Object Name -match '^\d'|Sort-Object Name)
foreach($project in $projects){
    foreach($profile in (Get-Profiles $project)){
        try{
            $stateDir=Join-Path $profile.ProjectPath '.proxy-integrity'
            $statePath=Join-Path $stateDir ($profile.Id+'.json')
            $oldState=$null
            if(Test-Path -LiteralPath $statePath -PathType Leaf){try{$oldState=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json}catch{$oldState=$null}}
            $changedSources=if($oldState){@(Compare-Sources @($oldState.Sources) @($profile.Sources))}else{@()}
            $sourceChanged=$changedSources.Count -gt 0

            $badSources=[Collections.Generic.List[object]]::new()
            foreach($sourceRecord in $profile.Sources){
                $sourcePath=Join-Path $profile.ProjectPath ([string]$sourceRecord.Path)
                $sourceTest=Test-MediaFile $sourcePath
                if(-not $sourceTest.Valid){$badSources.Add([pscustomobject]@{Path=$sourcePath;Alias=[string]$sourceRecord.Alias;Reason=$sourceTest.Error})}
            }

            $derived=@()
            foreach($root in $profile.ProxyRoots){$derived+=@(Get-MediaFiles $root $true)}
            $derived=@($derived|Sort-Object FullName -Unique)
            $partials=@($derived|Where-Object Name -match '(?i)\.partial\.')
            $badDerived=[Collections.Generic.List[object]]::new()
            $mediaCache=@{}
            foreach($file in ($derived|Where-Object Name -notmatch '(?i)\.partial\.')){
                $test=Test-MediaFile $file.FullName;$mediaCache[$file.FullName]=$test
                if(-not $test.Valid){$badDerived.Add([pscustomobject]@{File=$file;Reason=$test.Error})}
            }

            $badFinals=[Collections.Generic.List[object]]::new();$missingFinals=[Collections.Generic.List[string]]::new();$countMismatch=$false
            foreach($group in $profile.FinalGroups){
                if(-not(Test-Path -LiteralPath $group.Path -PathType Leaf)){$missingFinals.Add($group.Path);continue}
                $finalTest=Test-MediaFile $group.Path
                if(-not $finalTest.Valid){$badFinals.Add([pscustomobject]@{Path=$group.Path;Reason=$finalTest.Error});continue}
                $validParts=@($group.Parts|Where-Object{Test-Path -LiteralPath $_.FullName -PathType Leaf})
                if($group.ExpectedCount -gt 0 -and $validParts.Count -ne $group.ExpectedCount){$countMismatch=$true}
                if($validParts.Count){
                    $sum=0.0;$allValid=$true
                    foreach($part in $validParts){$test=if($mediaCache.ContainsKey($part.FullName)){$mediaCache[$part.FullName]}else{Test-MediaFile $part.FullName};if(-not$test.Valid){$allValid=$false;break};$sum+=$test.Duration}
                    if($allValid){$tol=[Math]::Max(2.0,$sum*0.01);if([Math]::Abs($finalTest.Duration-$sum)-gt$tol){$badFinals.Add([pscustomobject]@{Path=$group.Path;Reason=("Duracion final {0:N2}s versus partes {1:N2}s"-f $finalTest.Duration,$sum)})}}
                }
            }

            $issues=[Collections.Generic.List[string]]::new()
            if($sourceChanged){$issues.Add('Cambio en originales')}
            if($profile.Sources.Count -eq 0){$issues.Add('Ya no hay originales de esta camara')}
            if($badSources.Count){$issues.Add("Originales ilegibles: $($badSources.Count)")}
            if($partials.Count){$issues.Add("Parciales: $($partials.Count)")}
            if($badDerived.Count){$issues.Add("Proxies corruptos: $($badDerived.Count)")}
            if($badFinals.Count){$issues.Add("Finales invalidos: $($badFinals.Count)")}
            if($missingFinals.Count){$issues.Add("Finales faltantes: $($missingFinals.Count)")}
            if($countMismatch){$issues.Add('Cantidad originales/proxies diferente')}

            $moved=[Collections.Generic.List[string]]::new()
            $unsafeOriginal=$badSources.Count -gt 0
            $repairBlocked=$unsafeOriginal -or $profile.Sources.Count -eq 0
            if($Repair -and $issues.Count -and -not $unsafeOriginal){
                $toMove=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach($file in $partials){[void]$toMove.Add($file.FullName)}
                foreach($bad in $badDerived){[void]$toMove.Add($bad.File.FullName)}
                foreach($bad in $badFinals){[void]$toMove.Add($bad.Path)}
                if($partials.Count -or $badDerived.Count -or $sourceChanged -or $countMismatch -or $profile.Sources.Count -eq 0){foreach($group in $profile.FinalGroups){[void]$toMove.Add($group.Path)}}

                $aliases=@($changedSources|ForEach-Object{[string]$_.Alias}|Where-Object{$_}|Sort-Object -Unique)
                $currentAliases=@($profile.Sources|ForEach-Object{[string]$_.Alias}|Where-Object{$_}|Sort-Object -Unique)
                if($sourceChanged -or $countMismatch -or $profile.Sources.Count -eq 0){
                    $orphaned=@($derived|Where-Object{-not(Test-NameContainsAlias $_.BaseName $currentAliases)})
                    foreach($file in $orphaned){[void]$toMove.Add($file.FullName)}
                    foreach($file in $derived){if(Test-NameContainsAlias $file.BaseName $aliases){[void]$toMove.Add($file.FullName)}}
                    if($sourceChanged -and $aliases.Count -and @($toMove|Where-Object{$_ -notin @($profile.FinalGroups.Path)}).Count -eq 0){foreach($file in $derived){[void]$toMove.Add($file.FullName)}}
                }
                foreach($path in $toMove){$destination=Move-ToQuarantine $path $profile;if($destination){$moved.Add($destination)}}
            }

            if(-not $NoState){
                New-Item -ItemType Directory -Path $stateDir -Force|Out-Null
                [pscustomobject]@{Version=1;CameraId=$profile.Id;Camera=$profile.Name;Project=$profile.ProjectPath;CheckedUtc=(Get-Date).ToUniversalTime().ToString('o');Pending=($issues.Count-gt0);Blocked=[bool]$repairBlocked;Sources=@($profile.Sources)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $statePath -Encoding UTF8
            }

            $status=if($issues.Count){if($repairBlocked){'BLOQUEADO'}elseif($Repair){'PREPARADO'}else{'REVISAR'}}else{'OK'}
            $message=if($issues.Count){$issues -join '; '}else{'Originales, proxies y finales coherentes'}
            Write-Host ("[{0}] {1} / {2}: {3}"-f $status,$project.Name,$profile.Name,$message) -ForegroundColor $(if($issues.Count){'Yellow'}else{'Green'})
            foreach($bad in $badSources){Write-Host ("  [ORIGINAL ILEGIBLE] {0} | {1}"-f $bad.Path,$bad.Reason) -ForegroundColor Red}
            foreach($bad in $badDerived){Write-Host ("  [PROXY INVALIDO] {0} | {1}"-f $bad.File.FullName,$bad.Reason) -ForegroundColor Red}
            foreach($bad in $badFinals){Write-Host ("  [FINAL INVALIDO] {0} | {1}"-f $bad.Path,$bad.Reason) -ForegroundColor Red}
            $results.Add([pscustomobject]@{
                Project=$project.Name;Camera=$profile.Name;CameraId=$profile.Id;Status=$status;Sources=$profile.Sources.Count
                Issues=@($issues);ChangedSources=@($changedSources.Path);BadSources=@($badSources.Path)
                BadProxies=@($badDerived|ForEach-Object{$_.File.FullName});BadFinals=@($badFinals.Path)
                Partials=@($partials.FullName);MissingFinals=@($missingFinals);Quarantined=@($moved);State=$statePath
            })
        }catch{
            Write-Host ("[ERROR] {0} / {1}: {2}"-f $project.Name,$profile.Name,$_.Exception.Message) -ForegroundColor Red
            $results.Add([pscustomobject]@{Project=$project.Name;Camera=$profile.Name;CameraId=$profile.Id;Status='ERROR';Sources=$profile.Sources.Count;Issues=@($_.Exception.Message);Quarantined=@();State=''})
        }
    }
}

[pscustomobject]@{Timestamp=(Get-Date).ToString('o');Root=$RootPath;Repair=[bool]$Repair;NoState=[bool]$NoState;Results=@($results)}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportOut -Encoding UTF8
$errors=@($results|Where-Object Status -eq 'ERROR').Count
$issues=@($results|Where-Object Status -in @('REVISAR','PREPARADO','BLOQUEADO')).Count
Write-Host ("[INTEGRIDAD] Camaras={0} ConHallazgos={1} Errores={2}"-f $results.Count,$issues,$errors) -ForegroundColor $(if($errors){'Red'}elseif($issues){'Yellow'}else{'Green'})
Write-Host "[INTEGRIDAD] Reporte: $ReportOut"
if($errors){exit 2};if($issues){exit 1};exit 0
