@echo off
setlocal
set "ROOT=%~dp0..\"
pushd "%ROOT%" || exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\Update-Scripts.ps1" -Root "%ROOT%" -Apply
set "RC=%ERRORLEVEL%"
echo.
pause
popd
exit /b %RC%
