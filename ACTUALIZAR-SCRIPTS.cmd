@echo off
setlocal
pushd "%~dp0" || exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Update-Scripts.ps1" -Root "%~dp0" -Apply
set "RC=%ERRORLEVEL%"
echo.
pause
popd
exit /b %RC%
