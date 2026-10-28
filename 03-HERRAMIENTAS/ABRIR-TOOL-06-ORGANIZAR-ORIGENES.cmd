@echo off
title Organizar origenes - vista previa y aplicacion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0TOOL-06-VISTA-PREVIA.ps1"
echo.
echo Pulsa una tecla para cerrar esta ventana.
pause >nul
