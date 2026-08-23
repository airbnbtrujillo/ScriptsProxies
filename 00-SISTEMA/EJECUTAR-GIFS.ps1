[CmdletBinding()]
param([string]$TargetPath)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$gifRoot = Join-Path $RepoRoot '02-GIFS'
if ([string]::IsNullOrWhiteSpace($TargetPath)) {
    $TargetPath = Read-Host 'Ruta del proyecto para generar GIFs (local o de red)'
}
$TargetPath = $TargetPath.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) { throw "La carpeta no existe o no es accesible: $TargetPath" }
$target = (Get-Item -LiteralPath $TargetPath).FullName
$cmdName = 'GIF-01-EJECUTAR-SEPARADOR.cmd'
$psName = 'GIF-02-SEPARAR-AUTOMATICO.ps1'
foreach ($name in @($cmdName,$psName)) {
    $source = Join-Path $gifRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Falta el archivo central: $source" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $target $name) -Force
}
Write-Host "[GIF] Ejecutando en $target" -ForegroundColor Green
& $env:ComSpec /d /c ('call "{0}"' -f (Join-Path $target $cmdName))
exit $LASTEXITCODE
