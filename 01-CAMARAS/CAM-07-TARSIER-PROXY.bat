@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001>nul
REM IMPORTANTE: usar PUSHD en vez de CD, porque CD falla con rutas de red UNC \\servidor\carpeta
set "_DID_PUSHD="
pushd "%~dp0" || (
  echo([ERROR] No pude entrar a la carpeta del script: "%~dp0"
  echo([ERROR] Si esta en red, verifica permisos o mapea la ruta como unidad.
  endlocal
  exit /b 1
)
set "_DID_PUSHD=1"

REM ==================== CONFIG ====================
set "DIR_IN=Videos"
set "DIR_PROXY=Proxies"
set "DIR_RIGHT=Right25"

set "FILL_PROXIES=1"
set "FILL_RIGHTS=1"         REM siempre desde PROXY
set "RECURSIVE_IN=1"

set "ORDER_BY=NAME"         REM NAME o TIME
set "PAUSE_AT_END=0"

REM Proxy (SBS completo reducido)
set "W_PROXY=1920"
set "H_PROXY=960"
set "FPS_PROXY=30"
set "A_BR_PROXY=96k"

REM Right (mitad derecha 960x960@30)
set "W_RIGHT=960"
set "H_RIGHT=960"
set "FPS_RIGHT=30"
set "A_BR_RIGHT=32k"
set "A_AR_RIGHT=16000"
set "A_CH_RIGHT=1"

set "EXTS=mp4 mov mkv m4v"
REM =================================================

REM ====== Salida raiz <DRIVE>\<TOP>\<TOP> ======
set "CUR=%CD%"
set "DRIVE_ROOT=%CUR:~0,3%"
for /f "tokens=1 delims=\" %%G in ("%CUR:~3%") do set "TOP=%%G"
if not defined TOP ( echo([ERROR] No pude resolver TOP desde "%CD%" & goto :END )
set "OUT_DIR=%DRIVE_ROOT%%TOP%\"
set "OUT_NAME=%TOP% TARSIER RAW Proxy Complete.mp4"
set "OUT_PATH=%OUT_DIR%%OUT_NAME%"
if not exist "%OUT_DIR%" md "%OUT_DIR%"
echo([INFO] OUT_PATH: "%OUT_PATH%"

REM ====== Prechequeos ======
where ffmpeg  >nul 2>&1 || (echo([ERROR] ffmpeg no esta en PATH & goto :END)
where ffprobe >nul 2>&1 || (echo([ERROR] ffprobe no esta en PATH & goto :END)
if not exist "%DIR_PROXY%" md "%DIR_PROXY%"
if not exist "%DIR_RIGHT%" md "%DIR_RIGHT%"

REM ====== Encoder y filtros (modo simple) ======
echo([INFO] Encoder: h264_nvenc (decode CPU, scale CPU)
set "VENC_PROXY=-c:v h264_nvenc -preset fast -qp 28"
set "VENC_RIGHT=-c:v h264_nvenc -preset fast -qp 30"

REM SIN hwaccel por el 8K HEVC del Tarsier
set "HWDEC_PROXY="
set "HWDEC_RIGHT="

REM Escala / crop siempre CPU (estable)
set "FC_PROXY=[0:v]scale=%W_PROXY%:%H_PROXY%:flags=fast_bilinear,format=yuv420p[vpo]"
set "FC_RIGHT_FROM_PROXY=[0:v]crop=iw/2:ih:iw/2:0,format=yuv420p,setsar=1,setdar=1[vro]"

REM ====== LISTAR Videos ======
set "SCAN_SWITCH="
if "%RECURSIVE_IN%"=="1" set "SCAN_SWITCH=/s"
del /q kd_list.txt 2>nul

if exist "%DIR_IN%\" (
  for %%E in (%EXTS%) do dir /a-d /b %SCAN_SWITCH% "%DIR_IN%\*.%%E" >> kd_list.txt 2>nul
  for %%A in (kd_list.txt) do if %%~zA gtr 0 (
    echo([INFO] Videos detectado. Fuentes:
    type kd_list.txt
  ) else (
    echo([WARN] Videos no tiene archivos con extensiones: %EXTS%
  )
) else (
  echo([WARN] "%DIR_IN%" no existe. Buscando videos en la carpeta actual.
  for %%E in (%EXTS%) do dir /a-d /b "*.%%E" >> kd_list.txt 2>nul
  for %%A in (kd_list.txt) do if %%~zA gtr 0 (
    echo([INFO] Videos detectado en carpeta actual. Fuentes:
    type kd_list.txt
  ) else (
    echo([ERROR] No encontre videos ni en "%DIR_IN%" ni en la carpeta actual.
  )
)

REM ====== PROCESAR: PROXY -> RIGHT ======
set /a SRC_COUNT=0
set /a NEW_PROXY=0
set /a NEW_RIGHT=0
if exist kd_list.txt for /f "usebackq delims=" %%F in ("kd_list.txt") do (
  set /a SRC_COUNT+=1
  call :PROCESS_ONE "%%~fF"
)
echo([INFO] Fuentes en Videos: %SRC_COUNT%  ^| Proxies creados: %NEW_PROXY%  ^| Rights creados: %NEW_RIGHT%

REM ====== Construir lista desde Right25 ======
echo(

if not exist "%DIR_RIGHT%\*.mp4" (
  echo([ERROR] Right25 no contiene MP4 validos para concatenar.
  goto END
)

echo(==== Construyendo lista para concat desde "%DIR_RIGHT%" ====
del /q list_right.txt 2>nul
if /I "%ORDER_BY%"=="TIME" (set "DIR_SW=/o:d") else (set "DIR_SW=/o:n")

for /f "delims=" %%R in ('dir /b /a-d %DIR_SW% "%DIR_RIGHT%\*_right_%W_RIGHT%x%H_RIGHT%_%FPS_RIGHT%fps.mp4" 2^>nul') do (
  set "FN=%%~nxR"
  setlocal enabledelayedexpansion
  if /I not "!FN:~0,6!"=="FINAL_" echo file '%CD%\%DIR_RIGHT%\%%R'>>list_right.txt
  endlocal
)
for %%A in (list_right.txt) do if %%~zA==0 (
  for /f "delims=" %%R in ('dir /b /a-d %DIR_SW% "%DIR_RIGHT%\*_right_*.mp4" 2^>nul') do (
    set "FN=%%~nxR"
    setlocal enabledelayedexpansion
    if /I not "!FN:~0,6!"=="FINAL_" echo file '%CD%\%DIR_RIGHT%\%%R'>>list_right.txt
    endlocal
  )
)
for %%A in (list_right.txt) do if %%~zA==0 (
  for /f "delims=" %%R in ('dir /b /a-d %DIR_SW% "%DIR_RIGHT%\*.mp4" 2^>nul') do (
    set "FN=%%~nxR"
    setlocal enabledelayedexpansion
    if /I not "!FN:~0,6!"=="FINAL_" echo file '%CD%\%DIR_RIGHT%\%%R'>>list_right.txt
    endlocal
  )
)
for %%A in (list_right.txt) do if %%~zA==0 (
  echo([ERROR] Right25 no contiene MP4 validos para concatenar.
  goto END
)

echo([INFO] Archivos a concatenar:
type list_right.txt

REM ====== OVERLAY: N - NombreDelClip ======
set "ASS=overlay.ass"
set "PS_ASS=_mk_overlay_ass.ps1"
set "SUFFIX_NOEXT="  REM mantener nombre completo

call :MAKE_ASS "%PS_ASS%" || (echo([ERROR] No se pudo escribir %PS_ASS% & goto :END)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_ASS%" -ListPath "list_right.txt" -AssPath "%ASS%" -FFProbe "ffprobe" -Suffix "%SUFFIX_NOEXT%"
if errorlevel 1 ( echo([ERROR] Powershell/ffprobe fallo creando ASS & goto :END )
if not exist "%ASS%" ( echo([ERROR] overlay.ass no existe & goto :END )
set "SUBFILTER=subtitles='%ASS:\=\\%'"
set "SUBFILTER=!SUBFILTER::=\:!"
echo([DBG] SUBFILTER=!SUBFILTER!

REM ====== Final en raiz (concat + overlay re-encode) ======
echo(
echo(==== Concatenando + overlay a "%OUT_PATH%" ====
ffmpeg -hide_banner -loglevel error -stats -y -f concat -safe 0 -i list_right.txt ^
  -vf "!SUBFILTER!,fps=%FPS_RIGHT%,format=yuv420p" %VENC_RIGHT% -c:a aac -b:a %A_BR_RIGHT% -ac %A_CH_RIGHT% -ar %A_AR_RIGHT% -movflags +faststart "%OUT_PATH%"
if exist "%OUT_PATH%" ( echo([OK] Final creado: "%OUT_PATH%" ) else ( echo([ERROR] No se pudo crear el final. Revisa permisos/list_right.txt. ) )

:END
if "%PAUSE_AT_END%"=="1" pause
if defined _DID_PUSHD popd
endlocal
exit /b

:PROCESS_ONE
REM *** Usar SIEMPRE !vars! dentro de este bloque ***
set "IN_SRC=%~1"
for %%# in ("!IN_SRC!") do set "BASE=%%~n#"
set "OUT_PROXY=%DIR_PROXY%\!BASE!_proxy_%W_PROXY%x%H_PROXY%_%FPS_PROXY%fps.mp4"
set "OUT_RIGHT=%DIR_RIGHT%\!BASE!_right_%W_RIGHT%x%H_RIGHT%_%FPS_RIGHT%fps.mp4"

echo(
echo([FILE] !BASE!

REM 1) PROXY
if "%FILL_PROXIES%"=="1" (
  if exist "!OUT_PROXY!" (
    echo(  - Proxy ya existe: "!OUT_PROXY!"
  ) else (
    echo(  - Creando PROXY desde Videos...
    ffmpeg -hide_banner -loglevel error -stats -y %HWDEC_PROXY% -i "!IN_SRC!" -filter_complex "%FC_PROXY%" ^
      -map "[vpo]" -map 0:a? -r %FPS_PROXY% %VENC_PROXY% -c:a aac -b:a %A_BR_PROXY% -movflags +faststart "!OUT_PROXY!"
    if exist "!OUT_PROXY!" (
      for %%S in ("!OUT_PROXY!") do set "SZ=%%~zS"
      if "!SZ!"=="0" (
        echo(  [ERR] Proxy salio 0 bytes. Eliminando...
        del /q "!OUT_PROXY!" 2>nul
      ) else (
        set /a NEW_PROXY+=1
      )
    ) else (
      echo(  [ERR] No se pudo crear el proxy
    )
  )
) else (
  echo(  - FILL_PROXIES=0 (no se crean proxies)
)

REM 2) RIGHT (siempre desde PROXY)
set "IN_FOR_RIGHT=!OUT_PROXY!"
if "%FILL_RIGHTS%"=="1" (
  if not exist "!IN_FOR_RIGHT!" (
    echo(  [ERR] No hay proxy; no puedo crear RIGHT. Crea el proxy primero.
  ) else (
    if exist "!OUT_RIGHT!" (
      echo(  - Right ya existe: "!OUT_RIGHT!"
    ) else (
      echo(  - Creando RIGHT desde PROXY...
      ffmpeg -hide_banner -loglevel error -stats -y %HWDEC_RIGHT% -i "!IN_FOR_RIGHT!" -filter_complex "%FC_RIGHT_FROM_PROXY%" ^
        -map "[vro]" -map 0:a? -r %FPS_RIGHT% %VENC_RIGHT% -c:a aac -b:a %A_BR_RIGHT% -ac %A_CH_RIGHT% -ar %A_AR_RIGHT% -movflags +faststart "!OUT_RIGHT!"
      if exist "!OUT_RIGHT!" (
        for %%S in ("!OUT_RIGHT!") do set "SZ=%%~zS"
        if "!SZ!"=="0" (
          echo(  [ERR] RIGHT salio 0 bytes. Eliminando...
          del /q "!OUT_RIGHT!" 2>nul
        ) else (
          set /a NEW_RIGHT+=1
        )
      ) else (
        echo(  [ERR] No se pudo crear el RIGHT
      )
    )
  )
) else (
  echo(  - FILL_RIGHTS=0 (no se crean rights)
)
exit /b 0

:MAKE_ASS
REM Genera _mk_overlay_ass.ps1 que crea overlay.ass con l??neas "N - NombreDelClip" alineadas a cada clip
> "%~1" echo param([string]$ListPath,[string]$AssPath,[string]$FFProbe,[string]$Suffix)
>>"%~1" echo $ErrorActionPreference='Stop'
>>"%~1" echo $acc=0.0; $idx=1
>>"%~1" echo $lines = @()
>>"%~1" echo $lines += "[Script Info]"
>>"%~1" echo $lines += "ScriptType: v4.00+"
>>"%~1" echo $lines += "PlayResX: 960"
>>"%~1" echo $lines += "PlayResY: 960"
>>"%~1" echo ""
>>"%~1" echo $lines += "[V4+ Styles]"
>>"%~1" echo $lines += "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
>>"%~1" echo $lines += "Style: Top,Arial,14,&H33FFFFFF,&H00FFFFFF,&H66000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,8,10,10,4,1"
>>"%~1" echo ""
>>"%~1" echo $lines += "[Events]"
>>"%~1" echo $lines += "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
>>"%~1" echo Get-Content -LiteralPath $ListPath ^| ForEach-Object {
>>"%~1" echo ^ if ($_ -match "^file '(.+)'$") {
>>"%~1" echo ^   $p = $Matches[1].Replace('/','\')
>>"%~1" echo ^   $label = [IO.Path]::GetFileNameWithoutExtension($p)
>>"%~1" echo ^   if ($Suffix) { $label = [regex]::Replace($label,[regex]::Escape($Suffix)+'$','') }
>>"%~1" echo ^   $dur = ^& $FFProbe -v error -show_entries format^=duration -of default^=noprint_wrappers^=1:nokey^=1 "$p"
>>"%~1" echo ^   if (-not $dur) { throw "ffprobe sin duracion para $p" }
>>"%~1" echo ^   $dur = [double]::Parse($dur,[Globalization.CultureInfo]::InvariantCulture)
>>"%~1" echo ^   $st  = [TimeSpan]::FromSeconds($acc)
>>"%~1" echo ^   $et  = [TimeSpan]::FromSeconds($acc + [Math]::Max($dur - 0.04, 0.01))
>>"%~1" echo ^   $stf = $st.ToString('hh\:mm\:ss\.ff')
>>"%~1" echo ^   $etf = $et.ToString('hh\:mm\:ss\.ff')
>>"%~1" echo ^   $safe = $label -replace "\\{","(" -replace "\\}"," )"
>>"%~1" echo ^   $safe = "$idx - $safe"
>>"%~1" echo ^   $lines += "Dialogue: 0,$stf,$etf,Top,,0000,0000,0000,,$safe"
>>"%~1" echo ^   $acc += $dur; $idx++
>>"%~1" echo ^ }
>>"%~1" echo }
>>"%~1" echo Set-Content -LiteralPath $AssPath -Value $lines -Encoding UTF8
exit /b

