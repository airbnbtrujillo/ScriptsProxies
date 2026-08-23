# Extract-Thumbnail-Candidates.ps1
# Usa proxies para sacar candidatos de thumbnail sin trabajar con los RAW pesados.
# Salida: Thumbnail_candidates\<video>\*.jpg + index.html + thumbnail_index.csv

param(
    [string]$Root = "",
    [int]$IntervalSec = 60,
    [int]$StartOffsetSec = 5,
    [int]$Width = 1280,
    [int]$MaxPerVideo = 240
)

$ErrorActionPreference = 'Continue'

function HMS([int]$sec) {
    $ts = [TimeSpan]::FromSeconds([math]::Max(0,$sec))
    return ("{0:D2}h{1:D2}m{2:D2}s" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds)
}

function HtmlEnc([string]$s) {
    return [System.Net.WebUtility]::HtmlEncode($s)
}

function SafeName([string]$s) {
    $bad = [IO.Path]::GetInvalidFileNameChars() -join ''
    $rx = '[{0}]' -f [Regex]::Escape($bad)
    return (($s -replace $rx, '_') -replace '\s+', ' ').Trim()
}

function EscapeDrawText([string]$s) {
    $s = $s -replace '\\','/'
    $s = $s -replace "'", "\\'"
    $s = $s -replace ':', '\:'
    $s = $s -replace ',', '\,'
    $s = $s -replace '%', '\%'
    return $s
}

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = (Get-Location).Path
}

try {
    $resolvedRoot = Resolve-Path -LiteralPath $Root
    if ($resolvedRoot.ProviderPath) {
        $Root = $resolvedRoot.ProviderPath
    } else {
        $Root = $resolvedRoot.Path
    }
} catch {
    Write-Host "[ERROR] No existe la carpeta: $Root"
    exit 1
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] ffmpeg no esta en PATH"
    exit 1
}
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] ffprobe no esta en PATH"
    exit 1
}

$project = Split-Path -Leaf $Root
$outRoot = Join-Path $Root 'Thumbnail_candidates'
New-Item -ItemType Directory -Path $outRoot -Force | Out-Null

$patterns = @(
    '*DJI OSMO RAW Proxy Complete*.mp4',
    '*DJI OSMO RAW Proxy Complete*.mov',
    '*DJI OSMO RAW Proxy Complete*.mkv',
    '*RAW PROXY Complete*.mp4',
    '*RAW PROXY Complete*.mov',
    '*RAW PROXY Complete*.mkv',
    '*RAW Proxy Complete*.mp4',
    '*RAW Proxy Complete*.mov',
    '*RAW Proxy Complete*.mkv',
    '*Proxy Complete*.mp4',
    '*Proxy Complete*.mov',
    '*Proxy Complete*.mkv'
)

$videos = @()
foreach ($pat in $patterns) {
    $videos += Get-ChildItem -LiteralPath $Root -File -Filter $pat -ErrorAction SilentlyContinue
}
if (-not $videos) {
    foreach ($pat in $patterns) {
        $videos += Get-ChildItem -Path $Root -Recurse -File -Filter $pat -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\Thumbnail_candidates\\|\\GIFs_split\\' }
    }
}
$videos = $videos | Sort-Object FullName -Unique

if (-not $videos) {
    Write-Host "[ERROR] No encontre proxies completos en: $Root"
    Write-Host "        Primero crea los proxies y luego vuelve a correr este script."
    exit 1
}

$fontFile = 'C:\Windows\Fonts\arial.ttf'
$fontEsc = $fontFile -replace '\\','/' -replace ':','\:'
$csvRows = New-Object System.Collections.Generic.List[object]
$html = New-Object System.Collections.Generic.List[string]
$html.Add('<!doctype html><html><head><meta charset="utf-8"><title>Thumbnail candidates</title>')
$html.Add('<style>body{font-family:Arial,sans-serif;margin:18px;background:#111;color:#eee}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:14px}.card{background:#1d1d1d;border:1px solid #333;padding:8px}.card img{width:100%;height:auto;display:block}.t{font-weight:bold;margin-top:6px}.s{font-size:12px;color:#bbb;word-break:break-all}</style></head><body>')
$html.Add('<h1>Thumbnail candidates - ' + (HtmlEnc $project) + '</h1>')
$html.Add('<p>Hecho desde proxies. El tiempo aparece en cada JPG y en el nombre del archivo.</p>')

foreach ($v in $videos) {
    $base = [IO.Path]::GetFileNameWithoutExtension($v.Name)
    $safeBase = SafeName $base
    $videoOut = Join-Path $outRoot $safeBase
    New-Item -ItemType Directory -Path $videoOut -Force | Out-Null

    $durRaw = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $v.FullName
    $durRaw = ($durRaw | Select-Object -First 1).Trim()
    try {
        $dur = [math]::Floor([double]::Parse($durRaw, [Globalization.CultureInfo]::InvariantCulture))
    } catch {
        Write-Host "[WARN] No pude leer duracion: $($v.Name)"
        continue
    }
    if ($dur -le 0) { continue }

    $start = [math]::Min($StartOffsetSec, [math]::Max(0, $dur - 1))
    $times = New-Object System.Collections.Generic.List[int]
    for ($t = $start; $t -lt $dur -and $times.Count -lt $MaxPerVideo; $t += $IntervalSec) {
        $times.Add([int]$t)
    }
    if ($times.Count -eq 0) { $times.Add(0) }

    Write-Host "[VIDEO] $($v.Name)"
    Write-Host "        Duracion: $dur s | candidatos: $($times.Count) | salida: $videoOut"
    $html.Add('<h2>' + (HtmlEnc $v.Name) + '</h2><div class="grid">')

    $n = 0
    foreach ($t in $times) {
        $n++
        $stamp = HMS $t
        $outName = ('{0:D3}_at_{1}__{2}.jpg' -f $n, $stamp, $safeBase)
        $outPath = Join-Path $videoOut $outName
        if (Test-Path -LiteralPath $outPath) {
            Write-Host "  salto existente: $outName"
        } else {
            $label = EscapeDrawText ("$stamp  |  $base")
            $vf = "scale=${Width}:-2,drawbox=x=0:y=ih-58:w=iw:h=58:color=black@0.58:t=fill,drawtext=fontfile='$fontEsc':text='$label':x=14:y=h-43:fontsize=26:fontcolor=white:borderw=2:bordercolor=black"
            & ffmpeg -hide_banner -loglevel error -ss $t -i $v.FullName -frames:v 1 -q:v 2 -vf $vf -y $outPath
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outPath)) {
                Write-Host "  [WARN] fallo frame: $stamp"
                continue
            }
            Write-Host "  ok: $outName"
        }

        $rel = ($outPath.Substring($outRoot.Length).TrimStart('\')) -replace '\\','/'
        $html.Add('<div class="card"><img src="' + (HtmlEnc $rel) + '"><div class="t">' + (HtmlEnc $stamp) + '</div><div class="s">' + (HtmlEnc $v.Name) + '</div></div>')
        $csvRows.Add([pscustomobject]@{
            Project = $project
            Proxy = $v.FullName
            Timestamp = $stamp
            Seconds = $t
            Thumbnail = $outPath
        }) | Out-Null
    }
    $html.Add('</div>')
}

$csvPath = Join-Path $outRoot 'thumbnail_index.csv'
$csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
$html.Add('</body></html>')
$htmlPath = Join-Path $outRoot 'index.html'
Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8

Write-Host ""
Write-Host "[FIN] Thumbnails: $outRoot"
Write-Host "[FIN] Indice HTML: $htmlPath"
Write-Host "[FIN] CSV: $csvPath"
exit 0

