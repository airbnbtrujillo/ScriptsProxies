@echo off
setlocal
title TOOL-06 Organizar origenes - AUTOMATICO (mueve sin preguntar)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0TOOL-06-ORGANIZAR-ORIGENES.ps1" -Aplicar
echo.
echo [BAT] Fin. Presiona una tecla para cerrar...
pause >nul
