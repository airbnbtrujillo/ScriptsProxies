@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001>nul

REM ================= RUTAS BASE =================
REM Usar PUSHD permite ejecutar desde rutas de red UNC \\servidor\carpeta.
set "_DID_PUSHD="
pushd "%~dp0" || (
  echo([ERROR] No pude entrar a la carpeta del script: "%~dp0"
  echo([ERROR] Si esta en red, verifica permisos o mapea la ruta como unidad.
  endlocal
  exit /b 1
)
set "_DID_PUSHD=1"

set "ROOT=%CD%"
for %%I in ("%ROOT%\..") do set "PROJECT_DIR=%%~fI"
for %%I in ("%PROJECT_DIR%") do set "PROJECT=%%~nxI"

REM ================= CONFIG =================
set "TEMP_DIR=Proxy DJI OSMO RAW"
set "PROXY_SUFFIX=_DJIProxy_LEFT_960x960_20fps.mp4"
set "DUAL_DIR=Proxy DJI OSMO DUAL"
set "DUAL_SUFFIX=_DJI_DUAL_PREVIEW_2048x1024_25fps.mp4"
set "FILELIST=%ROOT%\filelist_dji_osmo.txt"
set "MANIFEST=%ROOT%\_concat_manifest_dji_osmo.txt"
set "SIGN_FILE=%ROOT%\_concat_sig_dji_osmo_overlay_v6_top_white.txt"
set "DUAL_FILELIST=%ROOT%\filelist_dji_osmo_dual.txt"
set "DUAL_MANIFEST=%ROOT%\_concat_manifest_dji_osmo_dual.txt"
set "DUAL_SIGN_FILE=%ROOT%\_concat_sig_dji_osmo_dual_v1.txt"
set "LOG=%ROOT%\dji_osmo_proxy_log.txt"
set "ASS=%ROOT%\overlay_dji_osmo.ass"
set "PS_ASS=%ROOT%\_mk_overlay_dji_osmo_ass.ps1"

set "V_FPS=20"
set "VF_LRF=crop=iw/2:ih:0:0,scale=960:960:force_original_aspect_ratio=decrease,pad=960:960:(ow-iw)/2:(oh-ih)/2,fps=%V_FPS%,format=yuv420p"
set "VF_OSV=scale=960:960:force_original_aspect_ratio=decrease,pad=960:960:(ow-iw)/2:(oh-ih)/2,fps=%V_FPS%,format=yuv420p"

set "V_CODEC=h264_nvenc"
set "V_PRESET=medium"
set "V_CQ=28"
set "V_BV=1200k"
set "V_MAX=1500k"

set "A_BR=32k"
set "A_AR=16000"
set "A_CH=1"

if exist "%LOG%" del /q "%LOG%" 2>nul
if exist "%FILELIST%" del /q "%FILELIST%" 2>nul
if exist "%MANIFEST%" del /q "%MANIFEST%" 2>nul
if exist "%DUAL_FILELIST%" del /q "%DUAL_FILELIST%" 2>nul
if exist "%DUAL_MANIFEST%" del /q "%DUAL_MANIFEST%" 2>nul
if exist "%ASS%" del /q "%ASS%" 2>nul
if exist "%PS_ASS%" del /q "%PS_ASS%" 2>nul

echo ===== RUN START ===== >"%LOG%"
echo ROOT=%ROOT%>>"%LOG%"
echo PROJECT_DIR=%PROJECT_DIR%>>"%LOG%"
echo PROJECT=%PROJECT%>>"%LOG%"

if /I "%ROOT%"=="C:\Windows" (
  echo([ERROR] ROOT resolvio a C:\Windows. No se entro a la carpeta real.
  echo ERROR ROOT C:\Windows>>"%LOG%"
  goto END
)

REM ================= FFMPEG =================
set "FFMPEG=C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffmpeg.exe"
if not exist "%FFMPEG%" set "FFMPEG=ffmpeg"

set "FFPROBE=C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffprobe.exe"
if not exist "%FFPROBE%" set "FFPROBE=ffprobe"

"%FFMPEG%" -version >nul 2>&1 || (
  echo([ERROR] ffmpeg no encontrado.
  echo ERROR ffmpeg no encontrado>>"%LOG%"
  goto END
)
"%FFPROBE%" -version >nul 2>&1 || (
  echo([ERROR] ffprobe no encontrado.
  echo ERROR ffprobe no encontrado>>"%LOG%"
  goto END
)

"%FFMPEG%" -hide_banner -v error -h encoder=%V_CODEC% >nul 2>&1
if errorlevel 1 (
  echo([AVISO] No NVENC, uso libx264.
  echo No NVENC, uso libx264>>"%LOG%"
  set "V_CODEC=libx264"
  set "V_PRESET=veryfast"
)

if not exist "%TEMP_DIR%" mkdir "%TEMP_DIR%" >nul 2>&1
if not exist "%DUAL_DIR%" mkdir "%DUAL_DIR%" >nul 2>&1

set "OUT_FILE=%PROJECT% DJI OSMO RAW Proxy Complete.mp4"
set "OUT_FULL=%PROJECT_DIR%\%OUT_FILE%"
set "OUT_FINAL_LOCAL=%ROOT%\%TEMP_DIR%\%OUT_FILE%"
set "DUAL_OUT_FILE=%PROJECT% DJI OSMO DUAL Preview Complete.mp4"
set "DUAL_OUT_FULL=%PROJECT_DIR%\%DUAL_OUT_FILE%"
set "DUAL_OUT_LOCAL=%ROOT%\%DUAL_DIR%\%DUAL_OUT_FILE%"

echo ==== DJI OSMO 360 PROXY LEFT 960x960 20fps ====
echo ROOT:  %ROOT%
echo FINAL: %OUT_FULL%
echo DUAL:  %DUAL_OUT_FULL%
echo LOG:   %LOG%
echo.

REM Preferimos LRF porque es el proxy interno liviano. Si no hay LRF, intenta OSV.
set /a IDX=0
set /a DUAL_IDX=0
for %%F in (*.LRF) do call :PROCESS_ONE "%%~fF"

if %IDX% EQU 0 (
  echo([WARN] No encontre LRF. Intentando OSV directo...
  echo No LRF; intentando OSV>>"%LOG%"
  for %%F in (*.OSV) do call :PROCESS_ONE "%%~fF"
)

if %DUAL_IDX% GTR 0 call :BUILD_DUAL_FINAL

if %IDX% EQU 0 (
  echo([ERROR] No se genero/ubico ningun proxy. Revisa archivos .LRF/.OSV.
  echo ERROR sin proxies>>"%LOG%"
  goto END
)

REM ================= FIRMAR MANIFIESTO =================
set "NEW_SIG="
for /f "tokens=* delims=" %%H in ('certutil -hashfile "%MANIFEST%" MD5 ^| findstr /r /b "[0-9A-F]"') do set "NEW_SIG=%%H"
set "NEW_SIG=%NEW_SIG: =%"

set "NEED_REBUILD=1"
if exist "%SIGN_FILE%" (
  set /p OLD_SIG=<"%SIGN_FILE%"
  set "OLD_SIG=!OLD_SIG: =!"
  if /I "!OLD_SIG!"=="!NEW_SIG!" if exist "%OUT_FULL%" (
    echo([SKIP] Final sin cambios: "%OUT_FULL%"
    echo SKIP final sin cambios>>"%LOG%"
    set "NEED_REBUILD=0"
  )
)

if "%NEED_REBUILD%"=="1" (
  echo Creando overlay con nombres de archivo...
  call :MAKE_ASS "%PS_ASS%"
  if errorlevel 1 (
    echo([ERROR] No se pudo escribir "%PS_ASS%"
    echo ERROR write PS_ASS>>"%LOG%"
    goto END
  )

  set "SUFFIX_NOEXT=%PROXY_SUFFIX:.mp4=%"
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_ASS%" -ListPath "%FILELIST%" -AssPath "%ASS%" -FFProbe "%FFPROBE%" -Suffix "!SUFFIX_NOEXT!"
  if errorlevel 1 (
    echo([ERROR] Powershell/ffprobe fallo creando overlay ASS.
    echo ERROR overlay ASS>>"%LOG%"
    goto END
  )
  if not exist "%ASS%" (
    echo([ERROR] No existe "%ASS%"
    echo ERROR ASS missing>>"%LOG%"
    goto END
  )

  set "SUBFILTER=subtitles='%ASS:\=\\%'"
  set "SUBFILTER=!SUBFILTER::=\:!"

  echo Uniendolo todo con nombres en "%OUT_FINAL_LOCAL%"...
  "%FFMPEG%" -y -hide_banner -loglevel warning -stats -f concat -safe 0 -i "%FILELIST%" ^
    -vf "!SUBFILTER!,fps=%V_FPS%,format=yuv420p" ^
    -c:v %V_CODEC% -cq %V_CQ% -b:v %V_BV% -maxrate %V_MAX% -bufsize %V_MAX% -pix_fmt yuv420p -preset %V_PRESET% ^
    -c:a aac -b:a 96k -ar 48000 -ac 2 "%OUT_FINAL_LOCAL%"
  if errorlevel 1 (
    echo([ERROR] Fallo la concatenacion final con overlay.
    echo ERROR concat final overlay>>"%LOG%"
    goto END
  )

  >"%SIGN_FILE%" echo %NEW_SIG%
  copy /y "%OUT_FINAL_LOCAL%" "%OUT_FULL%" >nul
  if errorlevel 1 (
    echo([AVISO] No pude copiar al padre. Final local:
    echo   "%OUT_FINAL_LOCAL%"
    echo COPY FAIL>>"%LOG%"
  ) else (
    echo([OK] Final copiado:
    echo   "%OUT_FULL%"
    echo COPY OK>>"%LOG%"
  )
)

echo.
echo LISTO:
echo   Proxies: "%ROOT%\%TEMP_DIR%"
echo   Final:   "%OUT_FULL%"
if %DUAL_IDX% GTR 0 (
  echo   Dual:    "%ROOT%\%DUAL_DIR%"
  echo   Preview: "%DUAL_OUT_FULL%"
)
echo DONE>>"%LOG%"
goto END

:PROCESS_ONE
set "IN=%~1"
for %%A in ("%IN%") do set "BASE=%%~nA"
for %%A in ("%IN%") do set "EXT=%%~xA"
set "OUT=%ROOT%\%TEMP_DIR%\!BASE!%PROXY_SUFFIX%"
set "OUT_UNIX=!OUT:\=/!"
set "DUAL_OUT=%ROOT%\%DUAL_DIR%\!BASE!%DUAL_SUFFIX%"
set "DUAL_OUT_UNIX=!DUAL_OUT:\=/!"
set "VF_USE=%VF_LRF%"
if /I "!EXT!"==".OSV" set "VF_USE=%VF_OSV%"

"%FFPROBE%" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "%IN%" >nul 2>&1
if errorlevel 1 (
  echo([SKIP] No legible: "%IN%"
  echo SKIP no legible "%IN%">>"%LOG%"
  exit /b 0
)

if exist "!OUT!" (
  echo([SKIP] !BASE! proxy existe.
  echo SKIP "!OUT!">>"%LOG%"
) else (
  echo([NEW ] !BASE!
  echo Procesando "%IN%" ^> "!OUT!">>"%LOG%"
  "%FFMPEG%" -y -hide_banner -loglevel warning -stats -i "%IN%" -vf "!VF_USE!" ^
    -c:v %V_CODEC% -cq %V_CQ% -b:v %V_BV% -maxrate %V_MAX% -bufsize %V_MAX% -pix_fmt yuv420p -preset %V_PRESET% ^
    -c:a aac -b:a %A_BR% -ar %A_AR% -ac %A_CH% -map 0:v:0 -map 0:a? -movflags +faststart "!OUT!"
  if errorlevel 1 (
    echo([ERROR] ffmpeg fallo con !BASE!
    echo ERROR ffmpeg "!IN!">>"%LOG%"
    if exist "!OUT!" del /q "!OUT!" 2>nul
    exit /b 0
  )
)

REM El LRF ya contiene las dos lentes lado a lado. Creamos un preview dual
REM sin tocar el OSV 8K y conservamos el proxy izquierdo existente.
if /I "!EXT!"==".LRF" (
  if exist "!DUAL_OUT!" (
    echo([SKIP] !BASE! preview DUAL existe.
    echo SKIP DUAL "!DUAL_OUT!">>"%LOG%"
  ) else (
    echo([DUAL] !BASE! ^(dos lentes desde LRF^)
    echo Procesando DUAL "%IN%" ^> "!DUAL_OUT!">>"%LOG%"
    REM LRF ya es H.264 + AAC compatible con MP4. Solo reempaquetamos:
    REM no hay render, no se pierde calidad y no se toca el OSV 8K.
    "%FFMPEG%" -y -hide_banner -loglevel warning -stats -i "%IN%" ^
      -map 0:v:0 -map 0:a? -c copy -movflags +faststart "!DUAL_OUT!"
    if errorlevel 1 (
      echo([ERROR] ffmpeg fallo creando DUAL para !BASE!
      echo ERROR DUAL ffmpeg "%IN%">>"%LOG%"
      if exist "!DUAL_OUT!" del /q "!DUAL_OUT!" 2>nul
    )
  )
  if exist "!DUAL_OUT!" (
    set /a DUAL_IDX+=1
    >>"%DUAL_FILELIST%" echo file '!DUAL_OUT_UNIX!'
    for %%X in ("!DUAL_OUT!") do (
      set "DFSZ=%%~zX"
      set "DFTS=%%~tX"
    )
    >>"%DUAL_MANIFEST%" echo !DFSZ!^|!DFTS!^|!DUAL_OUT_UNIX!
  )
)

if exist "!OUT!" (
  set /a IDX+=1
  >>"%FILELIST%" echo file '!OUT_UNIX!'
  for %%X in ("!OUT!") do (
    set "FSZ=%%~zX"
    set "FTS=%%~tX"
  )
  >>"%MANIFEST%" echo !FSZ!^|!FTS!^|!OUT_UNIX!
)
exit /b 0

:BUILD_DUAL_FINAL
set "DUAL_NEW_SIG="
for /f "tokens=* delims=" %%H in ('certutil -hashfile "%DUAL_MANIFEST%" MD5 ^| findstr /r /b "[0-9A-F]"') do set "DUAL_NEW_SIG=%%H"
set "DUAL_NEW_SIG=!DUAL_NEW_SIG: =!"
set "DUAL_NEED_REBUILD=1"
if exist "%DUAL_SIGN_FILE%" (
  set /p DUAL_OLD_SIG=<"%DUAL_SIGN_FILE%"
  set "DUAL_OLD_SIG=!DUAL_OLD_SIG: =!"
  if /I "!DUAL_OLD_SIG!"=="!DUAL_NEW_SIG!" if exist "%DUAL_OUT_FULL%" set "DUAL_NEED_REBUILD=0"
)
if "!DUAL_NEED_REBUILD!"=="0" (
  echo([SKIP] Preview DUAL final sin cambios.
  echo SKIP DUAL final sin cambios>>"%LOG%"
  exit /b 0
)
echo Uniendo preview DUAL de dos lentes...
"%FFMPEG%" -y -hide_banner -loglevel warning -stats -f concat -safe 0 -i "%DUAL_FILELIST%" ^
  -map 0:v:0 -map 0:a? -c copy -movflags +faststart "%DUAL_OUT_LOCAL%"
if errorlevel 1 (
  echo([WARN] Concat DUAL directo fallo; reintentando con codificacion.
  echo WARN DUAL concat copy fallo; reencode>>"%LOG%"
  "%FFMPEG%" -y -hide_banner -loglevel warning -stats -f concat -safe 0 -i "%DUAL_FILELIST%" ^
    -vf "fps=%V_FPS%,format=yuv420p" ^
    -c:v %V_CODEC% -cq %V_CQ% -b:v 2200k -maxrate 3000k -bufsize 3000k -pix_fmt yuv420p -preset %V_PRESET% ^
    -c:a aac -b:a 64k -ar 48000 -ac 2 "%DUAL_OUT_LOCAL%"
)
if errorlevel 1 (
  echo([ERROR] No se pudo crear el preview DUAL final.
  echo ERROR DUAL final>>"%LOG%"
  exit /b 0
)
copy /y "%DUAL_OUT_LOCAL%" "%DUAL_OUT_FULL%" >nul
if errorlevel 1 (
  echo([WARN] Preview DUAL quedo local: "%DUAL_OUT_LOCAL%"
) else (
  >"%DUAL_SIGN_FILE%" echo !DUAL_NEW_SIG!
  echo([OK] Preview DUAL: "%DUAL_OUT_FULL%"
  echo OK DUAL "%DUAL_OUT_FULL%">>"%LOG%"
)
exit /b 0

:MAKE_ASS
REM ASS: texto superior con "N - nombre del archivo" durante cada proxy.
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
>>"%~1" echo $lines += "Style: Top,Arial,26,&H00FFFFFF,&H00FFFFFF,&H99000000,&H66000000,0,0,0,0,100,100,0,0,1,2,1,8,10,10,28,1"
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

:END
echo ===== RUN END =====>>"%LOG%"
if defined _DID_PUSHD popd
endlocal
exit /b
