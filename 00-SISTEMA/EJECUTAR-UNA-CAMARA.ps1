[CmdletBinding()]
param(
    [ValidateRange(1,9)][int]$CameraId,
    [string]$TargetPath,
    [switch]$ListOnly,
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$cameraRoot = Join-Path $RepoRoot '01-CAMARAS'
$cameras = @(
    [pscustomobject]@{ Id=1; Name='VUZE';       Script='CAM-01-VUZE-PROXY-960x960-20fps.bat'; Companion=$null },
    [pscustomobject]@{ Id=2; Name='QOOCAM';     Script='CAM-02-QOOCAM-PROXY.bat'; Companion=$null },
    [pscustomobject]@{ Id=3; Name='GoPro';      Script='CAM-03-GOPRO-PROXY.bat'; Companion=$null },
    [pscustomobject]@{ Id=4; Name='Gear 360';   Script='CAM-04-GEAR360-PROXY.bat'; Companion=$null },
    [pscustomobject]@{ Id=5; Name='DJI OSMO';   Script='CAM-05-DJI-OSMO-PROXY-960x960-20fps.bat'; Companion=$null },
    [pscustomobject]@{ Id=6; Name='Insta EVO';  Script='CAM-06-INSTA-EVO-PROXY-960x960-20fps.bat'; Companion=$null },
    [pscustomobject]@{ Id=7; Name='Tarsier';    Script='CAM-07-TARSIER-PROXY.bat'; Companion=$null },
    [pscustomobject]@{ Id=8; Name='TECHE';      Script='CAM-08-TECHE-PROXY.bat'; Companion='CAM-08-TECHE-CORREGIR-TIEMPO.ps1' },
    [pscustomobject]@{ Id=9; Name='Insta GO 3'; Script='CAM-09-INSTA-GO3-PROXY.bat'; Companion=$null }
)

Write-Host 'CAMARAS DISPONIBLES' -ForegroundColor Cyan
$cameras | ForEach-Object { Write-Host (" {0}. {1}" -f $_.Id, $_.Name) }
if ($ListOnly) { exit 0 }

if (-not $CameraId) {
    $answer = Read-Host 'Numero de camara'
    if ($answer -notmatch '^\d+$') { throw 'Numero de camara no valido.' }
    $CameraId = [int]$answer
}
$camera = $cameras | Where-Object Id -eq $CameraId | Select-Object -First 1
if (-not $camera) { throw "No existe la camara numero $CameraId." }

if ([string]::IsNullOrWhiteSpace($TargetPath)) {
    Write-Host 'Indica la carpeta propia de la camara (por ejemplo 100GOPRO, CAM_001 o una ruta de red).' -ForegroundColor Yellow
    $TargetPath = Read-Host 'Ruta de la carpeta de camara'
}
$TargetPath = $TargetPath.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) { throw "La carpeta no existe o no es accesible: $TargetPath" }
$target = (Get-Item -LiteralPath $TargetPath).FullName

$source = Join-Path $cameraRoot $camera.Script
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Falta el script central: $source" }
$destination = Join-Path $target $camera.Script
Copy-Item -LiteralPath $source -Destination $destination -Force

if ($camera.Id -eq 2) {
    $qooRenderer = Join-Path $cameraRoot 'CAM-02-QOOCAM-RENDER.ps1'
    if (-not (Test-Path -LiteralPath $qooRenderer -PathType Leaf)) { throw "Falta el integrador QooCam: $qooRenderer" }
    Copy-Item -LiteralPath $qooRenderer -Destination (Join-Path $target 'CAM-02-QOOCAM-RENDER.ps1') -Force
}

if ($camera.Companion) {
    $companionSource = Join-Path $cameraRoot $camera.Companion
    if (-not (Test-Path -LiteralPath $companionSource -PathType Leaf)) { throw "Falta el complemento: $companionSource" }
    Copy-Item -LiteralPath $companionSource -Destination (Join-Path $target $camera.Companion) -Force
}

if ($PrepareOnly) {
    Write-Host ("[CAMARA] Preparada {0} en {1}; no se inicio el render." -f $camera.Name, $target) -ForegroundColor Green
    exit 0
}

Write-Host ("[CAMARA] Ejecutando solo {0} en {1}" -f $camera.Name, $target) -ForegroundColor Green
if ($camera.Id -eq 2) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $qooRenderer -SourceDir $target -OutputDir (Join-Path $target 'KDOutput')
    if ($LASTEXITCODE -ne 0) {
        Write-Host '[CAMARA][ERROR] Falló el render QooCam; no se crearán proxies con resultados incompletos.' -ForegroundColor Red
        exit $LASTEXITCODE
    }
    $integrity = Join-Path $RepoRoot 'tools\Test-ProxyIntegrity.ps1'
    $project = Split-Path -Parent $target
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $integrity -ProjectPath $project -Repair
    if ($LASTEXITCODE -ge 2) {
        Write-Host '[CAMARA][ERROR] La validacion posterior al render fallo; no se crearán proxies.' -ForegroundColor Red
        exit $LASTEXITCODE
    }
}
& $env:ComSpec /d /c ('call "{0}"' -f $destination)
exit $LASTEXITCODE
