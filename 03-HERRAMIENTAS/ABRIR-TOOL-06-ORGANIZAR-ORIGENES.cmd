@echo off
title Organizar origenes - vista previa y aplicacion
echo Esta ventana permanecera abierta. Escribe exit cuando quieras cerrarla.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0TOOL-06-VISTA-PREVIA.ps1"
