param(
    # Carpeta base desde donde analizar en profundidad. Si no se pasa, usa la carpeta donde está el script.
    [string]$RootPath = $PSScriptRoot,

    # Divisor de escala. 4 = 1/4 de resolución
    [int]$Divisor = 4,

    # Calidad JPEG (más alto = más comprimido). 5 suele verse bien y pesar poco.
    [int]$JpegQ = 5,

    # Rehacer sólo si la fuente es más nueva que el PROXY existente
    [switch]$UpdateIfNewer
)

$ErrorActionPreference = 'Stop'

function Find-FFmpeg {
    param([string]$HintPath = "C:\ffmpeg\ffmpeg.exe")
    try {
        $cmd = Get-Command ffmpeg -ErrorAction Stop
        return $cmd.Source
    } catch {
        if (Test-Path -LiteralPath $HintPath) { return $HintPath }
        throw "No se encontró ffmpeg en PATH ni en '$HintPath'. Instálalo o ajusta la variable HintPath."
    }
}

function Get-ProjectInfo {
    param([string]$Path)
    $resolved = Resolve-Path -LiteralPath $Path
    $leaf = Split-Path -Leaf $resolved

    # Si la carpeta actual parece una fecha (YYYY_MM_DD o YYYY-MM-DD), sube un nivel
    if ($leaf -match '^\d{4}([_-])\d{2}\1\d{2}$') {
        $projectRoot = Split-Path -Parent $resolved
    } else {
        $projectRoot = $resolved
    }
    $projectName = Split-Path -Leaf $projectRoot
    return @{ Root = $projectRoot; Name = $projectName }
}

function Get-RelativePath {
    param(
        [string]$Base,
        [string]$Target
    )
    # Compatible con Windows PowerShell 5.1
    $baseUri   = New-Object System.Uri(($Base.TrimEnd('\') + '\'))
    $targetUri = New-Object System.Uri(($Target.TrimEnd('\') + '\'))
    $rel = $baseUri.MakeRelativeUri($targetUri).ToString() -replace '/', '\'
    if ($rel -eq '') { return '' }
    return $rel.TrimEnd('\')
}

# --- Inicio ---
$ffmpeg = Find-FFmpeg
if (-not (Test-Path -LiteralPath $RootPath)) {
    throw "No existe la ruta base: $RootPath"
}

$proj = Get-ProjectInfo -Path $RootPath
$projectRoot = $proj.Root
$projectName = $proj.Name

$destRoot = Join-Path $projectRoot "$projectName Pics"
if (-not (Test-Path -LiteralPath $destRoot)) {
    New-Item -ItemType Directory -Path $destRoot | Out-Null
}

Write-Host "==== PicsProxyCollector ===="
Write-Host "Proyecto : $projectName"
Write-Host "Raíz     : $projectRoot"
Write-Host "Analiza  : $RootPath (recursivo)"
Write-Host "Salida   : $destRoot"
Write-Host "ffmpeg   : $ffmpeg"
Write-Host "Escala   : 1/$Divisor   | JPEG Q: $JpegQ"
if ($UpdateIfNewer) { Write-Host "Modo     : UpdateIfNewer (rehace si la fuente es más nueva)" }

# Patrones a incluir
$patterns = @('*.jpg','*.jpeg','*.jpge','*.png')

# Evitar re-procesar lo que ya está dentro de "<Proyecto> Pics"
$excludePath = $destRoot.TrimEnd('\') + '\'

# Contadores
[int]$total = 0
[int]$skipped = 0
[int]$done = 0
[int]$updated = 0
[int]$errored = 0

# Log
$logFile = Join-Path $destRoot "_pics_proxy_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
"RUN $(Get-Date) | Root=$RootPath | Dest=$destRoot | Divisor=$Divisor | Q=$JpegQ | UpdateIfNewer=$UpdateIfNewer" | Out-File -Encoding UTF8 $logFile

Get-ChildItem -Path $RootPath -Recurse -Include $patterns -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike "$excludePath*" } |
    ForEach-Object {
        $total++

        $src = $_
        $srcDir = $src.DirectoryName

        # Carpeta relativa respecto a RootPath
        $relDir = Get-RelativePath -Base $RootPath -Target $srcDir
        if ([string]::IsNullOrWhiteSpace($relDir) -or $relDir -eq '.') { $relDir = '' }

        # Carpeta de salida (mantener estructura)
        $outDir = if ($relDir) { Join-Path $destRoot $relDir } else { $destRoot }
        if (-not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($src.Name)
        $outName  = "$baseName PROXY.jpg"
        $outPath  = Join-Path $outDir $outName

        # Saltar si ya existe (a menos que se pida UpdateIfNewer y la fuente sea más nueva)
        if (Test-Path -LiteralPath $outPath) {
            if ($UpdateIfNewer) {
                $srcTime = (Get-Item -LiteralPath $src.FullName).LastWriteTimeUtc
                $outTime = (Get-Item -LiteralPath $outPath).LastWriteTimeUtc
                if ($srcTime -le $outTime) {
                    $skipped++
                    "SKIP (up-to-date): $($src.FullName) -> $outPath" | Out-File -Append -Encoding UTF8 $logFile
                    return
                }
                # Rehacer (fuente más nueva)
            } else {
                $skipped++
                "SKIP (exists): $($src.FullName) -> $outPath" | Out-File -Append -Encoding UTF8 $logFile
                return
            }
        }

        # Construir filtro de escala
        $scale = "scale=iw/$Divisor:ih/$Divisor:flags=lanczos"
        # Asegurar salida sin alpha (JPG no soporta alpha); format=rgb24 evita fondos raros
        $vf = "$scale,format=rgb24"

        # Ejecutar ffmpeg
        $args = @(
            "-hide_banner", "-loglevel", "error",
            "-y",                                   # sobreescribe si corresponde
            "-i", $src.FullName,
            "-vf", $vf,
            "-q:v", $JpegQ,
            "-frames:v", "1",                       # si fuese animado, sólo 1er frame; para fotos no afecta
            $outPath
        )

        try {
            & $ffmpeg @args
            if ($LASTEXITCODE -ne 0) { throw "ffmpeg salió con código $LASTEXITCODE" }

            if (Test-Path -LiteralPath $outPath) {
                # Ajustar fecha de salida a la de fuente para facilitar comparaciones futuras
                (Get-Item -LiteralPath $outPath).LastWriteTime = (Get-Item -LiteralPath $src.FullName).LastWriteTime
                if ($UpdateIfNewer -and (Test-Path -LiteralPath $outPath)) {
                    $updated++
                    "UPDATED: $($src.FullName) -> $outPath" | Out-File -Append -Encoding UTF8 $logFile
                } else {
                    $done++
                    "DONE: $($src.FullName) -> $outPath" | Out-File -Append -Encoding UTF8 $logFile
                }
            } else {
                throw "Salida no encontrada tras ffmpeg"
            }
        }
        catch {
            $errored++
            "ERROR: $($src.FullName) -> $outPath | $_" | Out-File -Append -Encoding UTF8 $logFile
            Write-Warning "ERROR procesando: $($src.FullName) | $_"
        }
    }

Write-Host "===== RESUMEN ====="
Write-Host ("Total    : {0}" -f $total)
Write-Host ("Hechos   : {0}" -f $done)
Write-Host ("Actualiz.: {0}" -f $updated)
Write-Host ("Saltados : {0}" -f $skipped)
Write-Host ("Errores  : {0}" -f $errored)
Write-Host ("Log      : $logFile")
