@echo off
setlocal
set "ARG=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%~dp0Verificador_FilaUnica_FIX.ps1" -RootPath "%ARG%"
echo.
echo [BAT] Fin del script. Presiona una tecla para cerrar...
pause >nul
