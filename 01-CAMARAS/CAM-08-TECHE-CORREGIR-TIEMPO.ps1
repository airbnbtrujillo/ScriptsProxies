[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Folder,
    [Parameter(Mandatory)] [string] $Preview,
    [Parameter(Mandatory)] [string] $Output,
    [string] $FFmpeg = 'ffmpeg',
    [string] $FFprobe = 'ffprobe',
    [double] $ToleranceSeconds = 0.04,
    [double] $MaxCorrectionPercent = 10.0
)

$ErrorActionPreference = 'Stop'
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$VideoExtensions = '.mp4', '.mov', '.mkv', '.m4v', '.avi', '.insv'
$Sidecar = "$Output.timesync.json"

function Get-MediaInfo([string] $Path) {
    $json = & $FFprobe -v error -select_streams v:0 `
        -show_entries 'format=duration:stream=width,height,avg_frame_rate,duration,nb_frames' `
        -of json -- "$Path" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw "ffprobe no pudo leer: $Path" }
    $data = $json | ConvertFrom-Json
    $stream = @($data.streams)[0]
    # La duracion del contenedor incluye correctamente la cola de audio/video.
    # Algunos clips TECHE muy cortos declaran pocos frames en la pista, aunque
    # el MP4 completo tenga la duracion correcta.
    $durationText = if ($data.format.duration) { $data.format.duration } else { $stream.duration }
    $duration = 0.0
    if (-not [double]::TryParse([string]$durationText, [Globalization.NumberStyles]::Float, $Invariant, [ref]$duration)) {
        throw "Duracion no disponible: $Path"
    }
    $fps = 0.0
    if ($stream.avg_frame_rate -match '^(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)$' -and [double]$Matches[2] -ne 0) {
        $fps = [double]$Matches[1] / [double]$Matches[2]
    }
    [pscustomobject]@{
        Path = $Path; Duration = $duration; Fps = $fps
        Width = [int]$stream.width; Height = [int]$stream.height
    }
}

function Get-Signature([string] $Path) {
    $item = Get-Item -LiteralPath $Path
    [pscustomobject]@{ Length = $item.Length; LastWriteUtc = $item.LastWriteTimeUtc.ToString('o') }
}

function Test-HasAudio([string] $Path) {
    $value = & $FFprobe -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 -- "$Path" 2>$null
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($value -join '')))
}

function Test-VideoEncoder([string] $Encoder) {
    try {
        & $FFmpeg -hide_banner -v error -f lavfi -i 'color=size=256x256:rate=1:duration=0.1' `
            -frames:v 1 -c:v $Encoder -f null NUL 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

$ErrorLog = "$Output.timesync-error.log"
try {
Remove-Item -LiteralPath $ErrorLog -Force -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "Carpeta inexistente: $Folder" }
if (-not (Test-Path -LiteralPath $Preview -PathType Leaf)) { throw "Preview inexistente: $Preview" }

$previewFull = (Get-Item -LiteralPath $Preview).FullName
$rawCandidates = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction Stop | Where-Object {
    $VideoExtensions -contains $_.Extension.ToLowerInvariant() -and
    $_.FullName -ne $previewFull -and
    $_.Name -notmatch '(?i)TechePrev|proxy|timesync|timefix|complete'
} | Sort-Object Length -Descending)

$previewInfo = Get-MediaInfo $previewFull
$raw = $rawCandidates | Select-Object -First 1
$rawInfo = if ($raw) { Get-MediaInfo $raw.FullName } else { $null }
$targetDuration = if ($rawInfo) { $rawInfo.Duration } else { $previewInfo.Duration }
$difference = $targetDuration - $previewInfo.Duration
$differencePercent = if ($previewInfo.Duration -gt 0) { 100.0 * $difference / $previewInfo.Duration } else { 0.0 }
$needsCorrection = $rawInfo -and ([Math]::Abs($difference) -gt $ToleranceSeconds)
$withinGuard = [Math]::Abs($differencePercent) -le $MaxCorrectionPercent

if ($needsCorrection -and -not $withinGuard) {
    throw ('La diferencia es {0:N3}s ({1:N3}%), superior al limite de {2:N1}%. Revise el emparejamiento: {3}' -f `
        $difference, $differencePercent, $MaxCorrectionPercent, $raw.FullName)
}

$state = [ordered]@{
    Version = 3
    ClipId = Split-Path $Folder -Leaf
    MainPath = if ($raw) { $raw.FullName } else { $null }
    MainFileName = if ($raw) { $raw.Name } else { $null }
    ProxyPath = [IO.Path]::GetFullPath($Output)
    ProxyFileName = [IO.Path]::GetFileName($Output)
    Preview = $previewFull
    PreviewSignature = Get-Signature $previewFull
    Reference8K = if ($raw) { $raw.FullName } else { $null }
    ReferenceSignature = if ($raw) { Get-Signature $raw.FullName } else { $null }
    PreviewDuration = $previewInfo.Duration
    TargetDuration = $targetDuration
    DifferenceSeconds = $difference
    DifferencePercent = $differencePercent
    Corrected = [bool]$needsCorrection
    ToleranceSeconds = $ToleranceSeconds
}

$canKeep = $false
if ((Test-Path -LiteralPath $Output -PathType Leaf) -and (Test-Path -LiteralPath $Sidecar -PathType Leaf)) {
    try {
        $old = Get-Content -LiteralPath $Sidecar -Raw | ConvertFrom-Json
        $canKeep = ($old.Version -eq $state.Version -and
            $old.PreviewSignature.Length -eq $state.PreviewSignature.Length -and
            $old.PreviewSignature.LastWriteUtc -eq $state.PreviewSignature.LastWriteUtc -and
            [string]$old.Reference8K -eq [string]$state.Reference8K -and
            [string]$old.ReferenceSignature.Length -eq [string]$state.ReferenceSignature.Length -and
            [string]$old.ReferenceSignature.LastWriteUtc -eq [string]$state.ReferenceSignature.LastWriteUtc -and
            [Math]::Abs([double]$old.TargetDuration - $targetDuration) -le 0.001)
    } catch { $canKeep = $false }
}

# Adopta proxies nuevos que ya tienen la duracion y dimensiones del preview.
# Asi, instalar esta mejora no obliga a renderizar nuevamente todo el archivo.
if (-not $canKeep -and (Test-Path -LiteralPath $Output -PathType Leaf)) {
    try {
        $existingInfo = Get-MediaInfo $Output
        $adoptionTolerance = [Math]::Max($ToleranceSeconds, 1.0 / 30.0 + 0.01)
        if ($existingInfo.Width -eq $previewInfo.Width -and $existingInfo.Height -eq $previewInfo.Height -and
            [Math]::Abs($existingInfo.Duration - $targetDuration) -le $adoptionTolerance) {
            $state.OutputDuration = $existingInfo.Duration
            $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Sidecar -Encoding UTF8
            $canKeep = $true
            Write-Host ('[ADOPTA] Proxy existente valido: {0}' -f $Output)
        }
    } catch { $canKeep = $false }
}

if ($canKeep) {
    Write-Host ('[KEEP] {0} | desfase={1:+0.000;-0.000;0.000}s' -f (Split-Path $Folder -Leaf), $difference)
    exit 0
}

$outDir = Split-Path -Parent $Output
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$tempOutput = Join-Path $outDir (([IO.Path]::GetFileNameWithoutExtension($Output)) + '.partial.mp4')
Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue

$hasAudio = Test-HasAudio $previewFull

# El preview y el main TECHE empiezan con la misma marca de tiempo. La diferencia
# observada esta al final: nunca se estira ni se acelera el contenido completo.
# Si el preview alcanza o sobra, solo se remultiplexa/recorta con stream copy.
# Unicamente cuando falta tiempo se codifica el preview ligero y se agrega negro
# al final. En CPU se usa ultrafast para evitar velocidades como 0.08x.
$durationArg = $targetDuration.ToString('0.############',$Invariant)
$paddingSeconds = [Math]::Max(0.0, $difference)
if ([Math]::Abs($difference) -le $ToleranceSeconds) {
    $mode = 'COPIA-DIRECTA'
    Copy-Item -LiteralPath $previewFull -Destination $tempOutput -Force
    $args = $null
    $state.CorrectionMode = $mode
    $state.PaddingEndSeconds = 0.0
} elseif ($difference -lt 0) {
    $mode = 'RECORTA-COPIA'
    $args = @('-y','-hide_banner','-loglevel','warning','-stats','-i',$previewFull,
        '-map','0:v:0','-map','0:a?','-c','copy','-t',$durationArg,'-movflags','+faststart',$tempOutput)
    $state.CorrectionMode = $mode
    $state.PaddingEndSeconds = 0.0
} else {
    $mode = 'NEGRO-AL-FINAL'
    $codec = if (Test-VideoEncoder 'h264_nvenc') { 'h264_nvenc' } else { 'libx264' }
    $videoArgs = if ($codec -eq 'h264_nvenc') {
        @('-c:v',$codec,'-preset','p1','-cq','28','-b:v','0')
    } else {
        @('-c:v',$codec,'-preset','ultrafast','-crf','28','-tune','fastdecode')
    }
    $padArg = $paddingSeconds.ToString('0.############',$Invariant)
    $videoFilter = 'tpad=stop_mode=add:color=black:stop_duration=' + $padArg + ',format=yuv420p'
    $args = @('-y','-hide_banner','-loglevel','warning','-stats','-i',$previewFull,
        '-map','0:v:0','-vf',$videoFilter) + $videoArgs + @('-pix_fmt','yuv420p')
    if ($hasAudio) {
        $audioFilter = 'apad=pad_dur=' + $padArg + ',atrim=duration=' + $durationArg
        $args += @('-map','0:a:0','-af',$audioFilter,'-c:a','aac','-b:a','96k')
    } else {
        $args += '-an'
    }
    $args += @('-t',$durationArg,'-movflags','+faststart',$tempOutput)
    $state.CorrectionMode = $mode
    $state.PaddingEndSeconds = $paddingSeconds
    $state.VideoEncoder = $codec
    Write-Host ("[CODEC RAPIDO] {0}" -f $codec)
}

Write-Host ('[{0}] {1} | preview={2:N3}s referencia={3:N3}s desfase={4:+0.000;-0.000;0.000}s' -f `
    $mode, (Split-Path $Folder -Leaf), $previewInfo.Duration, $targetDuration, $difference)
if ($args) {
    & $FFmpeg @args
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg fallo creando $Output" }
}
if (-not (Test-Path -LiteralPath $tempOutput)) { throw "No se pudo crear $Output" }

$outputInfo = Get-MediaInfo $tempOutput
$validationTolerance = [Math]::Max($ToleranceSeconds, 1.0 / 30.0 + 0.01)
if ([Math]::Abs($outputInfo.Duration - $targetDuration) -gt $validationTolerance) {
    Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
    throw ('Proxy invalido: dura {0:N3}s y se esperaban {1:N3}s' -f $outputInfo.Duration, $targetDuration)
}

Move-Item -LiteralPath $tempOutput -Destination $Output -Force
$state.OutputDuration = $outputInfo.Duration
$state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Sidecar -Encoding UTF8
Write-Host ('[OK] {0}' -f $Output)
exit 10
} catch {
    try {
        $errorDir = Split-Path -Parent $ErrorLog
        if ($errorDir -and -not (Test-Path -LiteralPath $errorDir)) {
            New-Item -ItemType Directory -Path $errorDir -Force | Out-Null
        }
        $detail = @(
            "Fecha: $((Get-Date).ToString('o'))"
            "Clip: $(Split-Path $Folder -Leaf)"
            "Preview: $Preview"
            "Output: $Output"
            "Error: $($_.Exception.Message)"
            "Posicion: $($_.InvocationInfo.PositionMessage)"
            "Detalle: $($_ | Out-String)"
        ) -join [Environment]::NewLine
        Set-Content -LiteralPath $ErrorLog -Value $detail -Encoding UTF8
    } catch {}
    Write-Error ("TECHE fallo: {0}. Detalle: {1}" -f $_.Exception.Message, $ErrorLog)
    exit 1
}
