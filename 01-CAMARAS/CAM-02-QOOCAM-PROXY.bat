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

REM =================================================
REM  QOOCAM Proxy Keeper v5
REM  - Proxy nuevo corto:   <BASE>_proxy.mp4
REM  - Acepta proxy legado: <BASE>_proxy_1920x960_30fps.mp4
REM  - SIN parentesis en echo dentro de bloques (evita parse bugs)
REM =================================================
set "SCRIPT_VER=QOOCAM Proxy Keeper v5 [skip final estable]"
echo([INFO] %SCRIPT_VER%

REM ==================== CONFIG ====================
set "DIR_IN=KDOutput"
set "DIR_PROXY=Proxies"
set "DIR_RIGHT=Right25"

set "FILL_PROXIES=1"
set "FILL_RIGHTS=1"
set "RECURSIVE_IN=1"

set "ORDER_BY=NAME"
set "PAUSE_AT_END=0"
set "PAUSE_ON_ERROR=0"
set "FORCE_CPU=0"

REM Proxy (SBS completo reducido)
set "W_PROXY=1920"
set "H_PROXY=960"
set "FPS_PROXY=30"
set "A_BR_PROXY=96k"

REM Right (mitad derecha 960x960)
set "W_RIGHT=960"
set "H_RIGHT=960"
set "FPS_RIGHT=30"
set "A_BR_RIGHT=32k"
set "A_AR_RIGHT=16000"
set "A_CH_RIGHT=1"

set "EXTS=mp4 mov mkv m4v"
REM =================================================

REM ====== Salida raiz E:\<TOP>\<TOP> ======
set "CUR=%CD%"
set "DRIVE_ROOT=%CUR:~0,3%"
for /f "tokens=1 delims=\" %%G in ("%CUR:~3%") do set "TOP=%%G"
if not defined TOP ( echo([ERROR] No pude resolver TOP desde "%CD%" & goto :END )

set "OUT_DIR=%DRIVE_ROOT%%TOP%\"
set "OUT_NAME=%TOP% QOOCAM RAW Proxy Complete.mp4"
set "OUT_PATH=%OUT_DIR%%OUT_NAME%"
if not exist "%OUT_DIR%" md "%OUT_DIR%"
echo([INFO] OUT_PATH: "%OUT_PATH%"

REM ====== Prechequeos ======
where ffmpeg >nul 2>&1 || (echo([ERROR] ffmpeg no esta en PATH & goto :END)
where ffprobe >nul 2>&1 || (echo([ERROR] ffprobe no esta en PATH & goto :END)
if not exist "%DIR_PROXY%" md "%DIR_PROXY%"
if not exist "%DIR_RIGHT%" md "%DIR_RIGHT%"

REM ====== Detectar NVENC y filtros CUDA ======
set "USE_GPU=0"
set "HAVE_SCALE_NPP=0"
set "HAVE_SCALE_CUDA=0"
set "HAVE_CROP_CUDA=0"

if "%FORCE_CPU%"=="0" (
  ffmpeg -hide_banner -encoders | findstr /i "h264_nvenc" >nul && set "USE_GPU=1"
  ffmpeg -hide_banner -filters  | findstr /i "scale_npp"  >nul && set "HAVE_SCALE_NPP=1"
  ffmpeg -hide_banner -filters  | findstr /i "scale_cuda" >nul && set "HAVE_SCALE_CUDA=1"
  ffmpeg -hide_banner -filters  | findstr /i "crop_cuda"  >nul && set "HAVE_CROP_CUDA=1"
)

REM ----- Comandos GPU/CPU -----
set "HWDEC_GPU=-hwaccel cuda -hwaccel_output_format cuda -extra_hw_frames 8"
set "VENC_PROXY_GPU=-c:v h264_nvenc -preset fast -qp 28"
set "VENC_RIGHT_GPU=-c:v h264_nvenc -preset fast -qp 30"

set "VENC_PROXY_CPU=-c:v libx264 -preset veryfast -crf 28"
set "VENC_RIGHT_CPU=-c:v libx264 -preset veryfast -crf 30"

REM Filtro proxy GPU/CPU
set "FC_PROXY_GPU="
if "%HAVE_SCALE_NPP%"=="1" (
  set "FC_PROXY_GPU=scale_npp=%W_PROXY%:%H_PROXY%"
) else if "%HAVE_SCALE_CUDA%"=="1" (
  set "FC_PROXY_GPU=scale_cuda=%W_PROXY%:%H_PROXY%"
)
set "FC_PROXY_CPU=scale=%W_PROXY%:%H_PROXY%:flags=fast_bilinear,format=yuv420p"

REM Filtro RIGHT GPU/CPU
set "FC_RIGHT_GPU="
if "%HAVE_CROP_CUDA%"=="1" (
  set "FC_RIGHT_GPU=crop_cuda=w=iw/2:h=ih:x=iw/2:y=0"
)
set "FC_RIGHT_CPU=crop=iw/2:ih:iw/2:0,format=yuv420p"

if "%USE_GPU%"=="1" (
  if not defined FC_PROXY_GPU (
    echo([WARN] GPU detectada pero no hay scale_cuda/scale_npp. Forzando CPU.
    set "USE_GPU=0"
  ) else (
    echo([INFO] Modo GPU: NVENC + %FC_PROXY_GPU%
  )
) else (
  echo([INFO] Modo CPU: libx264
)

REM ====== LISTAR KDOutput ======
set "SCAN_SWITCH="
if "%RECURSIVE_IN%"=="1" set "SCAN_SWITCH=/s"
del /q kd_list.txt 2>nul

if exist "%DIR_IN%\" (
  for %%E in (%EXTS%) do dir /a-d /b %SCAN_SWITCH% "%DIR_IN%\*.%%E" >> kd_list.txt 2>nul
  for %%A in ("kd_list.txt") do if %%~zA gtr 0 (
    echo([INFO] KDOutput detectado. Fuentes:
    type kd_list.txt
  ) else (
    echo([WARN] KDOutput no tiene archivos con extensiones: %EXTS%
  )
) else (
  echo([WARN] "%DIR_IN%" no existe. Saltando creacion de proxies/right.
)

REM ====== PROCESAR: PROXY -> RIGHT ======
set /a SRC_COUNT=0
set /a NEW_PROXY=0
set /a NEW_RIGHT=0
set /a FAIL_PROXY=0
set /a FAIL_RIGHT=0

if exist kd_list.txt for /f "usebackq delims=" %%F in ("kd_list.txt") do (
  set /a SRC_COUNT+=1
  call :PROCESS_ONE "%%~fF"
)

echo(
echo(==== RESUMEN ====
echo([INFO] Fuentes: %SRC_COUNT%
echo([INFO] Proxies nuevos creados: %NEW_PROXY% ^| Fallas proxy: %FAIL_PROXY%
echo([INFO] Rights nuevos creados:  %NEW_RIGHT% ^| Fallas right: %FAIL_RIGHT%

REM ====== SALTO SEGURO DEL FINAL ======
REM El orquestador ya valida integridad antes de llamar este BAT. Este control
REM adicional protege la ejecucion directa de una camara: si todas las fuentes
REM tienen su Right25, nada cambio durante esta pasada y el final existe, no se
REM vuelve a concatenar ni a codificar.
set /a RIGHT_COUNT=0
set /a RIGHT_INVALID=0
for /f "delims=" %%R in ('dir /b /a-d "%DIR_RIGHT%\*_right_%W_RIGHT%x%H_RIGHT%_%FPS_RIGHT%fps.mp4" 2^>nul') do (
  set /a RIGHT_COUNT+=1
  call :MEDIA_VALID "%DIR_RIGHT%\%%R" MEDIA_OK
  if "!MEDIA_OK!"=="0" set /a RIGHT_INVALID+=1
)
if "%RIGHT_COUNT%"=="0" for /f "delims=" %%R in ('dir /b /a-d "%DIR_RIGHT%\*_right_*.mp4" 2^>nul') do (
  set /a RIGHT_COUNT+=1
  call :MEDIA_VALID "%DIR_RIGHT%\%%R" MEDIA_OK
  if "!MEDIA_OK!"=="0" set /a RIGHT_INVALID+=1
)
set "FINAL_VALID=0"
if exist "%OUT_PATH%" call :MEDIA_VALID "%OUT_PATH%" FINAL_VALID
echo([INFO] Fuentes=%SRC_COUNT% Rights=%RIGHT_COUNT% RightsInvalidos=%RIGHT_INVALID% FinalValido=%FINAL_VALID%

if "%FAIL_PROXY%"=="0" if "%FAIL_RIGHT%"=="0" if "%NEW_PROXY%"=="0" if "%NEW_RIGHT%"=="0" if "%RIGHT_INVALID%"=="0" if "%FINAL_VALID%"=="1" if "%SRC_COUNT%"=="%RIGHT_COUNT%" if not "%SRC_COUNT%"=="0" (
  echo([KEEP] Final existente y partes sin cambios. No se concatena: "%OUT_PATH%"
  goto :END
)

REM ====== Construir lista desde Right25 ======
echo(
echo(==== Construyendo lista para concat desde "%DIR_RIGHT%" ====
del /q list_right.txt 2>nul

if /I "%ORDER_BY%"=="TIME" (set "DIR_SW=/o:d") else (set "DIR_SW=/o:n")

for /f "delims=" %%R in ('dir /b /a-d %DIR_SW% "%DIR_RIGHT%\*_right_%W_RIGHT%x%H_RIGHT%_%FPS_RIGHT%fps.mp4" 2^>nul') do (
  set "FN=%%~nxR"
  setlocal enabledelayedexpansion
  if /I not "!FN:~0,6!"=="FINAL_" echo file '%CD%\%DIR_RIGHT%\%%R'>>list_right.txt
  endlocal
)

if not exist "list_right.txt" (
  echo([WARN] No hay list_right.txt; probando *_right_*.mp4 ...
  for /f "delims=" %%R in ('dir /b /a-d %DIR_SW% "%DIR_RIGHT%\*_right_*.mp4" 2^>nul') do (
    set "FN=%%~nxR"
    setlocal enabledelayedexpansion
    if /I not "!FN:~0,6!"=="FINAL_" echo file '%CD%\%DIR_RIGHT%\%%R'>>list_right.txt
    endlocal
  )
)

if not exist "list_right.txt" (
  echo([ERROR] Right25 no contiene MP4 validos para concatenar. No se puede crear FINAL.
  goto :END
)

for %%A in ("list_right.txt") do set "LSZ=%%~zA"
if "%LSZ%"=="0" (
  echo([ERROR] Right25 no contiene MP4 validos para concatenar. No se puede crear FINAL.
  goto :END
)

echo([INFO] Archivos a concatenar:
type list_right.txt

REM ====== OVERLAY: N - NombreDelClip ======
set "ASS=overlay.ass"
set "PS_ASS=_mk_overlay_ass.ps1"
set "SUFFIX_NOEXT="

call :MAKE_ASS "%PS_ASS%" || (echo([ERROR] No se pudo escribir %PS_ASS% & goto :END)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_ASS%" -ListPath "list_right.txt" -AssPath "%ASS%" -FFProbe "ffprobe" -Suffix "%SUFFIX_NOEXT%"
if errorlevel 1 ( echo([ERROR] Powershell/ffprobe fallo creando ASS & goto :END )
if not exist "%ASS%" ( echo([ERROR] overlay.ass no existe & goto :END )

set "SUBFILTER=subtitles='%ASS:\=\\%'"
set "SUBFILTER=!SUBFILTER::=\:!"
echo([DBG] SUBFILTER=!SUBFILTER!

REM ====== Final (concat + overlay) ======
echo(
echo(==== Concatenando + overlay a "%OUT_PATH%" ====

if "%USE_GPU%"=="1" (
  set "VENC_FINAL=%VENC_RIGHT_GPU%"
) else (
  set "VENC_FINAL=%VENC_RIGHT_CPU%"
)

ffmpeg -hide_banner -loglevel error -stats -y -f concat -safe 0 -i list_right.txt ^
  -vf "!SUBFILTER!,fps=%FPS_RIGHT%,format=yuv420p" !VENC_FINAL! -c:a aac -b:a %A_BR_RIGHT% -ac %A_CH_RIGHT% -ar %A_AR_RIGHT% -movflags +faststart "%OUT_PATH%"

if exist "%OUT_PATH%" ( echo([OK] Final creado: "%OUT_PATH%" ) else ( echo([ERROR] No se pudo crear el final.) )

:END
if "%PAUSE_AT_END%"=="1" pause
if defined _DID_PUSHD popd
endlocal
exit /b


:PROCESS_ONE
set "IN_SRC=%~1"
for %%# in ("!IN_SRC!") do set "BASE=%%~n#"

REM --- SKIP estable [sin findstr, sin parentesis en echo] ---
set "SKIP=0"
set "T=!BASE!"
if /I not "!T:_proxy_=!"=="!T!" set "SKIP=1"
if /I not "!T:_right_=!"=="!T!" set "SKIP=1"
if /I not "!T:FINAL_=!"=="!T!" set "SKIP=1"
if "!SKIP!"=="1" (
  echo(
  echo([SKIP] !BASE! [parece proxy/right/final]
  exit /b 0
)

REM Nombres:
set "OUT_PROXY_NEW=%DIR_PROXY%\!BASE!_proxy.mp4"
set "OUT_PROXY_LEG=%DIR_PROXY%\!BASE!_proxy_%W_PROXY%x%H_PROXY%_%FPS_PROXY%fps.mp4"
set "OUT_RIGHT=%DIR_RIGHT%\!BASE!_right_%W_RIGHT%x%H_RIGHT%_%FPS_RIGHT%fps.mp4"

echo(
echo([FILE] !BASE!

REM 1) RESOLVER/CREAR PROXY
set "PROXY_PICK="
call :RESOLVE_PROXY "!BASE!"

if "%FILL_PROXIES%"=="1" (
  if defined PROXY_PICK (
    echo(  - Proxy ya existe: "!PROXY_PICK!"
  ) else (
    echo(  - Creando PROXY [nombre corto]...
    call :MAKE_PROXY "!IN_SRC!" "!OUT_PROXY_NEW!"
    if exist "!OUT_PROXY_NEW!" (
      for %%S in ("!OUT_PROXY_NEW!") do set "SZ=%%~zS"
      if "!SZ!"=="0" (
        echo(  [ERR] Proxy 0 bytes. Eliminando...
        del /q "!OUT_PROXY_NEW!" 2>nul
        set /a FAIL_PROXY+=1
        if "%PAUSE_ON_ERROR%"=="1" pause
      ) else (
        set "PROXY_PICK=!OUT_PROXY_NEW!"
        set /a NEW_PROXY+=1
      )
    ) else (
      echo(  [ERR] No se pudo crear PROXY para !BASE!
      set /a FAIL_PROXY+=1
      if "%PAUSE_ON_ERROR%"=="1" pause
    )
  )
) else (
  echo(  - FILL_PROXIES=0 [no se crean proxies]
)

REM 2) CREAR RIGHT [siempre desde PROXY]
if not defined PROXY_PICK call :RESOLVE_PROXY "!BASE!"

if "%FILL_RIGHTS%"=="1" (
  if not defined PROXY_PICK (
    echo(  [ERR] No hay proxy nuevo ni proxy legado. No puedo crear RIGHT.
    set /a FAIL_RIGHT+=1
    if "%PAUSE_ON_ERROR%"=="1" pause
    exit /b 0
  )

  if exist "!OUT_RIGHT!" (
    echo(  - Right ya existe: "!OUT_RIGHT!"
    exit /b 0
  )

  echo(  - Creando RIGHT desde: "!PROXY_PICK!"
  call :MAKE_RIGHT "!PROXY_PICK!" "!OUT_RIGHT!"

  if exist "!OUT_RIGHT!" (
    for %%S in ("!OUT_RIGHT!") do set "SZ=%%~zS"
    if "!SZ!"=="0" (
      echo(  [ERR] RIGHT 0 bytes. Eliminando...
      del /q "!OUT_RIGHT!" 2>nul
      set /a FAIL_RIGHT+=1
      if "%PAUSE_ON_ERROR%"=="1" pause
    ) else (
      set /a NEW_RIGHT+=1
    )
  ) else (
    echo(  [ERR] No se pudo crear RIGHT para !BASE!
    set /a FAIL_RIGHT+=1
    if "%PAUSE_ON_ERROR%"=="1" pause
  )
) else (
  echo(  - FILL_RIGHTS=0 [no se crean rights]
)

exit /b 0


:RESOLVE_PROXY
set "PROXY_PICK="
if exist "%DIR_PROXY%\%~1_proxy.mp4" (
  set "PROXY_PICK=%DIR_PROXY%\%~1_proxy.mp4"
  exit /b 0
)
if exist "%DIR_PROXY%\%~1_proxy_%W_PROXY%x%H_PROXY%_%FPS_PROXY%fps.mp4" (
  set "PROXY_PICK=%DIR_PROXY%\%~1_proxy_%W_PROXY%x%H_PROXY%_%FPS_PROXY%fps.mp4"
  exit /b 0
)
exit /b 0


:MEDIA_VALID
set "%~2=0"
for /f "usebackq delims=" %%V in (`ffprobe -v error -select_streams v:0 -show_entries stream^=index -of csv^=p^=0 "%~1" 2^>nul`) do set "%~2=1"
exit /b 0


:MAKE_PROXY
set "SRC=%~1"
set "DST=%~2"

if "%USE_GPU%"=="1" (
  ffmpeg -hide_banner -loglevel error -stats -y %HWDEC_GPU% -i "%SRC%" ^
    -vf "%FC_PROXY_GPU%" -r %FPS_PROXY% %VENC_PROXY_GPU% -c:a aac -b:a %A_BR_PROXY% -map 0:v:0 -map 0:a? -movflags +faststart "%DST%"
  if exist "%DST%" exit /b 0
  echo(    [WARN] PROXY GPU fallo - reintento CPU
)

ffmpeg -hide_banner -loglevel error -stats -y -i "%SRC%" ^
  -vf "%FC_PROXY_CPU%" -r %FPS_PROXY% %VENC_PROXY_CPU% -c:a aac -b:a %A_BR_PROXY% -map 0:v:0 -map 0:a? -movflags +faststart "%DST%"
exit /b 0


:MAKE_RIGHT
set "SRC=%~1"
set "DST=%~2"

if "%USE_GPU%"=="1" if defined FC_RIGHT_GPU (
  ffmpeg -hide_banner -loglevel error -stats -y %HWDEC_GPU% -i "%SRC%" ^
    -vf "%FC_RIGHT_GPU%" -r %FPS_RIGHT% %VENC_RIGHT_GPU% ^
    -c:a aac -b:a %A_BR_RIGHT% -ac %A_CH_RIGHT% -ar %A_AR_RIGHT% -map 0:v:0 -map 0:a? -movflags +faststart "%DST%"
  if exist "%DST%" exit /b 0
  echo(    [WARN] RIGHT GPU fallo - reintento CPU
)

ffmpeg -hide_banner -loglevel error -stats -y -i "%SRC%" ^
  -vf "%FC_RIGHT_CPU%" -r %FPS_RIGHT% %VENC_RIGHT_CPU% ^
  -c:a aac -b:a %A_BR_RIGHT% -ac %A_CH_RIGHT% -ar %A_AR_RIGHT% -map 0:v:0 -map 0:a? -movflags +faststart "%DST%"
exit /b 0


:MAKE_ASS
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
exit /b 0
