@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001>nul

REM TARSIER Proxy rapido v2
REM Entrada: carpeta Videos o, si no existe, los videos de la carpeta actual.
REM Right25 es el preview para Premiere: ojo derecho 960x960 a 25 fps.
REM Usa HEVC CUDA + scale_cuda + NVENC cuando estan disponibles.
REM Nunca modifica originales. Los temporales invalidos se archivan en _HISTORICO.

set "_DID_PUSHD="
pushd "%~dp0" || (echo([ERROR] No pude entrar a "%~dp0" & endlocal & exit /b 1)
set "_DID_PUSHD=1"
set "RUN_FAILED=0"
set "ROOT=%CD%"
for %%I in ("%ROOT%\..") do set "PROJECT_DIR=%%~fI"
for %%I in ("%PROJECT_DIR%") do set "PROJECT=%%~nxI"

REM ==================== CONFIG RAPIDA ====================
set "DIR_IN=Videos"
set "DIR_PROXY=Proxies"
set "DIR_RIGHT=Right25"
set "CREATE_SBS_PROXY=0"
set "W_PROXY=1280"
set "H_PROXY=640"
set "W_RIGHT=960"
set "H_RIGHT=960"
set "FPS=25"
set "EXTS=mp4 mov mkv m4v"
set "PAUSE_AT_END=0"

REM CREATE_SBS_PROXY=0 evita un proxy SBS intermedio innecesario.
REM Ponlo en 1 solo si tambien necesitas un preview SBS 1280x640.

set "FFMPEG=ffmpeg"
set "FFPROBE=ffprobe"
%FFMPEG% -version >nul 2>&1 || if exist "C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffmpeg.exe" set "FFMPEG=C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffmpeg.exe"
%FFPROBE% -version >nul 2>&1 || if exist "C:\ffmpeg\ffprobe.exe" set "FFPROBE=C:\ffmpeg\ffprobe.exe"
%FFMPEG% -version >nul 2>&1 || (echo([ERROR] ffmpeg no esta disponible & goto END)
%FFPROBE% -version >nul 2>&1 || (echo([ERROR] ffprobe no esta disponible & goto END)

if not exist "%DIR_PROXY%" mkdir "%DIR_PROXY%" >nul 2>&1
if not exist "%DIR_RIGHT%" mkdir "%DIR_RIGHT%" >nul 2>&1

set "USE_GPU=0"
%FFMPEG% -hide_banner -encoders 2>nul | findstr /i "h264_nvenc" >nul && %FFMPEG% -hide_banner -filters 2>nul | findstr /i "scale_cuda" >nul && set "USE_GPU=1"
if "%USE_GPU%"=="1" (echo([INFO] GPU: HEVC CUDA + scale_cuda + NVENC) else (echo([WARN] GPU CUDA/NVENC no disponible. Se usa CPU.)

set "OUT_FINAL=%PROJECT_DIR%\%PROJECT% TARSIER RAW PROXY Complete.mp4"
set "FILELIST=%ROOT%\_tarsier_concat.txt"
set "ASS=%ROOT%\_tarsier_overlay.ass"
set "PS_ASS=%ROOT%\_tarsier_make_ass.ps1"
set "LIST=%ROOT%\_tarsier_sources.txt"

REM ==================== DESCUBRIR FUENTES ====================
set "INPUT_ROOT=%ROOT%\%DIR_IN%"
del /q "%LIST%" 2>nul
if exist "%INPUT_ROOT%\" (
  for %%E in (%EXTS%) do dir /a-d /b /s "%INPUT_ROOT%\*.%%E" >> "%LIST%" 2>nul
  set "SOURCE_MODE=Videos"
) else (
  for %%E in (%EXTS%) do dir /a-d /b "%ROOT%\*.%%E" >> "%LIST%" 2>nul
  set "SOURCE_MODE=carpeta actual"
)
for %%A in ("%LIST%") do if %%~zA EQU 0 (echo([ERROR] No encontre videos en %SOURCE_MODE%. & goto END)

echo([INFO] Fuentes detectadas en %SOURCE_MODE%:
type "%LIST%"
set /a SRC_COUNT=0
set /a NEW_PROXY=0
set /a NEW_RIGHT=0
if exist "%LIST%" for /f "usebackq delims=" %%F in ("%LIST%") do (
  set /a SRC_COUNT+=1
  call :PROCESS_ONE "%%~fF"
)

REM ==================== VALIDAR PARTES Y DECIDIR FINAL ====================
set /a RIGHT_COUNT=0
set /a RIGHT_INVALID=0
for /f "delims=" %%R in ('dir /b /a-d "%DIR_RIGHT%\*_right_%W_RIGHT%x%H_RIGHT%_%FPS%fps.mp4" 2^>nul') do (
  set /a RIGHT_COUNT+=1
  call :HAS_VIDEO "%DIR_RIGHT%\%%R" RIGHT_OK
  if "!RIGHT_OK!"=="0" set /a RIGHT_INVALID+=1
)
echo([INFO] Fuentes=%SRC_COUNT% Rights=%RIGHT_COUNT% RightsInvalidos=%RIGHT_INVALID% Nuevos=%NEW_RIGHT%
if not "%SRC_COUNT%"=="%RIGHT_COUNT%" (echo([ERROR] Cantidad de fuentes y Right25 diferente. No se crea final. & set "RUN_FAILED=1" & goto END)
if not "%RIGHT_INVALID%"=="0" (echo([ERROR] Hay Right25 invalidos. No se crea final. & set "RUN_FAILED=1" & goto END)

set "FINAL_OK=0"
if exist "%OUT_FINAL%" call :HAS_VIDEO "%OUT_FINAL%" FINAL_OK
if "%NEW_RIGHT%"=="0" if "%FINAL_OK%"=="1" (echo([KEEP] Final Tarsier existente y partes sin cambios. No se renderiza. & goto END)

REM ==================== CONCATENAR FINAL UNA SOLA VEZ ====================
del /q "%FILELIST%" 2>nul
for /f "delims=" %%R in ('dir /b /a-d /o:n "%DIR_RIGHT%\*_right_%W_RIGHT%x%H_RIGHT%_%FPS%fps.mp4" 2^>nul') do (
  set "P=%ROOT%\%DIR_RIGHT%\%%R"
  set "P=!P:\=/!"
  >> "%FILELIST%" echo file '!P!'
)
for %%A in ("%FILELIST%") do if %%~zA EQU 0 (echo([ERROR] No se pudo crear la lista de Right25. & set "RUN_FAILED=1" & goto END)

call :MAKE_ASS "%PS_ASS%"
if errorlevel 1 (echo([ERROR] No se pudo preparar el overlay. & set "RUN_FAILED=1" & goto END)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_ASS%" -ListPath "%FILELIST%" -AssPath "%ASS%" -FFProbe "%FFPROBE%"
if errorlevel 1 (echo([ERROR] No se pudo generar el overlay. & set "RUN_FAILED=1" & goto END)

set "FINAL_TMP=%OUT_FINAL%.partial.mp4"
del /q "%FINAL_TMP%" 2>nul
set "SUBFILTER=subtitles='%ASS:\=\\%'"
set "SUBFILTER=!SUBFILTER::=\:!"
echo([INFO] Creando final TARSIER desde Right25...
%FFMPEG% -y -hide_banner -loglevel warning -stats -f concat -safe 0 -i "%FILELIST%" ^
  -vf "!SUBFILTER!,fps=%FPS%,format=yuv420p" -c:v h264_nvenc -preset p1 -cq 30 -c:a aac -b:a 32k -ac 1 -ar 16000 -movflags +faststart "%FINAL_TMP%"
if errorlevel 1 (
  echo([WARN] Final NVENC fallo; reintentando con libx264.
  %FFMPEG% -y -hide_banner -loglevel warning -stats -f concat -safe 0 -i "%FILELIST%" ^
    -vf "!SUBFILTER!,fps=%FPS%,format=yuv420p" -c:v libx264 -preset ultrafast -crf 30 -c:a aac -b:a 32k -ac 1 -ar 16000 -movflags +faststart "%FINAL_TMP%"
)
call :HAS_VIDEO "%FINAL_TMP%" FINAL_TMP_OK
if not "%FINAL_TMP_OK%"=="1" (echo([ERROR] El final temporal es invalido; se conserva el final anterior. & set "RUN_FAILED=1" & goto END)
move /y "%FINAL_TMP%" "%OUT_FINAL%" >nul
echo([OK] Final creado: "%OUT_FINAL%"
goto END

:PROCESS_ONE
set "IN_SRC=%~1"
for %%I in ("%~1") do set "BASE=%%~nI"
set "OUT_PROXY=%DIR_PROXY%\!BASE!_proxy_%W_PROXY%x%H_PROXY%_%FPS%fps.mp4"
set "OUT_RIGHT=%DIR_RIGHT%\!BASE!_right_%W_RIGHT%x%H_RIGHT%_%FPS%fps.mp4"
echo([FILE] !BASE!

if "%CREATE_SBS_PROXY%"=="1" (
  set "PROXY_OK=0"
  if exist "!OUT_PROXY!" call :HAS_VIDEO "!OUT_PROXY!" PROXY_OK
  if "!PROXY_OK!"=="1" (
    echo(  [KEEP] Proxy SBS existente
  ) else (
    if exist "!OUT_PROXY!" call :ARCHIVE_INVALID "!OUT_PROXY!"
    call :MAKE_PROXY "!IN_SRC!" "!OUT_PROXY!"
    call :HAS_VIDEO "!OUT_PROXY!" PROXY_OK
    if "!PROXY_OK!"=="1" (set /a NEW_PROXY+=1) else (echo(  [ERROR] No se pudo crear proxy SBS & set "RUN_FAILED=1")
  )
)

set "RIGHT_OK=0"
if exist "!OUT_RIGHT!" call :HAS_VIDEO "!OUT_RIGHT!" RIGHT_OK
if "!RIGHT_OK!"=="1" (echo(  [KEEP] Right25 existente & exit /b 0)
if exist "!OUT_RIGHT!" call :ARCHIVE_INVALID "!OUT_RIGHT!"
call :MAKE_RIGHT "!IN_SRC!" "!OUT_RIGHT!"
call :HAS_VIDEO "!OUT_RIGHT!" RIGHT_OK
if "!RIGHT_OK!"=="1" (set /a NEW_RIGHT+=1) else (echo(  [ERROR] No se pudo crear Right25 & set "RUN_FAILED=1")
exit /b 0

:MAKE_PROXY
set "SRC=%~1"
set "DST=%~2"
set "TMP=%DST%.partial.mp4"
del /q "%TMP%" 2>nul
if "%USE_GPU%"=="1" %FFMPEG% -y -hide_banner -loglevel warning -stats -hwaccel cuda -hwaccel_output_format cuda -i "%SRC%" ^
  -filter_complex "[0:v]fps=%FPS%,scale_cuda=%W_PROXY%:%H_PROXY%[v]" -map "[v]" -map 0:a? -c:v h264_nvenc -preset p1 -cq 31 -c:a aac -b:a 64k -movflags +faststart "%TMP%"
if not exist "%TMP%" %FFMPEG% -y -hide_banner -loglevel warning -stats -i "%SRC%" ^
  -vf "fps=%FPS%,scale=%W_PROXY%:%H_PROXY%:flags=fast_bilinear,format=yuv420p" -map 0:v:0 -map 0:a? -c:v libx264 -preset ultrafast -crf 30 -c:a aac -b:a 64k -movflags +faststart "%TMP%"
call :HAS_VIDEO "%TMP%" TMP_OK
if "%TMP_OK%"=="1" move /y "%TMP%" "%DST%" >nul
exit /b 0

:MAKE_RIGHT
set "SRC=%~1"
set "DST=%~2"
set "TMP=%DST%.partial.mp4"
del /q "%TMP%" 2>nul
if "%USE_GPU%"=="1" %FFMPEG% -y -hide_banner -loglevel warning -stats -hwaccel cuda -hwaccel_output_format cuda -i "%SRC%" ^
  -filter_complex "[0:v]fps=%FPS%,scale_cuda=1920:960,hwdownload,format=nv12,crop=%W_RIGHT%:%H_RIGHT%:%W_RIGHT%:0,format=yuv420p[v]" -map "[v]" -map 0:a? -c:v h264_nvenc -preset p1 -cq 31 -c:a aac -b:a 32k -ac 1 -ar 16000 -movflags +faststart "%TMP%"
if not exist "%TMP%" %FFMPEG% -y -hide_banner -loglevel warning -stats -i "%SRC%" ^
  -vf "crop=iw/2:ih:iw/2:0,fps=%FPS%,scale=%W_RIGHT%:%H_RIGHT%:flags=fast_bilinear,format=yuv420p" -map 0:v:0 -map 0:a? -c:v libx264 -preset ultrafast -crf 30 -c:a aac -b:a 32k -ac 1 -ar 16000 -movflags +faststart "%TMP%"
call :HAS_VIDEO "%TMP%" TMP_OK
if "%TMP_OK%"=="1" move /y "%TMP%" "%DST%" >nul
exit /b 0

:HAS_VIDEO
set "%~2=0"
if not exist "%~1" exit /b 0
for /f "usebackq delims=" %%V in (`"%FFPROBE%" -v error -select_streams v:0 -show_entries stream^=index -of csv^=p^=0 "%~1" 2^>nul`) do set "%~2=1"
exit /b 0

:ARCHIVE_INVALID
if not exist "%~1" exit /b 0
set "HIST=%~dp1_HISTORICO"
if not exist "%HIST%" mkdir "%HIST%" >nul 2>&1
move /y "%~1" "%HIST%\%~nx1.invalid.%RANDOM%" >nul
exit /b 0

:MAKE_ASS
> "%~1" echo param([string]$ListPath,[string]$AssPath,[string]$FFProbe)
>> "%~1" echo $ErrorActionPreference='Stop'; $acc=0.0; $idx=1; $lines=@()
>> "%~1" echo $lines += '[Script Info]'; $lines += 'ScriptType: v4.00+'; $lines += ''
>> "%~1" echo $lines += '[V4+ Styles]'
>> "%~1" echo $lines += 'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding'
>> "%~1" echo $lines += 'Style: Top,Arial,14,^&H33FFFFFF,^&H00FFFFFF,^&H66000000,^&H00000000,0,0,0,0,100,100,0,0,1,1,0,8,10,10,4,1'
>> "%~1" echo $lines += ''; $lines += '[Events]'
>> "%~1" echo $lines += 'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text'
>> "%~1" echo Get-Content -LiteralPath $ListPath ^| ForEach-Object {
>> "%~1" echo ^ if ($_ -match "^file '(.+)'$") {
>> "%~1" echo ^  $p=$Matches[1].Replace('/','\'); $dur=^& $FFProbe -v error -show_entries format^=duration -of default^=noprint_wrappers^=1:nokey^=1 $p
>> "%~1" echo ^  if (-not $dur) { throw "ffprobe sin duracion: $p" }; $dur=[double]::Parse($dur,[Globalization.CultureInfo]::InvariantCulture)
>> "%~1" echo ^  $st=[TimeSpan]::FromSeconds($acc).ToString('hh\:mm\:ss\.ff'); $et=[TimeSpan]::FromSeconds($acc+[Math]::Max($dur-0.04,0.01)).ToString('hh\:mm\:ss\.ff')
>> "%~1" echo ^  $label=[IO.Path]::GetFileNameWithoutExtension($p) -replace '\{','(' -replace '\}',' )'; $lines += "Dialogue: 0,$st,$et,Top,,0000,0000,0000,,$idx - $label"; $acc += $dur; $idx++
>> "%~1" echo ^ }
>> "%~1" echo }
>> "%~1" echo Set-Content -LiteralPath $AssPath -Value $lines -Encoding UTF8
exit /b 0

:END
if exist "%FILELIST%" del /q "%FILELIST%" 2>nul
if exist "%LIST%" del /q "%LIST%" 2>nul
if defined _DID_PUSHD popd
if "%PAUSE_AT_END%"=="1" pause
endlocal & exit /b %RUN_FAILED%
