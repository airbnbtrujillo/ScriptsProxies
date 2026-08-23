@echo off
setlocal EnableExtensions
chcp 65001>nul
pushd "%~dp0" || exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp000-SISTEMA\MENU-PRINCIPAL.ps1" -Root "%~dp0"
set "RC=%ERRORLEVEL%"
echo.
popd
exit /b %RC%
