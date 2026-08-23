@echo off
setlocal EnableExtensions
REM Lanza el extractor de candidatos de thumbnail usando proxies.
REM Si lo ejecutas desde I:\Resources\Scripts, te pedira la carpeta del proyecto.

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%TOOL-01-EXTRAER-MINIATURAS.ps1"
set "ROOT=%~1"

if not exist "%PS1%" (
    echo [ERROR] No se encontro "%PS1%".
    pause
    exit /b 1
)

if "%ROOT%"=="" (
    echo.
    echo Pega la ruta de la carpeta raiz del proyecto.
    echo Ejemplo: \\Desktop-7o70mnp\8\218 - Rhiana Nkd
    echo.
    set /p "ROOT=Ruta del proyecto: "
)

if "%ROOT%"=="" (
    echo [ERROR] No se ingreso ruta.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Root "%ROOT%"
set "PS_EXIT=%ERRORLEVEL%"

echo.
if not "%PS_EXIT%"=="0" (
    echo [ERROR] Termino con codigo %PS_EXIT%.
) else (
    echo [OK] Revisa la carpeta Thumbnail_candidates dentro del proyecto.
)
pause
exit /b %PS_EXIT%
