<#
TOOL-06-ORGANIZAR-ORIGENES

Reune el material de camaras y microfonos en la carpeta de proyecto
"NNN - Titulo" del dia en que se grabo, conservando el nombre original de cada
archivo y las carpetas que esperan los scripts de proxies:

  100QOOCAM\Q360_AAAAMMDD_HHMMSS_n.MP4        QooCam
  CAM_001\CAM_AAAAMMDDHHMMSS_nnnn_D.OSV       DJI Osmo 360
  AAAA_MM_DD\VIDEO_TECHE_...\TecheMain.mp4    Teche
  100GOPRO\DDMMAA PtN.MP4                     GoPro (fecha del renombrado manual)
  hl-AAAA-MM-DD\HH-MM-SS.wav                  Microfono anterior
  TX-AAAA-MM-DD\TX02_MICnnn_..._orig.wav      Microfono nuevo (mini SD)

Reglas:
  - Cada proyecto tiene un dia principal: el que reune mas archivos de video
    entre todas sus camaras (el audio solo decide si no hay video).
  - Un dia pertenece al unico proyecto que lo tiene como principal.
  - Lo que esta suelto en la raiz, o dentro de un proyecto pero es de otro dia,
    se lleva al proyecto dueno de ese dia.
  - Un dia sin dueno y posterior al ultimo proyecto crea el proyecto siguiente.
  - Un dia sin dueno y anterior (o solo con audio) va a Rezagados\AAAA-MM-DD.
  - Cada original viaja con sus derivados por clip (KDOutput, Proxies, Right25,
    Proxy ... RAW/DUAL), reconocidos porque su nombre empieza con el del original,
    y con su registro de .proxy-integrity. Asi el verificador de integridad solo
    detecta que el final unido ya no cuadra y rehace ese final, no los proxies.

Nunca borra ni sobrescribe archivos: solo mueve dentro de la misma unidad. Lo que
no puede fechar queda donde esta y se explica en el listado de inconvenientes.
Sin -Aplicar solo analiza. -Deshacer <registro.csv> revierte una ejecucion.
#>
[CmdletBinding()]
param(
    [string]$Root = 'G:\',
    [switch]$Aplicar,
    [string]$Deshacer,
    # Una grabacion antes de esta hora pertenece a la sesion del dia anterior.
    [int]$CorteHora = 5,
    # Horas que hay que sumar al reloj del microfono TX para obtener la hora real.
    # Medido por dialogo contra las camaras: el reloj del TX02 va 13 h 01 min adelantado.
    [double]$MicTxOffsetHoras = -13,
    # Muestra el plan y pregunta antes de mover.
    [switch]$Confirmar,
    [string]$CarpetaRezagados = 'Rezagados',
    [datetime]$Desde = [datetime]::MinValue,
    [datetime]$Hasta = [datetime]::MaxValue,
    # Permite al lanzador grafico leer exactamente el plan generado.
    [string]$PlanCsv
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = $PSScriptRoot }
$LogDir = Join-Path $RepoRoot 'logs'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$MediaExt = @('.mp4', '.mov', '.mkv', '.m4v', '.avi', '.insv', '.lrv')   # las mismas del verificador
$OriginalExt = $MediaExt + @('.osv', '.lrf', '.insp', '.wav', '.jpg', '.thm')

function Write-Journal($rows, $path) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
}

function Move-Literal([string]$from, [string]$to) {
    $parent = Split-Path -Parent $to
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path -LiteralPath $from -PathType Container) { [IO.Directory]::Move($from, $to) }
    else { [IO.File]::Move($from, $to) }
}

# Solo retira carpetas que quedaron completamente vacias; jamas un archivo.
function Remove-IfEmpty([string]$dir) {
    if ((Test-Path -LiteralPath $dir -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) {
        [IO.Directory]::Delete($dir, $false)
        Write-Host "  (carpeta vacia retirada) $dir" -ForegroundColor DarkGray
        return $true
    }
    return $false
}

# ---------------------------------------------------------------- deshacer
if ($Deshacer) {
    $all = @(Import-Csv -LiteralPath $Deshacer)
    $rows = @($all | Where-Object { $_.Estado -eq 'MOVIDO' })
    [array]::Reverse($rows)
    foreach ($r in $rows) {
        if (-not (Test-Path -LiteralPath $r.Destino)) { Write-Host "[FALTA] $($r.Destino)" -ForegroundColor Yellow; continue }
        if (Test-Path -LiteralPath $r.Origen) { Write-Host "[OCUPADO] $($r.Origen)" -ForegroundColor Yellow; continue }
        Move-Literal $r.Destino $r.Origen
        Write-Host "[DEVUELTO] $($r.Origen)"
        # Retirar solo las carpetas que este movimiento dejo vacias.
        $dir = Split-Path -Parent $r.Destino
        foreach ($level in 1..4) {
            if (-not (Remove-IfEmpty $dir)) { break }
            $dir = Split-Path -Parent $dir
        }
    }
    # Los registros de integridad vuelven a su copia previa.
    foreach ($r in ($all | Where-Object { $_.Estado -eq 'ESTADO' })) {
        if (Test-Path -LiteralPath $r.Origen) {
            Copy-Item -LiteralPath $r.Origen -Destination $r.Destino -Force
            Write-Host "[ESTADO RESTAURADO] $($r.Destino)"
        }
    }
    exit 0
}

# ---------------------------------------------------------------- fechas
function Get-SessionDay([datetime]$when) {
    if ($when.Hour -lt $CorteHora) { return $when.Date.AddDays(-1) }
    return $when.Date
}

function ConvertTo-Stamp([string]$digits) {
    $out = [datetime]::MinValue
    if ([datetime]::TryParseExact($digits, 'yyyyMMddHHmmss', $Inv, 'None', [ref]$out)) { return $out }
    return $null
}

# Devuelve la hora real de grabacion segun el nombre, o $null si no es reconocible.
function Get-NameTime([string]$name, [string]$parentName) {
    if ($name -match '^Q360_(\d{8})_(\d{6})_') { return ConvertTo-Stamp ($Matches[1] + $Matches[2]) }
    if ($name -match '^CAM_(\d{14})_\d+') { return ConvertTo-Stamp $Matches[1] }
    if ($name -match '^(?:VIDEO|PHOTO)_TECHE_(\d{14})\d*_') { return ConvertTo-Stamp $Matches[1] }
    if ($name -match '^TX\d*_MIC\d+_(\d{8})_(\d{6})') {
        $t = ConvertTo-Stamp ($Matches[1] + $Matches[2])
        if ($t) { return $t.AddHours($MicTxOffsetHoras) }
        return $null
    }
    if ($parentName -match '^hl-(\d{4})-(\d{2})-(\d{2})$') {
        $day = $Matches[1] + $Matches[2] + $Matches[3]
        if ($name -match '^(\d{2})-(\d{2})-(\d{2})[ .]') { return ConvertTo-Stamp ($day + $Matches[1] + $Matches[2] + $Matches[3]) }
        return $null
    }
    # GoPro: el reloj de la camara no es fiable; vale el renombrado manual DDMMAA.
    if ($name -match '^(\d{2})(\d{2})(\d{2})\s*pt\s*\d+') {
        return ConvertTo-Stamp ('20' + $Matches[3] + $Matches[2] + $Matches[1] + '120000')
    }
    return $null
}

$CameraDirs = @{ '100QOOCAM' = 'QOOCAM'; 'CAM_001' = 'DJI OSMO'; '100GOPRO' = 'GOPRO'; 'Camera01' = 'INSTA' }
$AudioKinds = @('MIC HL', 'MIC TX')
$DerivedDirPattern = '^(KDOutput|Proxies|Right25|Proxy .*|_.*|QooCam.*)$'

function Get-SourceKind([string]$dirName) {
    if ($CameraDirs.ContainsKey($dirName)) { return $CameraDirs[$dirName] }
    if ($dirName -match '^\d{4}_\d{2}_\d{2}$') { return 'TECHE' }
    if ($dirName -match '^hl-\d{4}-\d{2}-\d{2}$') { return 'MIC HL' }
    # TX-AAAA-MM-DD (la que crea esta herramienta) o TX02_MIC007_AAAAMMDD (copiada tal cual de la mini SD).
    if ($dirName -match '^TX\d*[-_]') { return 'MIC TX' }
    return $null
}

# Carpeta, dentro del proyecto, donde los scripts esperan cada unidad.
function Get-DestFolder([string]$kind, [string]$sourceDirName, [datetime]$day) {
    switch ($kind) {
        'QOOCAM'   { return '100QOOCAM' }
        'DJI OSMO' { return 'CAM_001' }
        'GOPRO'    { return '100GOPRO' }
        'MIC TX'   { return 'TX-' + $day.ToString('yyyy-MM-dd') }
    }
    return $sourceDirName   # Teche y microfono anterior conservan su carpeta de fecha
}

function Get-KindFromFile([string]$name) {
    if ($name -match '^Q360_\d{8}_') { return 'QOOCAM' }
    if ($name -match '^CAM_\d{14}_') { return 'DJI OSMO' }
    if ($name -match '^TX\d*_MIC\d+_') { return 'MIC TX' }
    return $null
}

# ---------------------------------------------------------------- inventario
$units = New-Object System.Collections.ArrayList
$problems = New-Object System.Collections.ArrayList

# Derivados de un original: archivos de las subcarpetas de su camara cuyo nombre
# empieza con el nombre del original. _HISTORICO y similares no se tocan.
function Get-SubFiles([string]$cameraDir) {
    foreach ($sub in Get-ChildItem -LiteralPath $cameraDir -Directory -ErrorAction SilentlyContinue) {
        if ($sub.Name -match '^_' -or (Get-NameTime $sub.Name (Split-Path -Leaf $cameraDir))) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $sub.FullName -File -ErrorAction SilentlyContinue) {
            [pscustomobject]@{ Sub = $sub.Name; Nombre = $f.Name; Origen = $f.FullName }
        }
    }
}
function Get-Companions($item, $subFiles) {
    $stem = if ($item.PSIsContainer) { $item.Name } else { [IO.Path]::GetFileNameWithoutExtension($item.Name) }
    @($subFiles | Where-Object {
        $_.Nombre.Length -gt $stem.Length -and $_.Nombre.StartsWith($stem, [StringComparison]::OrdinalIgnoreCase) -and
        '_. ('.Contains($_.Nombre[$stem.Length])
    })
}

function Add-Unit($item, [string]$kind, [string]$sourceDirName, $when, [string]$owner, $extras = @()) {
    $day = Get-SessionDay $when
    [void]$units.Add([pscustomobject]@{
        Extras = @($extras | Where-Object { $_ })
        Origen = $item.FullName; Nombre = $item.Name; Camara = $kind; Dia = $day.ToString('yyyy-MM-dd')
        Carpeta = (Get-DestFolder $kind $sourceDirName $day); Dueno = $owner
        EsVideo = ($AudioKinds -notcontains $kind)
    })
}
function Add-Problem([string]$path, [string]$kind, [string]$why, [int]$count = 1) {
    [void]$problems.Add([pscustomobject]@{ Camara = $kind; Elementos = $count; Ruta = $path; Motivo = $why })
}

# $owner vacio = material suelto (raiz o Rezagados); si no, nombre del proyecto que lo contiene.
function Read-Container([string]$path, [string]$owner) {
    foreach ($f in Get-ChildItem -LiteralPath $path -File -ErrorAction SilentlyContinue) {
        $kind = Get-KindFromFile $f.Name
        if (-not $kind) { continue }
        $t = Get-NameTime $f.Name ''
        if ($t) { Add-Unit $f $kind '' $t $owner }
        else { Add-Problem $f.FullName $kind 'El nombre parece de camara pero su fecha no es valida (mes, dia u hora imposibles).' }
    }
    foreach ($d in Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue) {
        $kind = Get-SourceKind $d.Name
        if (-not $kind) { continue }
        $entries = @(Get-ChildItem -LiteralPath $d.FullName -ErrorAction SilentlyContinue)
        if ($kind -eq 'INSTA') {
            $n = @($entries | Where-Object { -not $_.PSIsContainer -and $_.Extension -in '.insv', '.insp' }).Count
            if ($n) { Add-Problem $d.FullName $kind 'La Insta graba con el reloj sin configurar (anos 2018); el nombre no dice el dia real. Se queda donde esta.' $n }
            continue
        }
        $pending = @()
        $days = @{}
        $subFiles = @(Get-SubFiles $d.FullName)
        foreach ($e in $entries) {
            $t = Get-NameTime $e.Name $d.Name
            if ($t) { Add-Unit $e $kind $d.Name $t $owner (Get-Companions $e $subFiles); $days[(Get-SessionDay $t).ToString('yyyy-MM-dd')] = $t }
            else { $pending += $e }
        }
        foreach ($e in $pending) {
            if ($e.PSIsContainer) {
                if ($e.Name -match $DerivedDirPattern) { continue }
                $n = @(Get-ChildItem -LiteralPath $e.FullName -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $OriginalExt -contains $_.Extension.ToLowerInvariant() }).Count
                if ($n) { Add-Problem $e.FullName $kind 'Subcarpeta creada a mano dentro de la carpeta de camara; no sigue la nomenclatura y no se analiza por dentro.' $n }
                continue
            }
            if ($OriginalExt -notcontains $e.Extension.ToLowerInvariant()) { continue }
            $isGoProFile = ($kind -eq 'GOPRO' -and $e.Name -match '^G[A-Z]\d{6}\.')
            # Acompanantes GoPro (LRV/THM/MP4 sin renombrar): solo si la carpeta es de un unico dia.
            if ($isGoProFile -and $days.Count -eq 1) { Add-Unit $e $kind $d.Name (@($days.Values)[0]) $owner (Get-Companions $e $subFiles) }
            elseif ($isGoProFile -and $days.Count -eq 0) { Add-Problem $e.FullName $kind 'GoPro sin renombrar a DDMMAA PtN: el reloj de la camara no es fiable y no hay otro archivo fechado en la carpeta.' }
            elseif ($isGoProFile) { Add-Problem $e.FullName $kind 'GoPro sin renombrar a DDMMAA PtN y la carpeta mezcla varios dias; no se sabe a cual pertenece.' }
            else { Add-Problem $e.FullName $kind 'Archivo de medios cuyo nombre no sigue la nomenclatura de esta camara; no se puede leer su fecha.' }
        }
    }
}

$rootPath = (Get-Item -LiteralPath $Root).FullName
$lateRoot = Join-Path $rootPath $CarpetaRezagados
$projects = @(Get-ChildItem -LiteralPath $rootPath -Directory | Where-Object { $_.Name -match '^\d{3}[\s-]' } | Sort-Object Name)

Read-Container $rootPath ''
if (Test-Path -LiteralPath $lateRoot) {
    foreach ($d in Get-ChildItem -LiteralPath $lateRoot -Directory) { Read-Container $d.FullName '' }
}
foreach ($p in $projects) { Read-Container $p.FullName $p.Name }

# ---------------------------------------------------------------- dia principal y dueno
$stats = @{}   # proyecto -> dia -> @{Video; Audio; Camaras = @{camara = n}}
foreach ($u in $units) {
    if (-not $u.Dueno) { continue }
    if (-not $stats.ContainsKey($u.Dueno)) { $stats[$u.Dueno] = @{} }
    if (-not $stats[$u.Dueno].ContainsKey($u.Dia)) { $stats[$u.Dueno][$u.Dia] = @{ Video = 0; Audio = 0; Camaras = @{} } }
    $s = $stats[$u.Dueno][$u.Dia]
    if ($u.EsVideo) { $s.Video++ } else { $s.Audio++ }
    $s.Camaras[$u.Camara] = 1 + [int]$s.Camaras[$u.Camara]
}

$mainDay = @{}        # proyecto -> dia principal
$undecided = @{}      # proyecto -> motivo (no se mueve nada de el)
foreach ($name in $stats.Keys) {
    $field = 'Video'
    $rank = @($stats[$name].GetEnumerator() | Where-Object { $_.Value.Video -gt 0 } | Sort-Object { $_.Value.Video } -Descending)
    if (-not $rank.Count) { $field = 'Audio'; $rank = @($stats[$name].GetEnumerator() | Sort-Object { $_.Value.Audio } -Descending) }
    if ($rank.Count -gt 1 -and $rank[0].Value[$field] -eq $rank[1].Value[$field]) {
        $undecided[$name] = "Empate entre $($rank[0].Key) y $($rank[1].Key) ($($rank[0].Value[$field]) archivos cada uno): no hay un dia principal claro."
    } else { $mainDay[$name] = $rank[0].Key }
}

$ownerOf = @{}        # dia -> proyecto
$disputed = @{}       # dia -> proyectos que lo tienen como principal
foreach ($g in ($mainDay.GetEnumerator() | Group-Object Value)) {
    if ($g.Count -eq 1) { $ownerOf[$g.Name] = $g.Group[0].Key }
    else { $disputed[$g.Name] = (@($g.Group | ForEach-Object { $_.Key } | Sort-Object) -join ' | ') }
}
foreach ($name in $undecided.Keys) { Add-Problem (Join-Path $rootPath $name) 'PROYECTO' $undecided[$name] }
foreach ($day in $disputed.Keys) { Add-Problem $rootPath 'PROYECTO' "El dia $day es el principal de varios proyectos ($($disputed[$day])); no se mueve nada de ese dia hasta que decidas." }

$lastProjectDay = @($mainDay.Values | Sort-Object | Select-Object -Last 1)[0]
$maxNumber = 0
foreach ($p in $projects) { $n = [int]$p.Name.Substring(0, 3); if ($n -gt $maxNumber) { $maxNumber = $n } }

function Test-Displaced($u) {
    if (-not $u.Dueno) { return $true }
    if ($undecided.ContainsKey($u.Dueno)) { return $false }
    return $mainDay[$u.Dueno] -ne $u.Dia
}

# Dias sin dueno: proyecto nuevo si es una sesion posterior con video; si no, Rezagados.
$newNames = @{}
$next = $maxNumber
$freeDays = @($units | Where-Object { Test-Displaced $_ } | ForEach-Object { $_.Dia } | Sort-Object -Unique)
foreach ($day in $freeDays) {
    if ($ownerOf.ContainsKey($day) -or $disputed.ContainsKey($day)) { continue }
    $hasVideo = @($units | Where-Object { $_.Dia -eq $day -and $_.EsVideo -and (Test-Displaced $_) }).Count -gt 0
    if ($hasVideo -and $day -gt $lastProjectDay) { $next++; $newNames[$day] = ('{0:000} - {1}' -f $next, $day) }
}

# ---------------------------------------------------------------- plan
$plan = foreach ($u in $units) {
    if ($u.Dia -lt $Desde.ToString('yyyy-MM-dd') -or $u.Dia -gt $Hasta.ToString('yyyy-MM-dd')) { continue }
    if (-not (Test-Displaced $u)) { continue }
    $day = $u.Dia
    $estado = 'MOVER'
    if ($disputed.ContainsKey($day)) { $tipo = 'EN DISPUTA'; $estado = 'EN DISPUTA'; $target = $disputed[$day] }
    elseif ($ownerOf.ContainsKey($day)) { $target = $ownerOf[$day]; $tipo = if ($u.Dueno) { 'DE OTRO DIA' } else { 'EXISTENTE' } }
    elseif ($newNames.ContainsKey($day)) { $tipo = 'NUEVO'; $target = $newNames[$day] }
    else { $tipo = 'REZAGADO'; $target = Join-Path $CarpetaRezagados $day }

    $dest = ''
    if ($estado -eq 'MOVER') {
        $dest = Join-Path (Join-Path (Join-Path $rootPath $target) $u.Carpeta) $u.Nombre
        if ($dest -eq $u.Origen) { continue }
        if (Test-Path -LiteralPath $dest) { $estado = 'YA EXISTE' }
    }
    [pscustomobject]@{
        Dia = $day; Tipo = $tipo; Proyecto = $target; Camara = $u.Camara; Carpeta = $u.Carpeta
        Nombre = $u.Nombre; Estado = $estado; Viene = $u.Dueno; EsVideo = $u.EsVideo; Derivado = $false
        Origen = $u.Origen; Destino = $dest
    }
    if ($estado -ne 'MOVER') { continue }
    foreach ($x in $u.Extras) {
        $folder = Join-Path $u.Carpeta $x.Sub
        $xDest = Join-Path (Join-Path (Join-Path $rootPath $target) $folder) $x.Nombre
        [pscustomobject]@{
            Dia = $day; Tipo = $tipo; Proyecto = $target; Camara = $u.Camara; Carpeta = $folder
            Nombre = $x.Nombre; Estado = $(if (Test-Path -LiteralPath $xDest) { 'YA EXISTE' } else { 'MOVER' })
            Viene = $u.Dueno; EsVideo = $false; Derivado = $true; Origen = $x.Origen; Destino = $xDest
        }
    }
}
# Un mismo proxy acompana a varios originales del clip (OSV y LRF): se mueve una sola vez.
$seen = @{}
$plan = @($plan | Sort-Object Dia, Proyecto, Viene, Camara, Derivado, Carpeta, Nombre | Where-Object {
    $key = $_.Origen.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { $false } else { $seen[$key] = $true; $true }
})
foreach ($row in ($plan | Where-Object { $_.Estado -eq 'YA EXISTE' })) {
    Add-Problem $row.Origen $row.Camara "Ya existe un archivo con el mismo nombre en el destino ($($row.Destino)); no se sobrescribe y este se queda donde esta."
}

# ---------------------------------------------------------------- informe
Write-Host ''
Write-Host 'PROYECTOS: dia principal [P] y dias ajenos [x]  (archivos por camara)' -ForegroundColor Cyan
foreach ($p in $projects) {
    if (-not $stats.ContainsKey($p.Name)) { Write-Host ("  {0}  (sin originales fechados)" -f $p.Name) -ForegroundColor DarkGray; continue }
    Write-Host ("  {0}" -f $p.Name)
    foreach ($day in ($stats[$p.Name].Keys | Sort-Object)) {
        $s = $stats[$p.Name][$day]
        $detail = (@($s.Camaras.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')
        $isMain = ($mainDay[$p.Name] -eq $day)
        $mark = if ($undecided.ContainsKey($p.Name)) { '?' } elseif ($isMain) { 'P' } else { 'x' }
        Write-Host ("      [{0}] {1}   {2}" -f $mark, $day, $detail) -ForegroundColor $(if ($mark -eq 'P') { 'Gray' } else { 'Yellow' })
    }
}

Write-Host ''
Write-Host "PLAN PARA $rootPath" -ForegroundColor Cyan
$colors = @{ 'NUEVO' = 'Green'; 'EXISTENTE' = 'Yellow'; 'DE OTRO DIA' = 'Magenta'; 'EN DISPUTA' = 'Red'; 'REZAGADO' = 'Gray' }
foreach ($g in ($plan | Group-Object Dia, Proyecto)) {
    $first = $g.Group[0]
    $label = if ($first.Tipo -in 'EXISTENTE', 'DE OTRO DIA') { 'PROYECTO EXISTENTE' } else { $first.Tipo }
    Write-Host ''
    Write-Host ("  {0}  ->  {1}  [{2}]" -f $first.Dia, $first.Proyecto, $label) -ForegroundColor $colors[$first.Tipo]
    foreach ($c in ($g.Group | Group-Object Viene, Camara, Carpeta)) {
        $skip = @($c.Group | Where-Object { $_.Estado -eq 'YA EXISTE' }).Count
        $extra = if ($skip) { "  ($skip ya existen, no se tocan)" } else { '' }
        $from = if ($c.Group[0].Viene) { "  (desde $($c.Group[0].Viene))" } else { '' }
        $what = if ($c.Group[0].Derivado) { 'derivado(s) ' } else { 'elemento(s)' }
        Write-Host ("      {0,-9} {1,3} {2} -> {3}\{4}{5}" -f $c.Group[0].Camara, $c.Count, $what, $c.Group[0].Carpeta, $from, $extra)
        if (-not $c.Group[0].Derivado) {
            $c.Group | Select-Object -First 8 | ForEach-Object { Write-Host "                    $($_.Nombre)" -ForegroundColor DarkGray }
            if ($c.Count -gt 8) { Write-Host "                    ... y $($c.Count - 8) mas en el plan detallado" -ForegroundColor DarkGray }
        }
    }
}

$problemPath = Join-Path $LogDir "organizador_inconvenientes_$Stamp.csv"
if ($problems.Count) {
    Write-Host ''
    Write-Host "INCONVENIENTES ($($problems.Count)) - nada de esto se mueve" -ForegroundColor Magenta
    foreach ($g in ($problems | Group-Object Camara, Motivo)) {
        $total = ($g.Group | Measure-Object Elementos -Sum).Sum
        Write-Host ("  {0,-9} {1,4} archivo(s): {2}" -f $g.Group[0].Camara, $total, $g.Group[0].Motivo)
        $g.Group | Select-Object -First 6 | ForEach-Object { Write-Host "             $($_.Ruta)" -ForegroundColor DarkGray }
        if ($g.Count -gt 6) { Write-Host "             ... y $($g.Count - 6) mas en el listado" -ForegroundColor DarkGray }
    }
    Write-Journal $problems $problemPath
    Write-Host "Listado de inconvenientes: $problemPath"
}

$planPath = if ($PlanCsv) { $PlanCsv } else { Join-Path $LogDir "organizador_plan_$Stamp.csv" }
Write-Journal $plan $planPath
$toMove = @($plan | Where-Object { $_.Estado -eq 'MOVER' })
Write-Host ''
Write-Host ("Resumen: {0} a mover ({1} originales y {2} derivados): {3} a proyectos nuevos, {4} a proyectos existentes, {5} a Rezagados. Inconvenientes: {6}." -f `
    $toMove.Count, @($toMove | Where-Object { -not $_.Derivado }).Count, @($toMove | Where-Object { $_.Derivado }).Count,
    @($toMove | Where-Object { $_.Tipo -eq 'NUEVO' }).Count, @($toMove | Where-Object { $_.Tipo -in 'EXISTENTE', 'DE OTRO DIA' }).Count,
    @($toMove | Where-Object { $_.Tipo -eq 'REZAGADO' }).Count, $problems.Count)
Write-Host "Plan detallado: $planPath"

if ($Confirmar -and -not $Aplicar) {
    if (-not $toMove.Count) { Write-Host 'No hay nada que mover.' -ForegroundColor Green; exit 0 }
    Write-Host ''
    $answer = Read-Host "Voy a mover los $($toMove.Count) elementos del plan de arriba. Escribe S para proceder (cualquier otra cosa cancela)"
    if ($answer -notmatch '^\s*s(i)?\s*$') { Write-Host 'Cancelado: no se movio nada.' -ForegroundColor Cyan; exit 0 }
    $Aplicar = $true
}
if (-not $Aplicar) {
    Write-Host 'Modo analisis: no se movio nada. Repite con -Aplicar para ejecutar el plan.' -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------- aplicar
$journalPath = Join-Path $LogDir "organizador_movimientos_$Stamp.csv"
$journal = New-Object System.Collections.ArrayList
$sourceDirs = @{}
foreach ($row in $toMove) {
    $state = 'MOVIDO'
    try {
        if (Test-Path -LiteralPath $row.Destino) { $state = 'YA EXISTE' }
        else { Move-Literal $row.Origen $row.Destino; $sourceDirs[(Split-Path -Parent $row.Origen)] = $true }
    } catch {
        $state = 'ERROR: ' + $_.Exception.Message
        Write-Host "[ERROR] $($row.Origen): $($_.Exception.Message)" -ForegroundColor Red
    }
    [void]$journal.Add([pscustomobject]@{ Origen = $row.Origen; Destino = $row.Destino; Estado = $state; Viene = $row.Viene; Tipo = $row.Tipo; Proyecto = $row.Proyecto })
    Write-Journal $journal $journalPath
}

# ---- registros de integridad: cada original movido lleva su registro al destino
function Get-Rel([string]$base, [string]$path) { return $path.Substring($base.TrimEnd('\').Length + 1) }
function Test-Under([string]$path, [string]$prefix) {
    return $path.Equals($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($prefix + '\', [StringComparison]::OrdinalIgnoreCase)
}
function New-Record([IO.FileInfo]$file, [string]$projectPath, [string]$alias) {
    [pscustomobject]@{ Path = (Get-Rel $projectPath $file.FullName); Alias = $alias; Length = [long]$file.Length; LastWriteUtc = $file.LastWriteTimeUtc.ToString('o') }
}
# Lo que el verificador considera "original" de cada camara, para un elemento recien llegado.
function Get-FreshRecords([string]$cameraId, [string]$projectPath, [string]$rel) {
    $full = Join-Path $projectPath $rel
    switch ($cameraId) {
        'CAM-08' {
            if ($rel -match '^\d{4}_\d{2}_\d{2}\\VIDEO_TECHE_[^\\]+$' -and (Test-Path -LiteralPath $full -PathType Container)) {
                $alias = Split-Path -Leaf $full
                return @(Get-ChildItem -LiteralPath $full -File | Where-Object { $MediaExt -contains $_.Extension.ToLowerInvariant() } | ForEach-Object { New-Record $_ $projectPath $alias })
            }
        }
        'CAM-05' { if ($rel -match '^CAM_001\\[^\\]+\.(lrf|mp4|mov)$') { $f = Get-Item -LiteralPath $full; return @(New-Record $f $projectPath $f.BaseName) } }
        'CAM-02' { if ($rel -match '^100QOOCAM\\KDOutput\\' -and $MediaExt -contains ([IO.Path]::GetExtension($rel).ToLowerInvariant())) { $f = Get-Item -LiteralPath $full; return @(New-Record $f $projectPath $f.BaseName) } }
        'CAM-03' { if ($rel -match '^100GOPRO\\' -and $rel -notmatch '^100GOPRO\\Proxy GOPRO RAW\\' -and $MediaExt -contains ([IO.Path]::GetExtension($rel).ToLowerInvariant())) { $f = Get-Item -LiteralPath $full; return @(New-Record $f $projectPath $f.BaseName) } }
    }
    return @()
}

$stateCache = @{}     # ruta del json -> objeto
$stateBackup = Join-Path $LogDir "organizador_estado_$Stamp"
function Get-State([string]$path) {
    if (-not $stateCache.ContainsKey($path)) {
        $copy = Join-Path $stateBackup ((Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $path))) + '\' + (Split-Path -Leaf $path))
        New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force | Out-Null
        Copy-Item -LiteralPath $path -Destination $copy
        [void]$journal.Add([pscustomobject]@{ Origen = $copy; Destino = $path; Estado = 'ESTADO'; Viene = ''; Tipo = ''; Proyecto = '' })
        $stateCache[$path] = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    return $stateCache[$path]
}

foreach ($m in @($journal | Where-Object { $_.Estado -eq 'MOVIDO' })) {
    try {
        $carried = @{}   # camara -> registros que salieron del proyecto de origen
        $srcRel = $null
        if ($m.Viene) {
            $srcProject = Join-Path $rootPath $m.Viene
            $srcRel = Get-Rel $srcProject $m.Origen
            foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $srcProject '.proxy-integrity') -File -Filter 'CAM-*.json' -ErrorAction SilentlyContinue)) {
                $state = Get-State $file.FullName
                $out = @($state.Sources | Where-Object { $_ -and (Test-Under ([string]$_.Path) $srcRel) })
                if ($out.Count) {
                    $state.Sources = @($state.Sources | Where-Object { $_ -and -not (Test-Under ([string]$_.Path) $srcRel) })
                    $carried[$file.BaseName] = $out
                }
            }
        }
        if ($m.Tipo -eq 'REZAGADO') { continue }
        $dstProject = Join-Path $rootPath $m.Proyecto
        $dstRel = Get-Rel $dstProject $m.Destino
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $dstProject '.proxy-integrity') -File -Filter 'CAM-*.json' -ErrorAction SilentlyContinue)) {
            $state = Get-State $file.FullName
            $incoming = @()
            if ($carried.ContainsKey($file.BaseName)) {
                $incoming = @($carried[$file.BaseName] | ForEach-Object {
                    [pscustomobject]@{ Path = ($dstRel + ([string]$_.Path).Substring($srcRel.Length)); Alias = $_.Alias; Length = $_.Length; LastWriteUtc = $_.LastWriteUtc }
                })
            } else { $incoming = @(Get-FreshRecords $file.BaseName $dstProject $dstRel) }
            if ($incoming.Count) {
                $paths = @($incoming | ForEach-Object { ([string]$_.Path).ToLowerInvariant() })
                $state.Sources = @(@($state.Sources | Where-Object { $_ -and $paths -notcontains ([string]$_.Path).ToLowerInvariant() }) + $incoming)
            }
        }
    } catch {
        Write-Host "[AVISO] No se pudo trasladar el registro de integridad de $($m.Destino): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
foreach ($path in $stateCache.Keys) {
    $state = $stateCache[$path]
    $state.Sources = @($state.Sources)
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
}
Write-Journal $journal $journalPath

foreach ($dir in $sourceDirs.Keys) {
    if ($dir.TrimEnd('\') -ne $rootPath.TrimEnd('\')) { [void](Remove-IfEmpty $dir) }
}
$errors = @($journal | Where-Object { $_.Estado -like 'ERROR*' }).Count
Write-Host ("Movidos: {0}. Errores: {1}. Registros de integridad actualizados: {2}." -f @($journal | Where-Object { $_.Estado -eq 'MOVIDO' }).Count, $errors, $stateCache.Count) -ForegroundColor $(if ($errors) { 'Yellow' } else { 'Green' })
Write-Host "Registro para -Deshacer: $journalPath"
