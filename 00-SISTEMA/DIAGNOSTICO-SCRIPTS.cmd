@echo off
setlocal
set "ROOT=%~dp0..\"
pushd "%ROOT%" || exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\Test-Scripts.ps1" -Root "%ROOT%"
set "RC=%ERRORLEVEL%"
echo.
if %RC% GEQ 2 echo Hay errores criticos. Revisa el reporte mostrado arriba.
if %RC% EQU 1 echo Diagnostico correcto con advertencias.
if %RC% EQU 0 echo Todo correcto.
pause
popd
exit /b %RC%
