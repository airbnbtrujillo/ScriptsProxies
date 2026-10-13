@echo off
setlocal
title TOOL-06 Organizar origenes - SOLO ANALISIS (no mueve nada)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0TOOL-06-ORGANIZAR-ORIGENES.ps1"
echo.
echo [BAT] Fin del analisis. Presiona una tecla para cerrar...
pause >nul
