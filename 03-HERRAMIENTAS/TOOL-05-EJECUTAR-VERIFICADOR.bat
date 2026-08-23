@echo off
setlocal
set "ARG=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%~dp0TOOL-05-VERIFICAR-FILA-UNICA.ps1" -RootPath "%ARG%"
echo.
echo [BAT] Fin del script. Presiona una tecla para cerrar...
pause >nul
