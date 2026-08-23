[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$Root = (Get-Item -LiteralPath $Root).FullName

function Invoke-PowerShellFile([string]$RelativePath, [string[]]$Arguments = @()) {
    $script = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "No existe: $script" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @Arguments
    return $LASTEXITCODE
}

while ($true) {
    Clear-Host
    Write-Host '=====================================================' -ForegroundColor Cyan
    Write-Host ' SCRIPTS PROXIES - MENU PRINCIPAL' -ForegroundColor Cyan
    Write-Host '=====================================================' -ForegroundColor Cyan
    Write-Host ' 1. Procesar todos los proyectos y camaras'
    Write-Host ' 2. Ejecutar una sola camara'
    Write-Host ' 3. Generar GIFs para un proyecto'
    Write-Host ' 4. Diagnostico (no renderiza)'
    Write-Host ' 5. Actualizar desde GitHub'
    Write-Host ' 6. Herramientas adicionales'
    Write-Host ' 0. Salir'
    Write-Host ''
    $choice = Read-Host 'Selecciona una opcion'

    try {
        switch ($choice) {
            '1' { [void](Invoke-PowerShellFile '00-SISTEMA\ORQUESTADOR-PRINCIPAL.ps1') }
            '2' { [void](Invoke-PowerShellFile '00-SISTEMA\EJECUTAR-UNA-CAMARA.ps1') }
            '3' { [void](Invoke-PowerShellFile '00-SISTEMA\EJECUTAR-GIFS.ps1') }
            '4' { & (Join-Path $Root '00-SISTEMA\DIAGNOSTICO-SCRIPTS.cmd') }
            '5' { & (Join-Path $Root '00-SISTEMA\ACTUALIZAR-SCRIPTS.cmd') }
            '6' {
                Write-Host ''
                Write-Host 'Herramientas disponibles en:' -ForegroundColor Cyan
                Write-Host (Join-Path $Root '03-HERRAMIENTAS')
                Write-Host '  TOOL-01: miniaturas'
                Write-Host '  TOOL-02: recolector de Pics Proxy'
                Write-Host '  TOOL-03: copias de respaldo'
                Write-Host '  TOOL-05: verificador de fila unica'
            }
            '0' { exit 0 }
            default { Write-Host 'Opcion no valida.' -ForegroundColor Yellow }
        }
    } catch {
        Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host ''
    Read-Host 'Presiona ENTER para volver al menu' | Out-Null
}
