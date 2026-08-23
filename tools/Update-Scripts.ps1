[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string] $SourcePath,
    [string] $GitRepository,
    [string] $Branch,
    [switch] $CheckOnly,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
$rootFull = [IO.Path]::GetFullPath($Root)
$settingsPath = Join-Path $rootFull 'config\settings.json'
$settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $SourcePath) { $SourcePath = [string]$settings.CloudMirror }
if (-not $GitRepository) { $GitRepository = [string]$settings.GitRepository }
if (-not $Branch) { $Branch = if ($settings.GitBranch) { [string]$settings.GitBranch } else { 'main' } }

$tempRoot = $null
$sourceRoot = $null
try {
    if ($SourcePath) {
        $sourceRoot = [IO.Path]::GetFullPath($SourcePath)
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "CloudMirror no existe: $sourceRoot" }
    } elseif ($GitRepository) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git no esta instalado o no esta en PATH.' }
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("f-scripts-update-{0}" -f [guid]::NewGuid().ToString('N'))
        & git clone --depth 1 --branch $Branch -- $GitRepository $tempRoot
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo descargar el repositorio.' }
        $sourceRoot = $tempRoot
    } else {
        throw 'No hay origen configurado. Completa CloudMirror o GitRepository en config\settings.json.'
    }

    $sourceManifestPath = Join-Path $sourceRoot 'config\scripts.manifest.json'
    if (-not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) { throw "El origen no contiene un manifiesto valido: $sourceManifestPath" }
    $sourceManifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
    $localManifestPath = Join-Path $rootFull 'config\scripts.manifest.json'
    $localManifest = if (Test-Path $localManifestPath) { Get-Content $localManifestPath -Raw | ConvertFrom-Json } else { $null }
    Write-Host "Version instalada: $($localManifest.version)"
    Write-Host "Version disponible: $($sourceManifest.version)"

    $sourceTest = Join-Path $sourceRoot 'tools\Test-Scripts.ps1'
    if (-not (Test-Path -LiteralPath $sourceTest)) { throw 'El origen no incluye tools\Test-Scripts.ps1.' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sourceTest -Root $sourceRoot -Quick
    if ($LASTEXITCODE -ge 2) { throw 'La version descargada no paso el diagnostico; no se aplico nada.' }

    if ($CheckOnly -or -not $Apply) {
        if ($sourceManifest.version -eq $localManifest.version) { Write-Host '[UPDATE] Ya tienes la version declarada mas reciente.' }
        else { Write-Host '[UPDATE] Hay una version diferente disponible. Ejecuta con -Apply para instalarla.' }
        exit 0
    }

    $backupRoot = Join-Path $rootFull ("archive\updates\{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($entry in $sourceManifest.files) {
        $relative = [string]$entry.path
        $source = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relative))
        $destination = [IO.Path]::GetFullPath((Join-Path $rootFull $relative))
        if (-not $source.StartsWith(($sourceRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw "Ruta fuera del origen: $relative" }
        if (-not $destination.StartsWith(($rootFull.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw "Ruta fuera del destino: $relative" }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            if ($entry.required) { throw "Falta archivo requerido en origen: $relative" }
            continue
        }
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $backup = Join-Path $backupRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backup -Force
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    Copy-Item -LiteralPath $sourceManifestPath -Destination $localManifestPath -Force
    $sourceVersion = Join-Path $sourceRoot 'VERSION.txt'
    if (Test-Path $sourceVersion) { Copy-Item -LiteralPath $sourceVersion -Destination (Join-Path $rootFull 'VERSION.txt') -Force }
    Write-Host "[UPDATE] Actualizacion instalada. Respaldo: $backupRoot" -ForegroundColor Green
} finally {
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        $tempFull = [IO.Path]::GetFullPath($tempRoot)
        $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($tempFull.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $tempFull) -like 'f-scripts-update-*') {
            Remove-Item -LiteralPath $tempFull -Recurse -Force
        }
    }
}
