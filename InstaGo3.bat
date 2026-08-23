@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM === Debe ejecutarse dentro de ...\72 - Mia - Happy Halowwen\InstaGo
REM IMPORTANTE: usar PUSHD en vez de CD, porque CD falla con rutas de red UNC \\servidor\carpeta
set "_DID_PUSHD="
pushd "%~dp0" || (
  echo([ERROR] No pude entrar a la carpeta del script: "%~dp0"
  echo([ERROR] Si esta en red, verifica permisos o mapea la ruta como unidad.
  endlocal
  exit /b 1
)
set "_DID_PUSHD=1"

REM ---- ffmpeg disponible? ----
set "FFMPEG=ffmpeg"
%FFMPEG% -version >nul 2>&1 || (
  echo [ERROR] No se encontro ffmpeg en PATH.
  pause
  exit /b 1
)

REM ---- Rutas/Nombres ----
set "CUR=%CD%"
for %%I in ("%CUR%\..") do set "PARENT=%%~fI"
for %%I in ("%PARENT%") do set "PROJECT=%%~nxI"

set "OUT_NAME=%PROJECT% GO3 RAW PROXY Complete.mp4"
set "OUT_FULL=%PARENT%\%OUT_NAME%"
set "LIST=%CUR%\_to_concat.txt"

echo ==== GO3 Concat LRV (robusto) ====
echo Carpeta clips : "%CUR%"
echo Proyecto      : "%PROJECT%"
echo Salida        : "%OUT_FULL%"
echo.

REM ---- Construir lista (orden por nombre) solo archivos LRV_* ----
del "%LIST%" 2>nul

set /a COUNT=0
REM Usamos DIR para evitar que FOR incluya el literal del patron cuando no hay match
for /f "delims=" %%F in ('
  dir /b /a:-d /on LRV_*.mp4 LRV_*.MP4 LRV_*.lrv LRV_*.LRV 2^>nul
') do (
  set /a COUNT+=1
  set "ABS=%%~fF"
  set "ABS_F=!ABS:\=/!"
  >>"%LIST%" echo file '!ABS_F!'
)

if %COUNT% EQU 0 (
  echo [ERROR] No se encontraron archivos que empiecen con "LRV_" en "%CUR%".
  pause
  exit /b 2
)

echo [INFO] %COUNT% archivos LRV_* detectados.
echo [DBG] Primeras lineas del filelist:
for /f "usebackq delims=" %%L in ("%LIST%") do (
  echo    %%L
  goto :shown1
)
:shown1
echo.

REM ---- Intento 1: concat demuxer con filelist ----
%FFMPEG% -hide_banner -loglevel info ^
  -f concat -safe 0 -i "%LIST%" ^
  -c:v libx264 -preset fast -crf 20 ^
  -c:a aac -b:a 128k -movflags +faststart ^
  "%OUT_FULL%"
set "ERR=%ERRORLEVEL%"

if "%ERR%"=="0" (
  echo.
  echo [OK] Generado con concat demuxer: "%OUT_FULL%"
  goto :END
)

echo [WARN] concat demuxer fallo (code %ERR%). Probando concat filter...

REM ---- Intento 2: concat filter (sin filelist) ----
set "ARGS="
set "IDX=0"

for /f "delims=" %%F in ('
  dir /b /a:-d /on LRV_*.mp4 LRV_*.MP4 LRV_*.lrv LRV_*.LRV 2^>nul
') do (
  set /a IDX+=1
  set "ABS=%%~fF"
  set "ARGS=!ARGS! -i "!ABS!""
)

REM Construir el filtro: concat=n=COUNT:v=1:a=1
set "FILTER=concat=n=%COUNT%:v=1:a=1"

%FFMPEG% -hide_banner -loglevel info ^
  %ARGS% ^
  -filter_complex "%FILTER%" ^
  -map "[v]" -map "[a]" ^
  -c:v libx264 -preset fast -crf 20 ^
  -c:a aac -b:a 128k -movflags +faststart ^
  "%OUT_FULL%"
set "ERR=%ERRORLEVEL%"

if not "%ERR%"=="0" (
  echo [ERROR] Fallo tambien el concat filter (code %ERR%).
  pause
  exit /b %ERR%
)

echo.
echo [OK] Generado con concat filter: "%OUT_FULL%"

:END
echo.
echo Listo.
if defined _DID_PUSHD popd
if "%1"=="/nopause" (exit /b 0)
pause
