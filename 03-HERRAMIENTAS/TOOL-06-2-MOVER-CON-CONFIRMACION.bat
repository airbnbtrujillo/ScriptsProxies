@echo off
setlocal
title TOOL-06 Organizar origenes - MOVER (pregunta antes)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0TOOL-06-ORGANIZAR-ORIGENES.ps1" -Confirmar
echo.
echo [BAT] Fin. Presiona una tecla para cerrar...
pause >nul
