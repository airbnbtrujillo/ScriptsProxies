[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [switch] $Quick,
    [string] $JsonOut
)

$ErrorActionPreference = 'Stop'
$rootFull = [IO.Path]::GetFullPath($Root)
$manifestPath = Join-Path $rootFull 'config\scripts.manifest.json'
$results = [Collections.Generic.List[object]]::new()

function Add-Result([string] $Level, [string] $Check, [string] $Message, [string] $Path = '') {
    $results.Add([pscustomobject]@{ Level = $Level; Check = $Check; Message = $Message; Path = $Path })
}

function Find-Executable([string] $Name, [string[]] $Fallbacks = @()) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($fallback in $Fallbacks) {
        if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    }
    return $null
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Add-Result ERROR Manifest 'Falta config\scripts.manifest.json.' $manifestPath
} else {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Add-Result OK Manifest ("Version declarada: {0}" -f $manifest.version) $manifestPath
    } catch {
        Add-Result ERROR Manifest ("JSON invalido: {0}" -f $_.Exception.Message) $manifestPath
    }
}

if ($manifest) {
    foreach ($entry in $manifest.files) {
        $path = Join-Path $rootFull ([string]$entry.path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-Result ($(if ($entry.required) { 'ERROR' } else { 'WARN' })) File ("Falta: {0}" -f $entry.role) $path
            continue
        }
        Add-Result OK File ([string]$entry.role) $path
        if ([IO.Path]::GetExtension($path) -ieq '.ps1') {
            $tokens = $null
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
            foreach ($parseError in @($parseErrors)) {
                Add-Result ERROR PowerShell ("Linea {0}: {1}" -f $parseError.Extent.StartLineNumber, $parseError.Message) $path
            }
        }
        if ([IO.Path]::GetExtension($path) -in @('.bat', '.cmd')) {
            $firstMeaningful = Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -First 1
            if ($firstMeaningful -notmatch '^\s*@?echo\s+off') {
                Add-Result WARN Batch 'No comienza con @echo off; revisa salida accidental.' $path
            }
        }
    }
}

$ffmpeg = Find-Executable ffmpeg @('C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffmpeg.exe', 'C:\ffmpeg\ffmpeg.exe')
$ffprobe = Find-Executable ffprobe @('C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffprobe.exe', 'C:\ffmpeg\ffprobe.exe')
if ($ffmpeg) { Add-Result OK Tool 'ffmpeg disponible.' $ffmpeg } else { Add-Result ERROR Tool 'No se encontro ffmpeg.' }
if ($ffprobe) { Add-Result OK Tool 'ffprobe disponible.' $ffprobe } else { Add-Result ERROR Tool 'No se encontro ffprobe.' }
if ($ffmpeg) {
    $nvencWorks = $false
    try {
        & $ffmpeg -hide_banner -v error -f lavfi -i 'color=size=256x256:rate=1:duration=0.1' `
            -frames:v 1 -c:v h264_nvenc -f null NUL 2>$null
        $nvencWorks = ($LASTEXITCODE -eq 0)
    } catch { $nvencWorks = $false }
    if ($nvencWorks) {
        Add-Result OK Tool 'NVIDIA NVENC funciona con una codificacion real.' $ffmpeg
    } else {
        Add-Result WARN Tool 'NVIDIA NVENC no esta operativo; TECHE cambiara automaticamente a CPU.' $ffmpeg
    }
}
foreach ($tool in @('powershell.exe', 'cmd.exe')) {
    $found = Find-Executable $tool
    if ($found) { Add-Result OK Tool "$tool disponible." $found } else { Add-Result ERROR Tool "No se encontro $tool." }
}
$handbrake = Find-Executable HandBrakeCLI
if ($handbrake) { Add-Result OK Tool 'HandBrakeCLI disponible.' $handbrake } else { Add-Result WARN Tool 'HandBrakeCLI no esta en PATH; solo afecta funciones que lo necesiten.' }

$settingsPath = Join-Path $rootFull 'config\settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$settings.CloudMirror) -and [string]::IsNullOrWhiteSpace([string]$settings.GitRepository)) {
            Add-Result WARN Cloud 'Actualizacion en nube aun no configurada.' $settingsPath
        } else {
            Add-Result OK Cloud 'Origen de actualizacion configurado.' $settingsPath
        }
    } catch {
        Add-Result ERROR Settings ("JSON invalido: {0}" -f $_.Exception.Message) $settingsPath
    }
}

$errors = @($results | Where-Object Level -eq ERROR).Count
$warnings = @($results | Where-Object Level -eq WARN).Count
$oks = @($results | Where-Object Level -eq OK).Count

if (-not $Quick) {
    $results | Sort-Object @{Expression={switch($_.Level){'ERROR'{0};'WARN'{1};default{2}}}}, Check, Path | Format-Table Level,Check,Message,Path -AutoSize -Wrap
} else {
    $results | Where-Object Level -in @('ERROR','WARN') | Format-Table Level,Check,Message,Path -AutoSize -Wrap
}
Write-Host ("[DIAGNOSTICO] OK={0} Avisos={1} Errores={2}" -f $oks, $warnings, $errors) -ForegroundColor $(if ($errors) {'Red'} elseif ($warnings) {'Yellow'} else {'Green'})

if (-not $Quick) {
    if (-not $JsonOut) {
        $logDir = Join-Path $rootFull 'logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $JsonOut = Join-Path $logDir ("diagnostico_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        Root = $rootFull
        Version = if ($manifest) { $manifest.version } else { $null }
        Summary = @{ OK = $oks; Warnings = $warnings; Errors = $errors }
        Results = $results
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
    Write-Host "[DIAGNOSTICO] Reporte: $JsonOut"
}

if ($errors) { exit 2 }
if ($warnings) { exit 1 }
exit 0
