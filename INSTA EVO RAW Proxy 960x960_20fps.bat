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

REM ================= LOG / AUX =================
set "LOG=%CD%\insta_proxy_log.txt"
if exist "%LOG%" del /q "%LOG%"
echo ===== RUN START ===== >"%LOG%"
echo PWD=%CD%>>"%LOG%"

set "FILELIST=filelist.txt"
set "MANIFEST=_concat_manifest.txt"
set "SIGN_FILE=_concat_sig.txt"

if exist "%FILELIST%" del /q "%FILELIST%"
if exist "%MANIFEST%" del /q "%MANIFEST%"

REM ================= FFMPEG ====================
set "FFMPEG=C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffmpeg.exe"
if not exist "%FFMPEG%" set "FFMPEG=ffmpeg"

"%FFMPEG%" -version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] ffmpeg no encontrado.
    echo [ERROR] ffmpeg no encontrado.>>"%LOG%"
    goto END
)
echo FFMPEG=%FFMPEG%>>"%LOG%"

REM ============ RUTAS SALIDA (DRV/TOP) =========
for /f "tokens=1,2 delims=\\" %%A in ("%CD%") do (
    set "DRV=%%A"
    set "TOP=%%B"
)

set "OUT_DIR=%DRV%\%TOP%"
set "OUT_FILE=%TOP% INSTA RAW PROXY Complete.mp4"
set "OUT_FULL=%OUT_DIR%\%OUT_FILE%"

set "TEMP_DIR=Proxy INSTA RAW"
set "OUT_LOCAL_DIR=%CD%\%TEMP_DIR%"
set "OUT_FINAL_LOCAL=%OUT_LOCAL_DIR%\%OUT_FILE%"

echo DRV=%DRV%>>"%LOG%"
echo TOP=%TOP%>>"%LOG%"
echo OUT_DIR=%OUT_DIR%>>"%LOG%"
echo OUT_FULL=%OUT_FULL%>>"%LOG%"
echo TEMP_DIR=%TEMP_DIR%>>"%LOG%"
echo OUT_LOCAL_DIR=%OUT_LOCAL_DIR%>>"%LOG%"
echo OUT_FINAL_LOCAL=%OUT_FINAL_LOCAL%>>"%LOG%"

if not exist "%TEMP_DIR%" mkdir "%TEMP_DIR%" >nul 2>&1
if not exist "%OUT_LOCAL_DIR%" mkdir "%OUT_LOCAL_DIR%" >nul 2>&1

REM ============ PERFIL LIGERO PROXY ============
set "V_FPS=15"
set "VF=scale=720:720:force_original_aspect_ratio=decrease,pad=720:720:(ow-iw)/2:(oh-ih)/2,fps=%V_FPS%"

set "V_CODEC=h264_nvenc"
set "V_PRESET=medium"
set "V_CQ=28"
set "V_BV=1200k"
set "V_MAX=1500k"

set "A_BR=32k"
set "A_AR=16000"
set "A_CH=1"

"%FFMPEG%" -hide_banner -v error -h encoder=%V_CODEC% >nul 2>&1
if errorlevel 1 (
    echo [AVISO] No NVENC, uso libx264
    echo No NVENC, uso libx264>>"%LOG%"
    set "V_CODEC=libx264"
) else (
    echo NVENC OK ^(%V_CODEC%^)>>"%LOG%"
)

echo Buscando *_00_*.insv ...
echo Buscando *_00_*.insv ...>>"%LOG%"

REM ====== LOOP: crear SOLO faltantes / reusar ======
set /a IDX=0
for %%F in (*_00_*.insv) do (
    set /a IDX+=1
    set "IN=%%~fF"
    set "OUT=%TEMP_DIR%\%%~nF.mp4"

    set "OUT_ABS=%CD%\!OUT!"
    set "OUT_UNIX=!OUT_ABS:\=/!"

    if exist "!OUT!" (
        echo [SKIP] %%~nxF  ^(ya existe !OUT!^)
        echo SKIP !OUT!>>"%LOG%"
    ) else (
        echo [NEW ] %%~nxF
        echo Procesando %%~fF ^> !OUT!>>"%LOG%"

        "%FFMPEG%" -y -hide_banner -loglevel warning -stats ^
            -i "!IN!" ^
            -vf "!VF!" ^
            -c:v !V_CODEC! -rc vbr_hq -cq !V_CQ! -b:v !V_BV! -maxrate !V_MAX! -bufsize !V_MAX! -pix_fmt yuv420p -preset !V_PRESET! ^
            -c:a aac -b:a !A_BR! -ar !A_AR! -ac !A_CH! ^
            "!OUT!"

        if errorlevel 1 (
            echo   [ERROR] ffmpeg fallo con %%~nxF
            echo ERROR FFMPEG %%~fF>>"%LOG%"
            set /a IDX-=1
        ) else (
            echo OK !OUT!>>"%LOG%"
        )
    )

    REM Agregar a listas solo si el proxy existe
    if exist "!OUT!" (
        >>"%FILELIST%" echo file '!OUT_UNIX!'
        for %%X in ("!OUT!") do (
            set "FSZ=%%~zX"
            set "FTS=%%~tX"
        )
        >>"%MANIFEST%" echo !FSZ!^|!FTS!^|!OUT_UNIX!
    )
)

if %IDX%==0 (
    echo [ERROR] No se genero/ubico ningun proxy. Revisa ffmpeg / archivos .insv.
    echo No se genero/ubico ningun proxy>>"%LOG%"
    goto END
)

REM ====== FIRMAR MANIFIESTO Y DECIDIR REBUILD ======
set "NEW_SIG="
for /f "tokens=* delims=" %%H in ('certutil -hashfile "%MANIFEST%" MD5 ^| findstr /r /b "[0-9A-F]"') do (
    set "NEW_SIG=%%H"
)
if not defined NEW_SIG (
    echo [ERROR] No se pudo calcular MD5 del manifiesto.
    echo Error MD5 manifiesto>>"%LOG%"
    goto END
)
set "NEW_SIG=%NEW_SIG: =%"

set "NEED_REBUILD=1"
if exist "%SIGN_FILE%" (
    set /p OLD_SIG=<"%SIGN_FILE%"
    set "OLD_SIG=%OLD_SIG: =%"
    if /I "%OLD_SIG%"=="%NEW_SIG%" (
        if exist "%OUT_FULL%" (
            set "NEED_REBUILD=0"
            echo [SKIP] Final sin cambios y ya existe en padre: "%OUT_FULL%"
            echo SKIP concat ^(firma igual, OUT_FULL existe^)>>"%LOG%"
        ) else if exist "%OUT_FINAL_LOCAL%" (
            echo [COPY] Firma igual; faltaba en padre. Copiando final local...
            copy /y "%OUT_FINAL_LOCAL%" "%OUT_FULL%" >nul
            if errorlevel 1 (
                echo [AVISO] No pude copiar al parent. El final sigue en:
                echo   "%OUT_FINAL_LOCAL%"
                echo COPY FAIL a OUT_FULL ^(firma igual^)>>"%LOG%"
            ) else (
                echo [OK] Copiado a:
                echo   "%OUT_FULL%"
                echo COPY OK a OUT_FULL ^(firma igual^)>>"%LOG%"
            )
            set "NEED_REBUILD=0"
        )
    )
)

REM ============== CONCATENAR (solo si cambia) ==============
if "%NEED_REBUILD%"=="1" (
    echo Uniendo %IDX% segmentos en "%OUT_FINAL_LOCAL%"...
    echo Concatenando %IDX% segmentos en %OUT_FINAL_LOCAL%>>"%LOG%"

    "%FFMPEG%" -y -hide_banner -loglevel warning -stats ^
        -f concat -safe 0 -i "%FILELIST%" -c copy "%OUT_FINAL_LOCAL%"
    if errorlevel 1 (
        echo [AVISO] Re-encode final local ^(copy fallo^)...
        echo concat copy fallo, intento recode local>>"%LOG%"
        "%FFMPEG%" -y -hide_banner -loglevel warning -stats ^
            -f concat -safe 0 -i "%FILELIST%" ^
            -c:v %V_CODEC% -rc vbr_hq -cq %V_CQ% -b:v %V_BV% -maxrate %V_MAX% -bufsize %V_MAX% -pix_fmt yuv420p -preset %V_PRESET% ^
            -c:a aac -b:a %A_BR% -ar %A_AR% -ac %A_CH% ^
            "%OUT_FINAL_LOCAL%"
        if errorlevel 1 (
            echo [ERROR] Fallo la concatenacion final.
            echo ERROR concat final>>"%LOG%"
            goto END
        )
    )

    >"%SIGN_FILE%" echo %NEW_SIG%

    echo Copiando final a carpeta padre...
    echo Copiando final a OUT_FULL >>"%LOG%"
    copy /y "%OUT_FINAL_LOCAL%" "%OUT_FULL%" >nul
    if errorlevel 1 (
        echo [AVISO] No pude copiar al parent. El final quedo aqui:
        echo   "%OUT_FINAL_LOCAL%"
        echo COPY FAIL a OUT_FULL>>"%LOG%"
    ) else (
        echo Final copiado en:
        echo   "%OUT_FULL%"
        echo COPY OK a OUT_FULL>>"%LOG%"
    )
)

echo.
echo LISTO:
echo   Proxies: "%TEMP_DIR%"
echo   Final local: "%OUT_FINAL_LOCAL%"
echo   Final padre: "%OUT_FULL%"
echo DONE>>"%LOG%"

:END
if defined _DID_PUSHD popd
endlocal
exit
