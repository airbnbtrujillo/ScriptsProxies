[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceDir,
    [string]$OutputDir,
    [string]$AutomatorExe,
    [string]$QooCamExe
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$source = (Get-Item -LiteralPath $SourceDir -ErrorAction Stop).FullName
if ($OutputDir -and [IO.Path]::GetFullPath($OutputDir) -ne $source) {
    Write-Host '[QOO-RENDER][AVISO] OutputDir se ignora: QooCam guardara junto a los originales.' -ForegroundColor Yellow
}
$output = Join-Path $source 'KDOutput'

if (-not $AutomatorExe) {
    $AutomatorExe = Join-Path $RepoRoot 'tools\QooCamAutomation\QooCam_VR180_Batch_AntiShake.exe'
}
if (-not (Test-Path -LiteralPath $AutomatorExe -PathType Leaf)) {
    throw "Falta el automatizador QooCam: $AutomatorExe"
}

$originals = @(Get-ChildItem -LiteralPath $source -File -ErrorAction Stop | Where-Object {
    $_.Extension -ieq '.mp4' -and $_.Name -notmatch '(?i)(?:_output|_reframe|_proxy)(?:\(\d+\))?\.mp4$'
})
if ($originals.Count -eq 0) {
    Write-Host '[QOO-RENDER] No hay MP4 originales en el nivel directo; no se abre QooCam.' -ForegroundColor DarkGray
    exit 0
}

if (-not $QooCamExe) {
    $settingsPath = Join-Path $RepoRoot 'config\settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            if ($settings.PSObject.Properties.Name -contains 'QooCamStudioExe') {
                $QooCamExe = [string]$settings.QooCamStudioExe
            }
        } catch {
            Write-Host "[QOO-RENDER][AVISO] No se pudo leer settings.json: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

$arguments = @('--source', $source, '--direct', '--adopt-existing', '--run')
if (-not [string]::IsNullOrWhiteSpace($QooCamExe)) {
    if (-not (Test-Path -LiteralPath $QooCamExe -PathType Leaf)) {
        throw "QooCamStudioExe no existe: $QooCamExe"
    }
    $arguments += @('--qoocam-exe', [IO.Path]::GetFullPath($QooCamExe))
}

Write-Host ("[QOO-RENDER] Originales directos: {0}. Salida: {1}" -f $originals.Count, $output) -ForegroundColor Cyan
Write-Host '[QOO-RENDER] Durante la configuracion deja Windows desbloqueado y no uses el raton.' -ForegroundColor Yellow
& $AutomatorExe @arguments
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
if ($code -ne 0) {
    Write-Host "[QOO-RENDER][ERROR] El automatizador termino con codigo $code; no se iniciaran proxies nuevos." -ForegroundColor Red
}
exit $code
