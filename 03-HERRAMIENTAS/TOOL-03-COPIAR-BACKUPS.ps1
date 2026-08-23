# Collect-RawProxyComplete.ps1
# Recorre solo 1 nivel de subcarpetas y copia:
#  - MP4 cuyo nombre contenga "RAW PROXY COMPLETE" (variantes admitidas)
#  - Carpeta GIFs_split completa
# Crea la misma estructura (por subcarpeta) en el destino.

param(
    [string]$SourceRoot,
    [string]$DestRoot
)

$ErrorActionPreference = 'Stop'

function Resolve-Folder([string]$PromptText, [string]$DefaultIfEmpty) {
    $path = Read-Host $PromptText
    if ([string]::IsNullOrWhiteSpace($path)) {
        if ($DefaultIfEmpty) { $path = $DefaultIfEmpty }
        else {
            Write-Host "[ERROR] Ruta no proporcionada." -ForegroundColor Red
            exit 1
        }
    }
    try {
        return (Resolve-Path -LiteralPath $path).Path
    } catch {
        Write-Host "[ERROR] No existe la ruta: $path" -ForegroundColor Red
        exit 1
    }
}

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Resolve-Folder "Ruta ORIGEN (raíz a escanear) [ENTER = carpeta actual]" ((Get-Location).Path)
} else {
    $SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
}

if ([string]::IsNullOrWhiteSpace($DestRoot)) {
    $DestRoot = Resolve-Folder "Ruta DESTINO (donde se copiará)" $null
} else {
    $DestRoot = (Resolve-Path -LiteralPath $DestRoot).Path
}

# Crea destino si no existe
if (-not (Test-Path -LiteralPath $DestRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $DestRoot | Out-Null
}

Write-Host "== INICIO ==" -ForegroundColor Cyan
Write-Host "Origen : $SourceRoot"
Write-Host "Destino: $DestRoot"
Write-Host ""

# Patrón para nombres tipo:
# "RAW PROXY COMPLETE", "RAWPROXYCOMPLETE", "RAW_Proxy_Complete", etc. (insensible a mayúsculas)
$rawProxyPattern = '(?i)RAW(\s*|_)?PROXY(\s*|_)?COMPLETE'

# Contadores
$projects   = 0
$mp4Copied  = 0
$mp4Skipped = 0
$gifCopied  = 0
$gifSkipped = 0

function Copy-IfNeeded {
    param(
        [Parameter(Mandatory=$true)] [System.IO.FileInfo] $SrcFile,
        [Parameter(Mandatory=$true)] [string] $DestFolder
    )
    if (-not (Test-Path -LiteralPath $DestFolder)) {
        New-Item -ItemType Directory -Path $DestFolder | Out-Null
    }
    $destFile = Join-Path $DestFolder $SrcFile.Name
    if (Test-Path -LiteralPath $destFile) {
        $df = Get-Item -LiteralPath $destFile
        # Compara por tamaño y marca de tiempo
        if ($df.Length -eq $SrcFile.Length -and $df.LastWriteTimeUtc -eq $SrcFile.LastWriteTimeUtc) {
            return $false  # igual -> saltar
        }
    }
    Copy-Item -LiteralPath $SrcFile.FullName -Destination $destFile -Force
    # Mantener marca de tiempo del original (útil para detectar cambios futuros)
    (Get-Item -LiteralPath $destFile).LastWriteTimeUtc = $SrcFile.LastWriteTimeUtc
    return $true
}

# Solo 1 nivel de profundidad: subcarpetas inmediatas
$subdirs = Get-ChildItem -LiteralPath $SourceRoot -Directory | Sort-Object Name

foreach ($dir in $subdirs) {
    $projects++
    $projectName = $dir.Name
    $destProject = Join-Path $DestRoot $projectName
    if (-not (Test-Path -LiteralPath $destProject)) {
        New-Item -ItemType Directory -Path $destProject | Out-Null
    }

    Write-Host ">> [$projectName]" -ForegroundColor Yellow

    # 1) Copiar MP4 con nombre que calce el patrón
    $mp4s = Get-ChildItem -LiteralPath $dir.FullName -File -Filter *.mp4 |
            Where-Object { $_.BaseName -match $rawProxyPattern }

    if ($mp4s.Count -gt 0) {
        foreach ($f in $mp4s) {
            $copied = Copy-IfNeeded -SrcFile $f -DestFolder $destProject
            if ($copied) {
                $mp4Copied++
                Write-Host "   [MP4] Copiado: $($f.Name)"
            } else {
                $mp4Skipped++
                Write-Host "   [MP4] Saltado (ya existe igual): $($f.Name)" -ForegroundColor DarkGray
            }
        }
    } else {
        Write-Host "   [MP4] No se encontraron archivos que coincidan con 'RAW PROXY COMPLETE'." -ForegroundColor DarkGray
    }

    # 2) Copiar carpeta GIFs_split completa (si existe)
    $gifSrc = Join-Path $dir.FullName 'GIFs_split'
    if (Test-Path -LiteralPath $gifSrc -PathType Container) {
        $gifDst = Join-Path $destProject 'GIFs_split'
        # Si ya existe, igualmente copiamos recursivo (sobrescribe archivos necesarios)
        Copy-Item -LiteralPath $gifSrc -Destination $gifDst -Recurse -Force -Container
        $gifCopied++
        Write-Host "   [GIFs] Copiada carpeta GIFs_split -> $gifDst"
    } else {
        $gifSkipped++
        Write-Host "   [GIFs] No existe carpeta GIFs_split en este proyecto." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "== RESUMEN ==" -ForegroundColor Cyan
Write-Host "Proyectos procesados     : $projects"
Write-Host "MP4 copiados             : $mp4Copied"
Write-Host "MP4 saltados (sin cambio): $mp4Skipped"
Write-Host "GIFs_split copiadas      : $gifCopied"
Write-Host "GIFs_split ausentes      : $gifSkipped"
Write-Host "Salida en: $DestRoot"
