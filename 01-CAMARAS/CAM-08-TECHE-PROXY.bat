@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001>nul

:: ================== RUTAS BASE ==================
:: IMPORTANTE: usar PUSHD en vez de CD, porque CD falla con rutas de red UNC \\servidor\carpeta
set "_DID_PUSHD="
pushd "%~dp0" || (
  echo([ERROR] No pude entrar a la carpeta del script: "%~dp0"
  echo([ERROR] Si esta en red, verifica permisos o mapea la ruta como unidad.
  endlocal
  exit /b 1
)
set "_DID_PUSHD=1"
set "RUN_FAILED=0"
set "ROOT=%CD%"
for %%I in ("%ROOT%\..") do set "PROJECT_DIR=%%~fI"
for %%I in ("%PROJECT_DIR%") do set "PROJECT=%%~nxI"

set "SUBPAT=VIDEO_TECHE_*"
set "PROXY_DIR=%ROOT%\Proxy TECHE RAW"
set "TEMP_DIR=%ROOT%\_temp_proxies"
set "CANONICAL_SUFFIX=__TecheMain_proxy.mp4"
set "LEGACY_SUFFIX= TECHEProxy.mp4"
set "PROXY_SUFFIX=%CANONICAL_SUFFIX%"
set "PS_SYNC=%ROOT%\CAM-08-TECHE-CORREGIR-TIEMPO.ps1"
set "SYNC_REPORT=%PROJECT_DIR%\TECHE TimeSync Report.csv"
set "PROXY_MAP=%PROJECT_DIR%\TECHE Main-Proxy Map.csv"

:: ================== LOG ==================
set "LOG=%PROJECT_DIR%\_teche_debug.log"
del /q "%LOG%" 2>nul
call :LOG INFO "==== RUN START ===="
call :LOG INFO "ROOT=%ROOT%"
call :LOG INFO "PROJECT_DIR=%PROJECT_DIR%"
call :LOG INFO "PROJECT=%PROJECT%"
call :LOG INFO "PROXY_DIR=%PROXY_DIR%"

:: Guardia anti-error: si por cualquier razon seguimos en C:\Windows, detenerse
if /I "%ROOT%"=="C:\Windows" (
  call :LOG ERROR "ROOT resolvio a C:\Windows. Eso indica que no se entro a la carpeta real del proyecto."
  call :LOG ERROR "Ruta actual: %CD%"
  goto END
)

:: ================== TOOLS ==================
set "FFMPEG=ffmpeg"
%FFMPEG% -version >nul 2>&1 || if exist "C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffmpeg.exe" set "FFMPEG=C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffmpeg.exe"
%FFMPEG% -version >nul 2>&1 || (call :LOG ERROR "ffmpeg no encontrado" & goto END)

set "FFPROBE=ffprobe"
%FFPROBE% -version >nul 2>&1 || if exist "C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffprobe.exe" set "FFPROBE=C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffprobe.exe"
%FFPROBE% -version >nul 2>&1 || (call :LOG ERROR "ffprobe no encontrado" & goto END)

set "V_CODEC=h264_nvenc"
%FFMPEG% -hide_banner -v error -f lavfi -i "color=size=256x256:rate=1:duration=0.1" -frames:v 1 -c:v h264_nvenc -f null NUL >nul 2>&1
if errorlevel 1 (
  set "V_CODEC=libx264"
  set "V_ARGS=-c:v libx264 -crf 28 -preset ultrafast -tune fastdecode"
) else (
  set "V_ARGS=-c:v h264_nvenc -cq 28 -b:v 0 -preset p1"
)
call :LOG INFO "Encoder=%V_CODEC%"

:: ================== CONFIG ==================
if not exist "%PROXY_DIR%" mkdir "%PROXY_DIR%" >nul 2>&1
set "FILELIST=%ROOT%\_to_concat.txt"
set "OUT_FINAL=%PROJECT_DIR%\%PROJECT% TECHE RAW Proxy Complete.mp4"
set "OUT_PARTIAL=%OUT_FINAL%.partial.mp4"
set "QTYFILE=%PROJECT_DIR%\_concat_qty_teche.txt"
del /q "%FILELIST%" 2>nul

call :LOG INFO "OUT_FINAL=%OUT_FINAL%"

echo ==== TECHE (preview rapido + ajuste de duracion, con LOG) ====
echo OUT FINAL: %OUT_FINAL%
echo LOG      : %LOG%
echo.

:: ================== PROXIES & ORIGINALES VÃLIDOS ==================
set /a SRC_VALID=0
set /a PROXY_COUNT=0
set "PROXY_UPDATED=0"
for /f "delims=" %%D in ('dir /b /ad "%SUBPAT%" 2^>nul ^| sort') do (
  set "DIR=%ROOT%\%%D"
  set "BASE=%%D"
  call :LOG INFO "[DIR] %%D"
  set "INFILE="
  call :find_techeprev "!DIR!" INFILE
  if defined INFILE (
    set /a SRC_VALID+=1
    set "PROXY_CANONICAL=%PROXY_DIR%\!BASE!%CANONICAL_SUFFIX%"
    set "PROXY_LEGACY=%PROXY_DIR%\!BASE!%LEGACY_SUFFIX%"
    set "PROXY=!PROXY_CANONICAL!"
    if not exist "!PROXY_CANONICAL!" if exist "!PROXY_LEGACY!" (
      set "PROXY=!PROXY_LEGACY!"
      call :LOG INFO "[LEGACY] Se conserva el proxy existente: !PROXY_LEGACY!"
    )
    if exist "%PS_SYNC%" (
      call :LOG INFO "[SYNC] Analizando !BASE! sin decodificar el video 8K"
      powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SYNC%" ^
        -Folder "!DIR!" -Preview "!INFILE!" -Output "!PROXY!" -FFmpeg "%FFMPEG%" -FFprobe "%FFPROBE%"
      set "SYNC_RC=!ERRORLEVEL!"
      if "!SYNC_RC!"=="10" set "PROXY_UPDATED=1"
      if not "!SYNC_RC!"=="0" if not "!SYNC_RC!"=="10" (
        call :LOG ERROR "Correccion temporal fallo para !BASE! (codigo !SYNC_RC!)"
        call :LOG ERROR "Detalle persistente: !PROXY!.timesync-error.log"
      )
    ) else (
      call :LOG WARN "No existe CAM-08-TECHE-CORREGIR-TIEMPO.ps1; usando modo compatible sin correccion"
      if not exist "!PROXY!" (
        call :LOG INFO "[ENCODE] !BASE! hacia !PROXY!"
        "%FFMPEG%" -y -hide_banner -loglevel warning -stats -i "!INFILE!" ^
          -map 0:v:0 -map 0:a? -c copy -movflags +faststart "!PROXY!"
        if errorlevel 1 (call :LOG ERROR "ffmpeg fallo creando proxy: !PROXY!" & goto END)
        set "PROXY_UPDATED=1"
      ) else (
        call :LOG INFO "[KEEP] !BASE! (proxy existe)"
      )
    )
    if exist "!PROXY!" (
      set "P=!PROXY:\=/!"
      >>"%FILELIST%" echo file '!P!'
      set /a PROXY_COUNT+=1
    )
  ) else (
    call :LOG WARN "Sin *TechePrev* en: !DIR! (no cuenta)"
  )
)

if exist "%PS_SYNC%" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$rows = Get-ChildItem -LiteralPath '%PROXY_DIR%' -Filter '*.timesync.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $j = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json; [pscustomobject]@{ ClipID = $j.ClipId; MainArchivo = $j.MainFileName; ProxyArchivo = $j.ProxyFileName; Modo = $j.CorrectionMode; NegroFinalSegundos = [math]::Round([double]$j.PaddingEndSeconds,3); Corregido = $j.Corrected; DesfaseSegundos = [math]::Round($j.DifferenceSeconds,3); DuracionPreview = [math]::Round($j.PreviewDuration,3); DuracionMain = [math]::Round($j.TargetDuration,3); Main = $(if($j.MainPath){$j.MainPath}else{$j.Reference8K}); Proxy = $(if($j.ProxyPath){$j.ProxyPath}else{$_.FullName -replace '\\.timesync\\.json$',''}); Preview = $j.Preview } }; if ($rows) { $rows | Sort-Object ClipID | Export-Csv -LiteralPath '%SYNC_REPORT%' -NoTypeInformation -Encoding UTF8; $rows | Sort-Object ClipID | Select-Object ClipID,MainArchivo,ProxyArchivo,Main,Proxy | Export-Csv -LiteralPath '%PROXY_MAP%' -NoTypeInformation -Encoding UTF8 }"
  if exist "%SYNC_REPORT%" call :LOG INFO "Reporte temporal: %SYNC_REPORT%"
  if exist "%PROXY_MAP%" call :LOG INFO "Mapa Main-Proxy: %PROXY_MAP%"
)

:: ================== FILELIST ==================
if %PROXY_COUNT% EQU 0 if exist "%TEMP_DIR%" (
  for /f "delims=" %%P in ('dir /b /a-d "%TEMP_DIR%\clip_temp_*.mp4" 2^>nul ^| sort') do (
    set "ABS=%TEMP_DIR%\%%P"
    set "P=!ABS:\=/!"
    >>"%FILELIST%" echo file '!P!'
    set /a PROXY_COUNT+=1
  )
  if %PROXY_COUNT% GTR 0 (call :LOG INFO "Usando _temp_proxies")
)
if %PROXY_COUNT% EQU 0 (
  call :LOG ERROR "No hay proxies para concatenar"
  goto END
)
call :LOG INFO "SRC_VALID=%SRC_VALID%  PROXY_COUNT=%PROXY_COUNT%"

:: ================== VALIDAR CANTIDADES ==================
if %PROXY_COUNT% NEQ %SRC_VALID% (
  call :LOG WARN "Cantidades distintas (VALIDOS=%SRC_VALID% vs PROXIES=%PROXY_COUNT%). No se crea final."
  goto END
)

:: ================== DECISIÃ“N DE RENDER ==================
set "DO_RENDER=0"
if not exist "%OUT_FINAL%" (
  call :LOG INFO "OUT_FINAL no existe; se renderiza."
  set "DO_RENDER=1"
) else (
  set "LAST_QTY="
  if exist "%QTYFILE%" set /p LAST_QTY=<"%QTYFILE%"
  if not defined LAST_QTY set "LAST_QTY=0"
  call :LOG INFO "LAST_QTY=!LAST_QTY!  CUR_QTY=!PROXY_COUNT!"
  if "!PROXY_UPDATED!"=="1" (
    call :LOG INFO "Uno o mas proxies cambiaron; se renderiza."
    set "DO_RENDER=1"
  ) else if "!PROXY_COUNT!" NEQ "!LAST_QTY!" (
    call :LOG INFO "Cambio de cantidad; se renderiza."
    set "DO_RENDER=1"
  ) else (
    call :LOG INFO "Cantidad igual y final existente; no se renderiza."
  )
)

if "%DO_RENDER%"=="0" goto END

:: ================== CONCAT RAPIDO SIN RECODIFICAR ==================
:: Cada proxy individual ya tiene la duracion del TecheMain. Unir por copia
:: evita volver a renderizar horas de video solamente para colocar un rotulo.
del /q "%OUT_PARTIAL%" 2>nul
call :LOG INFO "FFMPEG concat rapido por stream copy..."
"%FFMPEG%" -y -hide_banner -loglevel warning -stats -f concat -safe 0 -i "%FILELIST%" ^
  -map 0:v:0 -map 0:a? -c copy -movflags +faststart "%OUT_PARTIAL%"
if errorlevel 1 (
  call :LOG WARN "Concat directo fallo; usando codificacion rapida de compatibilidad."
  del /q "%OUT_PARTIAL%" 2>nul
  "%FFMPEG%" -y -hide_banner -loglevel warning -stats -f concat -safe 0 -i "%FILELIST%" ^
    %V_ARGS% -pix_fmt yuv420p -c:a aac -b:a 96k "%OUT_PARTIAL%"
)
if not exist "%OUT_PARTIAL%" (call :LOG ERROR "No se pudo crear el final TECHE" & goto END)
move /y "%OUT_PARTIAL%" "%OUT_FINAL%" >nul
if errorlevel 1 (call :LOG ERROR "No se pudo instalar el final TECHE" & goto END)
> "%QTYFILE%" echo %PROXY_COUNT%
call :LOG INFO "DONE RAPIDO: %OUT_FINAL%"
goto END

:: ================== SUBRUTINAS ==================
:find_techeprev
set "%~2="
for %%E in (mp4 mov mkv m4v avi) do (
  for /f "delims=" %%F in ('dir /b /a-d /o:-s "%~1\*TechePrev*.%%E" 2^>nul') do (
    set "%~2=%~1\%%F"
    goto :EOF
  )
)
goto :EOF

:LOG
set "LVL=%~1"
if /I "%LVL%"=="ERROR" set "RUN_FAILED=1"
shift
set "MSG=%*"
echo [!TIME:~0,8!] [%LVL%] %MSG%
>>"%LOG%" echo [!TIME:~0,8!] [%LVL%] %MSG%
exit /b

:END
call :LOG INFO "==== RUN END ===="
if defined _DID_PUSHD popd
endlocal & exit /b %RUN_FAILED%


