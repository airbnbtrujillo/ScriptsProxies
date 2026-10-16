@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul

REM ============================================================================
REM TOOL-08 - Proxies FFmpeg a 1/6, con el mismo nombre del original
REM
REM Uso:
REM   1. Doble clic y pega/arrastra una carpeta de proyecto o una carpeta Videos.
REM   2. Si indicas un proyecto que contiene Videos, lee solamente Videos.
REM   3. Si indicas Videos directamente, la usa como entrada.
REM
REM Salida segura:
REM   Videos\Proxies\[misma subcarpeta]\[mismo nombre y extension].
REM Nunca escribe encima del original. Son MP4 ligeros para editar, transportar
REM o visualizar rapidamente desde cualquier programa.
REM ============================================================================

set "SCRIPT_VER=TOOL-08 Proxies FFmpeg 1/6"
set "EXTS=mp4 mov mkv m4v"
set "AUDIO_BITRATE=96k"
set "RUN_STAMP="
for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "RUN_STAMP=%%I"

echo(
echo([INFO] %SCRIPT_VER%
echo([INFO] Cada dimension se reduce a 1/6 y se redondea a un numero par.
echo([INFO] Originales: solo lectura. Proxies: carpeta Proxies con el mismo nombre.

if not "%~1"=="" set "SELECTED=%~1"
if defined SELECTED goto :RESOLVE_INPUT

echo(Pega o arrastra la carpeta de proyecto o la carpeta Videos y pulsa Enter:
set /p "SELECTED=Carpeta: "
if not defined SELECTED goto :END

:RESOLVE_INPUT
for %%A in ("%SELECTED%") do set "SELECTED=%%~fA"
if not exist "%SELECTED%\" (
  echo([ERROR] La carpeta no existe: "%SELECTED%"
  goto :END
)

if exist "%SELECTED%\Videos\" (
  set "SRC=%SELECTED%\Videos"
) else (
  set "SRC=%SELECTED%"
)
set "DST=%SRC%\Proxies"

where ffmpeg >nul 2>&1 || (
  echo([ERROR] ffmpeg no esta disponible en PATH.
  goto :END
)
where ffprobe >nul 2>&1 || (
  echo([ERROR] ffprobe no esta disponible en PATH.
  goto :END
)
if not exist "%DST%\" md "%DST%"

set /a FOUND=0
set /a CREATED=0
set /a REUSED=0
set /a FAILED=0

echo(
echo([INFO] Entrada: "%SRC%"
echo([INFO] Salida:  "%DST%"
echo(

REM PROCESS_ONE descarta Proxies e historicos para que este script nunca
REM procese sus propias salidas ni resultados recuperables como originales.
for %%E in (%EXTS%) do (
  for /f "usebackq delims=" %%F in (`dir /b /s /a-d "%SRC%\*.%%E" 2^>nul`) do call :PROCESS_ONE "%%F"
)

echo(
echo(================ RESUMEN ================
echo([INFO] Originales encontrados: %FOUND%
echo([INFO] Proxies nuevos:        %CREATED%
echo([INFO] Proxies reutilizados:  %REUSED%
echo([INFO] Fallas:                %FAILED%
echo(===========================================
goto :END


:PROCESS_ONE
set "IN_FILE=%~1"
set "CHECK_PATH=!IN_FILE:%DST%\=!"
if /I not "!CHECK_PATH!"=="!IN_FILE!" exit /b 0
set "CHECK_PATH=!IN_FILE:%SRC%\_HISTORICO\=!"
if /I not "!CHECK_PATH!"=="!IN_FILE!" exit /b 0
set /a FOUND+=1
set "REL=!IN_FILE:%SRC%\=!"
set "OUT_FILE=%DST%\!REL!"
for %%D in ("!OUT_FILE!") do set "OUT_DIR=%%~dpD"
if not exist "!OUT_DIR!" md "!OUT_DIR!"

for %%A in ("!IN_FILE!") do set "BASE=%%~nxA"
echo([FILE] !REL!

if not exist "!OUT_FILE!" goto :CREATE_PROXY
call :PROXY_VALID "!IN_FILE!" "!OUT_FILE!" OUT_VALID
if "!OUT_VALID!"=="1" (
  echo(  [KEEP] Proxy valido ya existe.
  set /a REUSED+=1
  exit /b 0
)

echo(  [WARN] Proxy existente invalido o no es 1/6. Se archiva y se rehace.
call :ARCHIVE_INVALID "!OUT_FILE!"

:CREATE_PROXY
for %%A in ("!OUT_FILE!") do set "TMP=%%~dpnA.partial%%~xA"
if exist "!TMP!" del /q "!TMP!" 2>nul

REM scale calcula 1/6 del ancho y alto originales y los hace pares para H.264.
REM No se fija FPS: se conserva el tiempo/FPS del original para sincronizar.
ffmpeg -hide_banner -loglevel error -stats -y -i "!IN_FILE!" ^
  -map 0:v:0 -map 0:a? -vf "scale=trunc(iw/6/2)*2:trunc(ih/6/2)*2:flags=fast_bilinear,format=yuv420p" ^
  -c:v libx264 -preset ultrafast -crf 28 -c:a aac -b:a %AUDIO_BITRATE% -movflags +faststart "!TMP!"

call :PROXY_VALID "!IN_FILE!" "!TMP!" TMP_VALID
if not "!TMP_VALID!"=="1" goto :CREATE_FAILED
move /y "!TMP!" "!OUT_FILE!" >nul
echo(  [OK] Proxy creado: "!OUT_FILE!"
set /a CREATED+=1
exit /b 0

:CREATE_FAILED
if exist "!TMP!" del /q "!TMP!" 2>nul
echo(  [ERROR] No se pudo crear un proxy valido: !PROXY_REASON!
set /a FAILED+=1
exit /b 0


:PROXY_VALID
REM %1 original, %2 proxy, %3 variable resultado. Exige video y dimensiones 1/6.
set "%~3=0"
set "PROXY_REASON=el archivo proxy no existe"
if not exist "%~2" exit /b 0
set "IW="
set "IH="
set "OW="
set "OH="
for /f "usebackq delims=" %%V in (`ffprobe -v error -select_streams v:0 -show_entries stream^=width -of csv^=p^=0 "%~1" 2^>nul`) do set "IW=%%V"
for /f "usebackq delims=" %%V in (`ffprobe -v error -select_streams v:0 -show_entries stream^=height -of csv^=p^=0 "%~1" 2^>nul`) do set "IH=%%V"
for /f "usebackq delims=" %%V in (`ffprobe -v error -select_streams v:0 -show_entries stream^=width -of csv^=p^=0 "%~2" 2^>nul`) do set "OW=%%V"
for /f "usebackq delims=" %%V in (`ffprobe -v error -select_streams v:0 -show_entries stream^=height -of csv^=p^=0 "%~2" 2^>nul`) do set "OH=%%V"
if not defined IW (
  set "PROXY_REASON=ffprobe no pudo leer el ancho del original"
  exit /b 0
)
if not defined IH (
  set "PROXY_REASON=ffprobe no pudo leer el alto del original"
  exit /b 0
)
if not defined OW (
  set "PROXY_REASON=ffprobe no pudo leer el ancho del proxy"
  exit /b 0
)
if not defined OH (
  set "PROXY_REASON=ffprobe no pudo leer el alto del proxy"
  exit /b 0
)
set /a EW=IW/6/2*2
set /a EH=IH/6/2*2
REM FFmpeg respeta la metadata de rotacion: un original 1280x720 marcado como
REM vertical produce 120x212. Ambas orientaciones son el mismo 1/6 valido.
if "!OW!"=="!EW!" if "!OH!"=="!EH!" (
  set "%~3=1"
  set "PROXY_REASON=valido (!OW!x!OH!)"
  exit /b 0
)
if "!OW!"=="!EH!" if "!OH!"=="!EW!" (
  set "%~3=1"
  set "PROXY_REASON=valido con rotacion (!OW!x!OH!)"
  exit /b 0
)
set "PROXY_REASON=dimension proxy !OW!x!OH!; se esperaba !EW!x!EH! o !EH!x!EW! con rotacion, desde original !IW!x!IH!"
exit /b 0


:ARCHIVE_INVALID
for %%A in ("%~1") do (
  set "BAD_FILE=%%~fA"
  set "BAD_DIR=%%~dpA"
)
if not exist "%BAD_FILE%" exit /b 0
set "HIST_DIR=%BAD_DIR%_HISTORICO\%RUN_STAMP%"
if not exist "%HIST_DIR%" md "%HIST_DIR%" 2>nul
move /y "%BAD_FILE%" "%HIST_DIR%\%~nx1" >nul
if exist "%BAD_FILE%" (
  echo(  [WARN] No se pudo archivar el proxy anterior.
) else (
  echo(  [KEEP] Proxy anterior: "%HIST_DIR%\%~nx1"
)
exit /b 0


:END
endlocal
exit /b
