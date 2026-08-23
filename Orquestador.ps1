# Orquestador.ps1
# Carga el helper, lanza BATs con watchdog y espera ENTER (auto o manual).

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# Log principal del orquestador
$LogDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$MainLog = Join-Path $LogDir "orquestador_$ts.log"
Start-Transcript -LiteralPath $MainLog -Append | Out-Null
Write-Host "[MAIN] Log general: $MainLog"

# Cargar helper
$helper = Join-Path $PSScriptRoot 'Watchdog-BAT-AutoENTER.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    Write-Host "[ERROR] No se encontro el helper: $helper"
    Stop-Transcript | Out-Null
    exit 1
}
. $helper

# Config comun
$CheckMinutes = 3
$AlsoWatch = @('ffmpeg','cmd','ffprobe','HandBrakeCLI','powershell')

# Ejemplo: lanzar VUZE
$batVuze    = Join-Path $PSScriptRoot 'VUZE RAW Proxy 960x960_20fps.bat'
$batVuzeLog = Join-Path $LogDir "VUZE_$ts.txt"

$null = Invoke-BatAndAutoEnter -BatPath $batVuze `
    -CheckMinutes $CheckMinutes `
    -AlsoWatch $AlsoWatch `
    -LogFile $batVuzeLog `
    -VerboseWatch

Write-Host "[FLOW] Waiting for ENTER (auto or manual) to continue..."
$null = Read-Host
Write-Host "[FLOW] Continue..."
Write-Host "[FLOW] BAT log: $batVuzeLog"

# (Opcional) Lanzar otro BAT, por ejemplo TECHE
# $batTeche    = Join-Path $PSScriptRoot 'TECHE Proxy.bat'
# $batTecheLog = Join-Path $LogDir "TECHE_$ts.txt"
# $null = Invoke-BatAndAutoEnter -BatPath $batTeche -CheckMinutes $CheckMinutes -AlsoWatch $AlsoWatch -LogFile $batTecheLog -VerboseWatch
# Write-Host "[FLOW] Waiting for ENTER (auto or manual) to continue..."
# $null = Read-Host
# Write-Host "[FLOW] Continue..."
# Write-Host "[FLOW] BAT log: $batTecheLog"

Stop-Transcript | Out-Null
Read-Host "FIN - Presiona ENTER para cerrar"
