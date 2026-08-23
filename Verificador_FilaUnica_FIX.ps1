param(
  [string]$RootPath,   # opcional: si no lo pasas, pregunta
  [string]$OutCsv      # opcional
)

$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = "Verificador de Archivos - Fila Unica (BULK FIX)"

function Log([string]$m){ Write-Host ("[{0}] {1}" -f (Get-Date).ToString('HH:mm:ss'), $m) }

# ------- pedir carpeta si falta -------
function Get-FolderPath(){
  try{
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = "Selecciona la carpeta del PROYECTO o la carpeta MADRE que contiene varios proyectos"
    $fb.ShowNewFolderButton = $false
    if ($fb.ShowDialog() -eq 'OK' -and $fb.SelectedPath){ return $fb.SelectedPath }
  } catch {}
  while($true){
    $p = Read-Host "Escribe/pega la RUTA (ENTER para cancelar)"
    if ([string]::IsNullOrWhiteSpace($p)){ return $null }
    if (Test-Path -LiteralPath $p){ return (Resolve-Path -LiteralPath $p).Path }
    Write-Host "Ruta invalida. Intenta de nuevo." -ForegroundColor Yellow
  }
}

# ------- helpers detección -------
function Get-LatestDateFolderName([string]$base){
  try{
    $rx = '^(?<Y>\d{4})[_-](?<M>\d{2})[_-](?<D>\d{2})$'
    Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match $rx } |
      Sort-Object { [int]"$($_.Name.Substring(0,4))$($_.Name.Substring(5,2))$($_.Name.Substring(8,2))" } -Descending |
      Select-Object -ExpandProperty Name -First 1
  } catch { $null }
}

function Find-ChildFolder([string]$base,[string[]]$cands,[string]$regex){
  try{
    $dirs = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue
    if (-not $dirs){ return $null }
    if ($cands){
      foreach($n in $cands){
        $hit = $dirs | Where-Object { $_.Name -ieq $n } | Select-Object -First 1
        if ($hit){ return $hit.Name }
      }
    }
    if ($regex){
      $h = $dirs | Where-Object { $_.Name -match $regex } | Select-Object -First 1
      if ($h){ return $h.Name }
    }
    return $null
  } catch { $null }
}

function Find-FinalProxy([string]$base,[string]$regexToken){
  try{
    Get-ChildItem -LiteralPath $base -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '(?i)RAW\s*PROXY\s*Complete' -and $_.Name -match $regexToken -and $_.Extension -match '(?i)\.mp4$' } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -ExpandProperty Name -First 1
  } catch { $null }
}

function Has-Gifs([string]$base,[string]$gifToken){
  try{
    $gifsDir = Join-Path $base 'GIFs_split'
    if (-not (Test-Path -LiteralPath $gifsDir)){ return $false }
    (Get-ChildItem -LiteralPath $gifsDir -File -Filter *.gif -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match $gifToken }).Count -gt 0
  } catch { $false }
}

function Build-State($hasFolder,$hasFile,$hasGif){
  if ($hasFolder -and $hasFile){
    if ($hasGif){ 'OK' } else { 'NO GIF' }
  } elseif ($hasFolder -and -not $hasFile){
    'NO RENDER'
  } else {
    ''   # dejar vacío
  }
}


# ------- definicion columnas -------
$cams = @(
  @{ Name='TECHE';      Mode='LatestDate';                              Final='(?i)\bTECHE\b';            Gif='(?i)TECHE' },
  @{ Name='QOOCAM';     Cands=@('100QOOCAM');                           Final='(?i)\bQOOCAM\b';           Gif='(?i)QOOCAM' },
  @{ Name='INSTAEVO';   Cands=@('Camera01');                            Final='(?i)\bINSTA\b(?!.*GO)';    Gif='(?i)\bINSTA\b(?!.*GO)' },
  @{ Name='TARSIER';    Cands=@('Videos');                              Final='(?i)\bTARSIER\b';          Gif='(?i)TARSIER' },
  @{ Name='VUZE';       Cands=@('100VUZXR');                            Final='(?i)\bVUZE\b';             Gif='(?i)VUZE' },
  @{ Name='GOPRO';      Cands=@('100GOPRO');                            Final='(?i)\bGOPRO\b';            Gif='(?i)GOPRO' },
  @{ Name='GEAR360';    Cands=@('101PHOTO');                            Final='(?i)\bGEAR\s*360\b';       Gif='(?i)GEAR\s*360' },
  @{ Name='INSTA360GO'; Cands=@('INSTA360GO','100INSTA360GO','100GO','GO'); Final='(?i)\bINSTA\s*360\s*GO\b'; Gif='(?i)\bINSTA\s*360\s*GO\b' }
)

# ------- obtener carpeta raíz -------
if (-not $RootPath -or -not (Test-Path -LiteralPath $RootPath)){
  Log "No se recibio ruta valida. Abrire selector..."
  $RootPath = Get-FolderPath
}
if (-not $RootPath){
  Write-Host "[CANCELADO] No se selecciono carpeta. Presiona ENTER para salir."
  Read-Host | Out-Null
  return
}
$Root = (Resolve-Path -LiteralPath $RootPath).Path
$RootName = Split-Path -Leaf $Root

# ------- determinar si es carpeta madre (tiene muchos proyectos) -------
$subProjects = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue
# Heurística: si hay subcarpetas y sus nombres parecen "nn - Titulo" o "aaa", lo tratamos como MADRE.
$looksMother = $subProjects.Count -gt 0
if ($looksMother){
  # produce lista de proyectos (rutas)
  $projects = $subProjects | Select-Object -ExpandProperty FullName
  if (-not $OutCsv){
    $OutCsv = Join-Path $Root ("{0} - VerificacionFilaUnica.csv" -f ($RootName -replace '[\\/:*?""<>|]','_'))
  }
  Log ("Modo: BULK sobre {0} proyectos" -f $projects.Count)
} else {
  $projects = @($Root)
  if (-not $OutCsv){
    $OutCsv = Join-Path $Root ("{0} - VerificacionFilaUnica.csv" -f ($RootName -replace '[\\/:*?""<>|]','_'))
  }
  Log "Modo: Proyecto unico"
}

# ------- encabezados y contenedor de filas -------
$headers = @('NOMBRE DEL PROYECTO') + ($cams | ForEach-Object {$_.Name}) + @('Premiere')
$allRows = New-Object System.Collections.Generic.List[object]

# ------- función para construir una fila por proyecto -------
function Build-Row([string]$projPath){
  $projName = Split-Path -Leaf $projPath
  $row = New-Object System.Collections.Generic.List[string]
  $row.Add($projName)

  foreach($cam in $cams){
    # Carpeta
    $folder = $null
    if ($cam.ContainsKey('Mode') -and $cam.Mode -eq 'LatestDate'){
      $folder = Get-LatestDateFolderName $projPath
    } elseif ($cam.ContainsKey('Cands')){
      $folder = Find-ChildFolder $projPath $cam.Cands $null
    }

    # Archivo final
    $final  = Find-FinalProxy $projPath $cam.Final
    # GIFs
    $hasGif = Has-Gifs $projPath $cam.Gif

    $state  = Build-State -hasFolder:([bool]$folder) -hasFile:([bool]$final) -hasGif:$hasGif
    if ([string]::IsNullOrEmpty($state)){ $cell = '' }
    else {
      if ($folder){ $cell = ("{0} - {1}" -f $folder, $state) } else { $cell = $state }
    }
    $row.Add($cell)
  }

  # Premiere: fecha del .prproj mas reciente
  $prem = Get-ChildItem -LiteralPath $projPath -Recurse -File -Filter *.prproj -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $premDate = ''
  if ($prem){ $premDate = $prem.LastWriteTime.ToString('yyyy-MM-dd') }
  $row.Add($premDate)

  return ,$row  # como objeto
}

# ------- construir todas las filas -------
foreach($p in $projects){
  Log ("Analizando: {0}" -f $p)
  $allRows.Add( (Build-Row -projPath $p) )
}

# ------- guardar CSV -------
$lines = @()
$lines += ($headers -join ',')
foreach($row in $allRows){
  # asegura número de columnas
  while($row.Count -lt $headers.Count){ $row.Add('') }
  $esc = $row | ForEach-Object {
    $v = $_; if ($null -eq $v){ $v = '' }
    $v = $v -replace '"','""'
    if ($v -match ','){ '"' + $v + '"' } else { $v }
  }
  $lines += ($esc -join ',')
}
Set-Content -LiteralPath $OutCsv -Value ($lines -join "`r`n") -Encoding UTF8
Log ("Listo. CSV generado en: {0}" -f $OutCsv)

Read-Host "Presiona ENTER para salir" | Out-Null
