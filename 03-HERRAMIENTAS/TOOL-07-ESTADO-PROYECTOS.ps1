<#
TOOL-07-ESTADO-PROYECTOS

Informe de solo lectura: para cada proyecto "NNN - Titulo" dice que tiene cada
camara y que le falta para quedar listo, en el orden real del flujo:

  QOOCAM   original -> render 8K en KDOutput (QooCam Studio) -> proxy -> final unido
  DJI OSMO original OSV -> exportado SBS 8K; LRF -> proxy izquierdo + vista dual -> finales
  TECHE    clip (TecheMain + TechePrev) -> proxy -> final unido
  GOPRO / INSTA / VUZE / GEAR 360      original -> proxy -> final unido
  AUDIO    microfonos hl-* y TX-*
  AUTOSYNC XML inicial -> analisis de dialogo -> dialogo verificado -> proyecto Premiere

No mueve, crea ni modifica nada dentro de los proyectos. Guarda un CSV en logs.
#>
[CmdletBinding()]
param(
    [string]$Root = 'G:\',
    # Muestra tambien los proyectos que ya estan completos.
    [switch]$Todos
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $RepoRoot 'logs'
$VideoExt = @('.mp4', '.mov', '.m4v', '.mkv')
$GeneratedQoo = '(?i)(?:_output|_reframe|_proxy)(?:\(\d+\))?\.mp4$'

function Get-Files([string]$path, [string]$filter = '*') {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $path -File -Filter $filter -ErrorAction SilentlyContinue)
}
function Test-Final([string]$project, [string]$pattern) {
    return [bool](Get-ChildItem -LiteralPath $project -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $pattern } | Select-Object -First 1)
}
# Cuantos originales tienen al menos un derivado cuyo nombre empieza con el suyo.
function Measure-Covered($stems, $derived) {
    $names = @($derived | Where-Object { $_ } | ForEach-Object { $_.Name })
    if (-not $names.Count) { return 0 }
    return @($stems | Where-Object { $s = $_; $names | Where-Object { $_.StartsWith($s, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }).Count
}
function New-Camera([string]$name, [int]$originals, [string]$detail, [string[]]$missing) {
    [pscustomobject]@{ Camara = $name; Originales = $originals; Detalle = $detail; Falta = @($missing | Where-Object { $_ }) }
}

function Get-ProjectStatus([IO.DirectoryInfo]$project) {
    $p = $project.FullName
    $cams = New-Object System.Collections.ArrayList

    # ---- QOOCAM
    $qoo = Join-Path $p '100QOOCAM'
    $orig = @(Get-Files $qoo | Where-Object { $_.Extension -ieq '.mp4' -and $_.Name -notmatch $GeneratedQoo })
    if ($orig.Count) {
        $stems = @($orig | ForEach-Object { $_.BaseName })
        $renders = Measure-Covered $stems (Get-Files (Join-Path $qoo 'KDOutput') '*.mp4')
        $proxies = Measure-Covered $stems (Get-Files (Join-Path $qoo 'Right25') '*.mp4')
        $final = Test-Final $p '*QOOCAM RAW Proxy Complete*'
        $missing = @()
        if ($renders -lt $orig.Count) { $missing += "$($orig.Count - $renders) render(s) 8K en QooCam Studio" }
        if ($proxies -lt $orig.Count) { $missing += "$($orig.Count - $proxies) proxy(s)" }
        if (-not $final) { $missing += 'final unido' }
        [void]$cams.Add((New-Camera 'QOOCAM' $orig.Count "render $renders/$($orig.Count), proxy $proxies/$($orig.Count), final $(if ($final) {'si'} else {'no'})" $missing))
    }

    # ---- DJI OSMO
    $dji = Join-Path $p 'CAM_001'
    $osv = @(Get-Files $dji '*.OSV')
    if ($osv.Count) {
        $stems = @($osv | ForEach-Object { $_.BaseName })
        $lrf = Measure-Covered $stems (Get-Files $dji '*.LRF')
        $exported = Measure-Covered $stems (Get-Files $dji | Where-Object { $VideoExt -contains $_.Extension.ToLowerInvariant() })
        $left = Measure-Covered $stems (Get-Files (Join-Path $dji 'Proxy DJI OSMO RAW') '*.mp4')
        $dual = Measure-Covered $stems (Get-Files (Join-Path $dji 'Proxy DJI OSMO DUAL') '*.mp4')
        $finalRaw = Test-Final $p '*DJI OSMO RAW Proxy Complete*'
        $finalDual = Test-Final $p '*DJI OSMO DUAL Preview Complete*'
        $missing = @()
        if ($exported -lt $osv.Count) { $missing += "$($osv.Count - $exported) exportado(s) SBS 8K" }
        if ($lrf -lt $osv.Count) { $missing += "$($osv.Count - $lrf) clip(s) sin LRF" }
        if ($left -lt $lrf) { $missing += "$($lrf - $left) proxy(s) LRF" }
        if ($dual -lt $lrf) { $missing += "$($lrf - $dual) vista(s) dual" }
        $vr180 = Measure-Covered $stems (Get-Files (Join-Path $dji 'Proxy DJI OSMO VR180') '*.mp4')
        if ($vr180 -lt $lrf) { $missing += "$($lrf - $vr180) proxy(s) VR180" }
        if (-not $finalRaw) { $missing += 'final RAW' }
        if ($lrf -and -not $finalDual) { $missing += 'final DUAL' }
        [void]$cams.Add((New-Camera 'DJI OSMO' $osv.Count "exportado $exported/$($osv.Count), proxy $left/$lrf, dual $dual/$lrf, vr180 $vr180/$lrf, finales $(if ($finalRaw) {'RAW'} else {'-'})/$(if ($finalDual) {'DUAL'} else {'-'})" $missing))
    }

    # ---- TECHE
    $clips = @(); $proxyCount = 0
    foreach ($date in @(Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}_\d{2}_\d{2}$' })) {
        $here = @(Get-ChildItem -LiteralPath $date.FullName -Directory -Filter 'VIDEO_TECHE_*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'TechePrev.mp4') })
        $clips += $here
        $proxyCount += Measure-Covered @($here | ForEach-Object { $_.Name }) (Get-Files (Join-Path $date.FullName 'Proxy TECHE RAW') '*.mp4')
    }
    if ($clips.Count) {
        $final = Test-Final $p '*TECHE RAW PROXY Complete*'
        $missing = @()
        if ($proxyCount -lt $clips.Count) { $missing += "$($clips.Count - $proxyCount) proxy(s)" }
        if (-not $final) { $missing += 'final unido' }
        [void]$cams.Add((New-Camera 'TECHE' $clips.Count "proxy $proxyCount/$($clips.Count), final $(if ($final) {'si'} else {'no'})" $missing))
    }

    # ---- camaras con flujo simple: original -> proxy -> final
    $simple = @(
        @{ Name = 'GOPRO';    Dir = '100GOPRO'; Proxy = 'Proxy GOPRO RAW';    Final = '*GOPRO RAW PROXY Complete*';    Filter = { $_.Extension -ieq '.mp4' } },
        @{ Name = 'INSTA';    Dir = 'Camera01'; Proxy = 'Proxy INSTA RAW';    Final = '*INSTA RAW PROXY Complete*';    Filter = { $_.Name -like '*_00_*.insv' } },
        @{ Name = 'VUZE';     Dir = '100VUZXR'; Proxy = 'Proxy VUZE RAW';     Final = '*VUZE RAW PROXY Complete*';     Filter = { $_.Extension -ieq '.mp4' } },
        @{ Name = 'GEAR 360'; Dir = '101PHOTO'; Proxy = 'Proxy GEAR 360 RAW'; Final = '*GEAR 360 RAW PROXY Complete*'; Filter = { $_.Extension -ieq '.mp4' } }
    )
    foreach ($c in $simple) {
        $dir = Join-Path $p $c.Dir
        $orig = @(Get-Files $dir | Where-Object $c.Filter)
        if (-not $orig.Count) { continue }
        $proxyFiles = @(Get-Files (Join-Path $dir $c.Proxy) '*.mp4' | Where-Object { $_.Name -notlike '*Complete*' })
        $final = Test-Final $p $c.Final
        $missing = @()
        if ($proxyFiles.Count -lt $orig.Count) { $missing += "$($orig.Count - $proxyFiles.Count) proxy(s)" }
        if (-not $final) { $missing += 'final unido' }
        [void]$cams.Add((New-Camera $c.Name $orig.Count "proxy $($proxyFiles.Count)/$($orig.Count), final $(if ($final) {'si'} else {'no'})" $missing))
    }

    # ---- audio externo
    $audio = 0
    foreach ($d in @(Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(hl-|TX)' })) {
        $audio += @(Get-Files $d.FullName '*.wav').Count
    }

    # ---- AutoSync y Premiere
    $as = Join-Path $p '_AutoSync'
    $stage = 'sin iniciar'
    if (Test-Path -LiteralPath $as) {
        $stage = 'carpeta creada'
        if (Get-Files $as '*AutoSync inicial.xml') { $stage = 'XML inicial' }
        if (Get-Files $as '*AutoSync dialogo.xml') { $stage = 'dialogo analizado' }
        if (Get-Files (Join-Path $as 'Dialogue_verification') 'dialogo_verificado*.xml') { $stage = 'dialogo verificado' }
    }
    $premiere = @(Get-Files $p '*.prproj' | Where-Object { $_.Name -like '*AutoSync*' }).Count -gt 0
    if ($premiere) { $stage = 'proyecto Premiere creado' }

    $gifs = Test-Path -LiteralPath (Join-Path $p 'GIFs_split')
    [pscustomobject]@{ Proyecto = $project.Name; Camaras = @($cams); Audio = $audio; AutoSync = $stage; GIFs = $gifs }
}

$rootPath = (Get-Item -LiteralPath $Root).FullName
$projects = @(Get-ChildItem -LiteralPath $rootPath -Directory | Where-Object { $_.Name -match '^\d{2,3}[\s-]' } | Sort-Object Name)
$rows = New-Object System.Collections.ArrayList
$pendingProjects = 0
$totals = @{}

Write-Host ''
Write-Host "ESTADO DE LOS PROYECTOS EN $rootPath" -ForegroundColor Cyan
foreach ($project in $projects) {
    $s = Get-ProjectStatus $project
    if (-not $s.Camaras.Count -and -not $s.Audio) { continue }
    $pendingCams = @($s.Camaras | Where-Object { $_.Falta.Count })
    $videoReady = ($pendingCams.Count -eq 0)
    $autoSyncDone = ($s.AutoSync -in 'dialogo analizado', 'dialogo verificado', 'proyecto Premiere creado')
    $complete = $videoReady -and $autoSyncDone
    if (-not $complete) { $pendingProjects++ }

    foreach ($c in $s.Camaras) {
        foreach ($m in $c.Falta) {
            $key = $c.Camara + ': ' + ($m -replace '^\d+\s+', '')
            $n = if ($m -match '^(\d+)\s') { [int]$Matches[1] } else { 1 }
            $totals[$key] = $n + [int]$totals[$key]
        }
        [void]$rows.Add([pscustomobject]@{
            Proyecto = $s.Proyecto; Camara = $c.Camara; Originales = $c.Originales; Detalle = $c.Detalle
            Falta = ($c.Falta -join '; '); Audio = $s.Audio; AutoSync = $s.AutoSync; GIFs = $s.GIFs
        })
    }
    if ($complete -and -not $Todos) { continue }

    Write-Host ''
    Write-Host ("  {0}" -f $s.Proyecto) -ForegroundColor $(if ($complete) { 'Green' } else { 'White' })
    foreach ($c in $s.Camaras) {
        $color = if ($c.Falta.Count) { 'Yellow' } else { 'DarkGray' }
        $tail = if ($c.Falta.Count) { '  FALTA: ' + ($c.Falta -join ', ') } else { '  listo' }
        Write-Host ("      {0,-9} {1,3} orig.  {2}{3}" -f $c.Camara, $c.Originales, $c.Detalle, $tail) -ForegroundColor $color
    }
    $audioText = if ($s.Audio) { "$($s.Audio) wav" } else { 'sin audio externo' }
    Write-Host ("      {0,-9} {1}   |   AUTOSYNC: {2}{3}" -f 'AUDIO', $audioText, $s.AutoSync, $(if ($videoReady -and -not $autoSyncDone) { '  <- ya se puede lanzar' } else { '' })) -ForegroundColor $(if ($autoSyncDone) { 'DarkGray' } else { 'Yellow' })
}

Write-Host ''
Write-Host 'TRABAJO PENDIENTE EN TOTAL' -ForegroundColor Cyan
if (-not $totals.Count) { Write-Host '  Nada pendiente en video.' -ForegroundColor Green }
foreach ($key in ($totals.Keys | Sort-Object)) { Write-Host ("  {0,5}  {1}" -f $totals[$key], $key) }
Write-Host ("Proyectos con algo pendiente: {0} de {1}." -f $pendingProjects, $projects.Count)

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$csv = Join-Path $LogDir ("estado_proyectos_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Write-Host "Detalle en: $csv"
