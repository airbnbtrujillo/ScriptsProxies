@echo off
setlocal EnableExtensions
REM IMPORTANTE: usar PUSHD en vez de CD, porque CD falla con rutas de red UNC \\servidor\carpeta
set "_DID_PUSHD="
pushd "%~dp0" || (
    echo [ERROR] No pude entrar a la carpeta del script: "%~dp0"
    echo [ERROR] Si esta en red, verifica permisos o mapea la ruta como unidad.
    endlocal
    exit /b 1
)
set "_DID_PUSHD=1"

REM Nombre del script PowerShell
set "PS1=Split-GIF-AutoByFolder.ps1"

REM Chequeo rÃ¡pido: Â¿existe el .ps1 antes de correrlo?
if not exist "%PS1%" (
    echo [ERROR] No se encontro "%PS1%" en esta carpeta.
    echo Esto suele pasar si ya se borro solo despues de una ejecucion exitosa.
    echo.
    pause
    exit /b 1
)

REM Ejecutar PowerShell y esperar que termine
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "PS_EXIT=%ERRORLEVEL%"

REM Si PowerShell devolvio error (cualquier codigo distinto de 0),
REM mostramos el error y NO nos autodestruimos.
if not "%PS_EXIT%"=="0" (
    echo.
    echo [ERROR] El script termino con codigo %PS_EXIT%.
    echo Revisa arriba el mensaje rojo/amarillo de PowerShell (ffmpeg, rutas, etc).
    echo.
    pause
    exit /b %PS_EXIT%
)

REM Si llegamos aqui: Exito.
REM OJO: el .ps1 probablemente ya se borro a si mismo.
REM Ahora este .bat se borra tambien y cerramos ventana.
if defined _DID_PUSHD popd
del "%~f0" >nul 2>&1
exit /b 0
