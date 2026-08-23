# Split-GIF-AutoByFolder.ps1
# Tramos 10 min | x60 | 30 fps | escala 1/6 (~160 px)
# Overlay: reloj HH:MM:SS (tiempo absoluto acelerado)
# Shrink si >4.7MB
$ErrorActionPreference = 'Continue'

# ===== Entrada automÃ¡tica (carpeta actual del script) =====
$scriptPath = $MyInvocation.MyCommand.Path
$root       = Split-Path -Parent $scriptPath

if (-not (Test-Path -LiteralPath $root)) {
    Write-Host "[ERROR] No existe la ruta base ($root)."
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    exit 1
}
$project = Split-Path -Leaf $root

# ===== Config =====
$ChunkSec = 600          # 10 min
$Speed    = 60           # x60
$Fps      = 30
$ScaleDiv = 6
$Colors   = 96
$Bayer    = 4
$OutRoot  = Join-Path $root "GIFs_split"

# ===== Shrink =====
$MaxMB           = 4.7
$MaxBytes        = [int64](1024*1024*$MaxMB)
$ShrinkEnable    = $true
$ShrinkKeepScale = $true
$ShrinkScaleDiv  = 8
$ShrinkKeepFps   = $true
$ShrinkColors    = 64
$ShrinkColors2   = 40

# ===== Chequeos =====
if (-not (Get-Command ffmpeg  -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] ffmpeg no esta en PATH"
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    exit 1
}
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] ffprobe no esta en PATH"
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    exit 1
}
New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null

# ===== Helpers =====

function HMS([int]$sec) {
    [TimeSpan]::FromSeconds($sec).ToString("hh\:mm\:ss")
}

# Detecta tipo de cÃ¡mara / fuente para nombrar carpeta destino
function Get-CamTag([string]$name) {
    if     ($name -match '(?i)gopro')        { return 'GIF GOPRO' }
    elseif ($name -match '(?i)gear[\s\-]*360'){ return 'GIF GEAR 360' }
    elseif ($name -match '(?i)vuze')         { return 'GIF VUZE' }
    elseif ($name -match '(?i)teche')        { return 'GIF TECHE' }
    elseif ($name -match '(?i)dji[\s\-_]*osmo|osmo') { return 'GIF DJI OSMO' }
    elseif ($name -match '(?i)insta')        { return 'GIF INSTA' }
    elseif ($name -match '(?i)tarsier')      { return 'GIF TARSIER' }
    elseif ($name -match '(?i)qoocam')       { return 'GIF QOOCAM' }
    else                                     { return 'MISC' }
}

# Crea las carpetas de GIF que correspondan si detecta renders finales GOPRO / GEAR360 / otros
function Ensure-GifFolders() {
    $camFolders = @{}

    $renderPatterns = @(
        "*GOPRO RAW PROXY Complete.*",
        "*GEAR 360 RAW PROXY Complete.*",
        "*VUZE RAW PROXY*.*",
        "*TECHE RAW Proxy Complete.*",
        "*QOOCAM*.*",
        "*TARSIER*.*",
        "*DJI OSMO RAW Proxy Complete.*",
        "*DJI*OSMO*.*",
        "*INSTA*.*"
    )

    $found = @()
    foreach ($pat in $renderPatterns) {
        $found += Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like $pat -and $_.Extension -match '^\.(mp4|mov|mkv)$' }
    }
    $found = $found | Sort-Object FullName -Unique

    foreach ($f in $found) {
        $base   = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $camTag = Get-CamTag $base
        $dest   = Join-Path $OutRoot $camTag
        if (-not $camFolders.ContainsKey($dest)) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            $camFolders[$dest] = $true
            Write-Host ("[SETUP] Carpeta de GIF asegurada: {0}" -f $dest)
        }
    }
}

# Â¿Este video ya fue procesado antes?
# Si ya hay GIFs que empiezan con el mismo nombre base en la carpeta correcta, lo saltamos.
function Is-VideoProcessed([string]$srcPath) {
    $base   = [IO.Path]::GetFileNameWithoutExtension($srcPath)
    $camTag = Get-CamTag $base
    $outDir = Join-Path $OutRoot $camTag

    if (-not (Test-Path $outDir)) {
        return $false
    }

    $existing = Get-ChildItem -Path $outDir -File -Filter "$base*.gif" -ErrorAction SilentlyContinue
    if ($existing -and $existing.Count -gt 0) {
        return $true
    }
    return $false
}

# Genera UN gif de un tramo especÃ­fico
function Make-Gif(
    [string]$srcPath,
    [int]$start,
    [int]$this,
    [int]$outW,
    [int]$outH,
    [int]$fps,
    [int]$paletteColors,
    [string]$destPath,
    [string]$labelRaw
) {
    # tamaÃ±o de fuente del reloj
    $fsClock  = [int][math]::Max(10, [math]::Round($outH * 0.09))  # ~9%

    # reloj dinÃ¡mico basado en tiempo absoluto del clip acelerado
    $clock = "%{eif\:floor(($start+t*$Speed)/3600)\:d}\:%{eif\:floor(mod(($start+t*$Speed)\,3600)/60)\:d}\:%{eif\:floor(mod(($start+t*$Speed)\,60))\:d}"

    # usar Arial local
    $FontFile = 'C:\Windows\Fonts\arial.ttf'
    $FontEsc  = $FontFile -replace '\\','/' -replace ':','\:'

    # altura barra semitransparente arriba
    $boxH = [int][math]::Round($outH * 0.14)

    # filtro combinado
    $fc = "[0:v]setpts=PTS/$Speed,fps=$fps,scale=${outW}:${outH}," +
          "drawbox=x=0:y=0:w=${outW}:h=${boxH}:color=black@0.45:t=fill," +
          "drawtext=fontfile='$FontEsc':text='$clock':x=6:y=3:fontsize=${fsClock}:fontcolor=white:borderw=2:bordercolor=black@1," +
          "split[v0][v1];" +
          "[v0]palettegen=max_colors=$paletteColors[p];" +
          "[v1][p]paletteuse=dither=bayer:bayer_scale=$Bayer[gif]"

    $args = @(
        "-hide_banner","-stats",
        "-ss",$start,"-t",$this,
        "-i",$srcPath,
        "-an","-sn",
        "-filter_complex",$fc,
        "-map","[gif]",
        "-loop","0",
        "-y",$destPath
    )
    & ffmpeg @args
    return $LASTEXITCODE
}

# Procesa UN video completo en segmentos -> muchos GIFs
function Process-Video([string]$srcPath) {

    $base   = [IO.Path]::GetFileNameWithoutExtension($srcPath)
    $camTag = Get-CamTag $base
    $outDir = Join-Path $OutRoot $camTag
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    # ===== DuraciÃ³n =====
    $durStr = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$srcPath"
    $durStr = ($durStr | Select-Object -First 1).Trim()
    try {
        $I = [Globalization.CultureInfo]::InvariantCulture
        $durSec = [math]::Floor([double]::Parse($durStr,$I))
    } catch {
        Write-Host ("[ERROR] Duracion invalida en {0}: {1} -> salto este video" -f $base,$durStr)
        return [pscustomobject]@{ Ok=0; Num=0 }
    }
    if ($durSec -le 0) {
        Write-Host ("[ERROR] Duracion <=0 en {0} -> salto este video" -f $base)
        return [pscustomobject]@{ Ok=0; Num=0 }
    }

    # ===== Dimensiones originales =====
    $wh = & ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$srcPath"
    $wh = ($wh | Select-Object -First 1).Trim()
    $w,$h = $wh -split 'x'

    # escala base calculada
    $nw = [int]([math]::Max(2, [math]::Floor(($w / $ScaleDiv) / 2) * 2))
    $nh = [int]([math]::Max(2, [math]::Floor(($h / $ScaleDiv) / 2) * 2))

    $num = [math]::Ceiling($durSec / $ChunkSec)

    Write-Host ("[INFO] {0}" -f $base)
    Write-Host ("       TipoCam   : {0}" -f $camTag)
    Write-Host ("       Duracion  : {0} s" -f $durSec)
    Write-Host ("       Segmentos : {0}" -f $num)
    Write-Host ("       Escala    : {0}x{1} -> {2}x{3}" -f $w,$h,$nw,$nh)
    Write-Host ("       Speed={0} | FPS={1}" -f $Speed,$Fps)
    Write-Host ("       OutputDir : {0}" -f $outDir)

    $okCount = 0

    for ($i=0; $i -lt $num; $i++) {

        $start = $i * $ChunkSec
        $this  = [math]::Min($ChunkSec, $durSec - $start)
        if ($this -le 0) { break }

        $idx   = "{0:D2}" -f ($i+1)
        $t1    = HMS $start
        $t2    = HMS ($start + $this)
        $label = "$idx  $t1 - $t2"

        $outGif= Join-Path $outDir ("{0}_part{1}.gif" -f $base, $idx)
        Write-Host ("[{0}/{1}] ss={2}s  t={3}s  label='{4}' -> {5}" -f ($i+1), $num, $start, $this, $label, $outGif)

        # GIF normal
        $rc = Make-Gif -srcPath $srcPath -start $start -this $this -outW $nw -outH $nh -fps $Fps -paletteColors $Colors -destPath $outGif -labelRaw $label
        if ($rc -ne 0 -or -not (Test-Path $outGif)) {
            Write-Host ("  ~ Error en segmento {0}, continuo con el siguiente tramo." -f $idx)
            continue
        }
        $okCount++

        # ===== SHRINK / CONTROL DE TAMAÃ‘O =====
        $cur = (Get-Item $outGif).Length
        if ($ShrinkEnable -and $cur -gt $MaxBytes) {

            if ($ShrinkKeepScale) {
                $snw = $nw; $snh = $nh
            } else {
                $snw = [int]([math]::Max(2, [math]::Floor(($w / $ShrinkScaleDiv) / 2) * 2))
                $snh = [int]([math]::Max(2, [math]::Floor(($h / $ShrinkScaleDiv) / 2) * 2))
            }
            if ($ShrinkKeepFps) {
                $sfps = $Fps
            } else {
                $sfps = [int][math]::Max(8, [math]::Floor($Fps * 0.9))
            }

            # SHRINK #1
            $tmp1 = Join-Path $outDir ("{0}_part{1}.tmp.gif" -f $base, $idx)
            Write-Host ("  > {0:N1} MB supera {1} MB. SHRINK #1 -> {2}x{3}, fps={4}, colors={5}" -f ($cur/1MB), $MaxMB, $snw, $snh, $sfps, $ShrinkColors)
            $rc2 = Make-Gif -srcPath $srcPath -start $start -this $this -outW $snw -outH $snh -fps $sfps -paletteColors $ShrinkColors -destPath $tmp1 -labelRaw $label
            if ($rc2 -eq 0 -and (Test-Path $tmp1)) {
                $new1 = (Get-Item $tmp1).Length
                if ($new1 -le $MaxBytes -or $new1 -lt $cur) {
                    Remove-Item $outGif -Force -ErrorAction SilentlyContinue
                    Rename-Item $tmp1 $outGif -Force
                    $cur = $new1
                    Write-Host ("  OK reemplazado (shrink #1). Nuevo tamano: {0:N1} MB" -f ($cur/1MB))
                } else {
                    Remove-Item $tmp1 -Force -ErrorAction SilentlyContinue
                    Write-Host ("  No mejoro (shrink #1: {0:N1} MB). Conservo original: {1:N1} MB" -f ($new1/1MB), ($cur/1MB))
                }
            } else {
                Remove-Item $tmp1 -Force -ErrorAction SilentlyContinue
                Write-Host "  Fallo shrink #1; conservo el original."
            }

            # SHRINK #2 si sigue grande
            if ($cur -gt $MaxBytes) {
                $tmp2 = Join-Path $outDir ("{0}_part{1}.tmp2.gif" -f $base, $idx)
                Write-Host ("  > Aun supera {0} MB. SHRINK #2 -> {1}x{2}, fps={3}, colors={4}" -f $MaxMB, $snw, $snh, $sfps, $ShrinkColors2)
                $rc3 = Make-Gif -srcPath $srcPath -start $start -this $this -outW $snw -outH $snh -fps $sfps -paletteColors $ShrinkColors2 -destPath $tmp2 -labelRaw $label
                if ($rc3 -eq 0 -and (Test-Path $tmp2)) {
                    $new2 = (Get-Item $tmp2).Length
                    if ($new2 -le $MaxBytes -or $new2 -lt $cur) {
                        Remove-Item $outGif -Force -ErrorAction SilentlyContinue
                        Rename-Item $tmp2 $outGif -Force
                        $cur = $new2
                        Write-Host ("  OK reemplazado (shrink #2). Nuevo tamano: {0:N1} MB" -f ($cur/1MB))
                    } else {
                        Remove-Item $tmp2 -Force -ErrorAction SilentlyContinue
                        Write-Host ("  No mejoro (shrink #2: {0:N1} MB). Conservo actual: {1:N1} MB" -f ($new2/1MB), ($cur/1MB))
                    }
                } else {
                    Remove-Item $tmp2 -Force -ErrorAction SilentlyContinue
                    Write-Host "  Fallo shrink #2; conservo el actual."
                }
            }
        } else {
            Write-Host ("  OK tamano: {0:N1} MB" -f ($cur/1MB))
        }
    }

    Write-Host ("`n[RESUMEN] {0} -> Segmentos OK: {1} / {2}" -f $base,$okCount,$num)
    return [pscustomobject]@{ Ok=$okCount; Num=$num }
}

# ===== Buscar videos candidatos =====
$exts = @('mp4','mov','mkv')

# patrones aceptados (incluye GOPRO y GEAR 360):
$patterns = @(
    "$project GOPRO RAW PROXY Complete",
    "$project*GOPRO RAW PROXY Complete",
    "$project GEAR 360 RAW PROXY Complete",
    "$project*GEAR 360 RAW PROXY Complete",
    "$project VUZE RAW PROXY*",
    "$project*VUZE RAW PROXY*",
    "$project TECHE RAW Proxy Complete",
    "$project*TECHE RAW Proxy Complete",
    "$project*QOOCAM*",
    "$project*TARSIER*",
    "$project DJI OSMO RAW Proxy Complete",
    "$project*DJI OSMO RAW Proxy Complete",
    "$project*DJI*OSMO*",
    "$project*INSTA*"
)

# Antes de procesar, asegurar creaciÃ³n de carpetas de GIF segÃºn renders detectados
Ensure-GifFolders

$matches = @()

# 1) buscar en la carpeta raÃ­z
foreach ($ext in $exts) {
    foreach ($pat in $patterns) {
        $matches += Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like "$pat.$ext"
        }
    }
}

# 2) si nada arriba, buscar recursivo
if (-not $matches) {
    foreach ($ext in $exts) {
        foreach ($pat in $patterns) {
            $matches += Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like "$pat.$ext"
            }
        }
    }
}

if (-not $matches) {
    Write-Host "[ERROR] No se encontro ningun video candidato (GOPRO / GEAR 360 / VUZE / TECHE / QOOCAM / TARSIER / DJI OSMO / INSTA)."
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    exit 1
}

# limpiar duplicados y ordenar por tamaÃ±o desc (los grandes primero)
$matches = $matches | Sort-Object Length -Descending -Unique

Write-Host "Coincidencias:"
$matches | ForEach-Object { Write-Host (" - {0}" -f $_.FullName) }

# ===== Procesar SOLO lo que falta =====
$totalOk  = 0
$totalSeg = 0

foreach ($cand in $matches) {

    if (Is-VideoProcessed $cand.FullName) {
        Write-Host ""
        Write-Host ">>> Ya existe GIF para '$($cand.Name)'. Salto (ya estaba hecho)."
        continue
    }

    Write-Host ""
    Write-Host "=== Procesando: $($cand.Name) ==="
    $res = Process-Video -srcPath $cand.FullName
    $totalOk  += $res.Ok
    $totalSeg += $res.Num
}

Write-Host ("`n[RESUMEN GLOBAL] Gifs OK nuevos/generados ahora: {0} / {1}" -f $totalOk,$totalSeg)
Write-Host ("[FIN] Carpeta base GIFs: {0}" -f $OutRoot)

# ===== Auto-borrado del script y salida inmediata =====
Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
exit 0


