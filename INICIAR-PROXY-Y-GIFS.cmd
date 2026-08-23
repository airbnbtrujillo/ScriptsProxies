@echo off
setlocal
pushd "%~dp0" || exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PROXY y GIFS.ps1"
set "RC=%ERRORLEVEL%"
echo.
pause
popd
exit /b %RC%
