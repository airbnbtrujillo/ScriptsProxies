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
%FFMPEG% -hide_banner -v error -h encoder=%V_CODEC% >nul 2>&1 || set "V_CODEC=libx264"
call :LOG INFO "Encoder=%V_CODEC%"

:: ================== CONFIG ==================
if not exist "%PROXY_DIR%" mkdir "%PROXY_DIR%" >nul 2>&1
set "VF=crop=iw/2:ih:0:0,scale=960:960:force_original_aspect_ratio=decrease,pad=960:960:(ow-iw)/2:(oh-ih)/2,fps=30"
set "FILELIST=%ROOT%\_to_concat.txt"
set "OUT_FINAL=%PROJECT_DIR%\%PROJECT% TECHE RAW Proxy Complete.mp4"
set "QTYFILE=%PROJECT_DIR%\_concat_qty_teche.txt"
set "ASS=%ROOT%\overlay.ass"
set "PS_ASS=%ROOT%\_mk_overlay_ass.ps1"
set "SRT=%ROOT%\overlay.srt"
set "PS_SRT=%ROOT%\_mk_overlay_srt.ps1"
del /q "%FILELIST%" "%ASS%" "%PS_ASS%" "%SRT%" "%PS_SRT%" 2>nul

call :LOG INFO "OUT_FINAL=%OUT_FINAL%"

echo ==== TECHE (overlay + render por cantidad, con LOG) ====
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
        goto END
      )
    ) else (
      call :LOG WARN "No existe CAM-08-TECHE-CORREGIR-TIEMPO.ps1; usando modo compatible sin correccion"
      if not exist "!PROXY!" (
        call :LOG INFO "[ENCODE] !BASE! hacia !PROXY!"
        "%FFMPEG%" -y -hide_banner -loglevel warning -stats -analyzeduration 100M -probesize 100M ^
          -i "!INFILE!" -vf "%VF%" ^
          -c:v %V_CODEC% -cq 23 -b:v 2500k -maxrate 5000k -bufsize 5000k -pix_fmt yuv420p -preset slow ^
          -c:a aac -b:a 32k -ar 16000 -ac 1 "!PROXY!"
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
    "$rows = Get-ChildItem -LiteralPath '%PROXY_DIR%' -Filter '*.timesync.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $j = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json; [pscustomobject]@{ ClipID = $j.ClipId; MainArchivo = $j.MainFileName; ProxyArchivo = $j.ProxyFileName; Corregido = $j.Corrected; DesfaseSegundos = [math]::Round($j.DifferenceSeconds,3); DuracionPreview = [math]::Round($j.PreviewDuration,3); DuracionMain = [math]::Round($j.TargetDuration,3); Main = $(if($j.MainPath){$j.MainPath}else{$j.Reference8K}); Proxy = $(if($j.ProxyPath){$j.ProxyPath}else{$_.FullName -replace '\\.timesync\\.json$',''}); Preview = $j.Preview } }; if ($rows) { $rows | Sort-Object ClipID | Export-Csv -LiteralPath '%SYNC_REPORT%' -NoTypeInformation -Encoding UTF8; $rows | Sort-Object ClipID | Select-Object ClipID,MainArchivo,ProxyArchivo,Main,Proxy | Export-Csv -LiteralPath '%PROXY_MAP%' -NoTypeInformation -Encoding UTF8 }"
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

:: ================== OVERLAY (ASS con fallback SRT) ==================
set "SUFFIX_NOEXT=%PROXY_SUFFIX:.mp4=%"
call :write_ps_ass "%PS_ASS%"
if errorlevel 1 (call :LOG ERROR "No se pudo escribir %PS_ASS%" & goto TRY_SRT)

call :LOG INFO "Generando overlay.assâ€¦"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_ASS%" -ListPath "%FILELIST%" -AssPath "%ASS%" -FFProbe "%FFPROBE%" -Suffix "%SUFFIX_NOEXT%"
if errorlevel 1 (call :LOG ERROR "Powershell/ffprobe fallo creando ASS" & goto TRY_SRT)
if not exist "%ASS%" (call :LOG ERROR "overlay.ass no existe" & goto TRY_SRT)
set "SUBFILTER=subtitles='%ASS:\=\\%'"
set "SUBFILTER=%SUBFILTER::=\:%"
goto RENDER

:TRY_SRT
call :write_ps_srt "%PS_SRT%"
call :LOG INFO "Generando overlay.srt (fallback)â€¦"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SRT%" -ListPath "%FILELIST%" -SrtPath "%SRT%" -FFProbe "%FFPROBE%" -Suffix "%SUFFIX_NOEXT%"
if errorlevel 1 (call :LOG ERROR "Powershell/ffprobe fallo creando SRT" & goto END)
if not exist "%SRT%" (call :LOG ERROR "overlay.srt no existe" & goto END)
set "SUBFILTER=subtitles='%SRT:\=\\%':force_style=Alignment=8,MarginV=4,Fontsize=14,Outline=1,PrimaryColour=&H33FFFFFF,OutlineColour=&H66000000"
set "SUBFILTER=%SUBFILTER::=\:%"

:RENDER
call :LOG INFO "FFMPEG concat + overlayâ€¦"
call :LOG INFO "CMD: %FFMPEG% -y -f concat -safe 0 -i ""%FILELIST%"" -vf ""%SUBFILTER%"" -c:v %V_CODEC% ... ""%OUT_FINAL%"""
"%FFMPEG%" -y -hide_banner -loglevel warning -stats -f concat -safe 0 -i "%FILELIST%" ^
  -vf "%SUBFILTER%" ^
  -c:v %V_CODEC% -cq 23 -b:v 2500k -maxrate 5000k -bufsize 5000k -pix_fmt yuv420p -preset slow ^
  -c:a aac -b:a 96k -ar 48000 -ac 2 "%OUT_FINAL%"
if errorlevel 1 (call :LOG ERROR "FFMPEG fallo en render final" & goto END)

> "%QTYFILE%" echo %PROXY_COUNT%
call :LOG INFO "DONE: %OUT_FINAL%"
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

:write_ps_ass
REM ASS: top-center ~80%% opacidad; texto "N - Nombre"
> "%~1" echo param([string]$ListPath,[string]$AssPath,[string]$FFProbe,[string]$Suffix)
>>"%~1" echo $ErrorActionPreference='Stop'
>>"%~1" echo $acc=0.0; $idx=1
>>"%~1" echo $lines = @()
>>"%~1" echo $lines += "[Script Info]"
>>"%~1" echo $lines += "ScriptType: v4.00+"
>>"%~1" echo $lines += "PlayResX: 960"
>>"%~1" echo $lines += "PlayResY: 960"
>>"%~1" echo $lines += ""
>>"%~1" echo $lines += "[V4+ Styles]"
>>"%~1" echo $lines += "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
>>"%~1" echo $lines += "Style: Top,Arial,14,&H33FFFFFF,&H00FFFFFF,&H66000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,8,10,10,4,1"
>>"%~1" echo $lines += ""
>>"%~1" echo $lines += "[Events]"
>>"%~1" echo $lines += "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
>>"%~1" echo Get-Content -LiteralPath $ListPath ^| ForEach-Object {
>>"%~1" echo ^ if ($_ -match "^file '(.+)'$") {
>>"%~1" echo ^   $p = $Matches[1].Replace('/','\')
>>"%~1" echo ^   $label = [IO.Path]::GetFileNameWithoutExtension($p)
>>"%~1" echo ^   if ($Suffix) { $label = [regex]::Replace($label,[regex]::Escape($Suffix)+'$','') }
>>"%~1" echo ^   $dur = ^& $FFProbe -v error -show_entries format^=duration -of default^=noprint_wrappers^=1:nokey^=1 "$p"
>>"%~1" echo ^   if (-not $dur) { throw "ffprobe sin duracion para $p" }
>>"%~1" echo ^   $dur = [double]::Parse($dur,[Globalization.CultureInfo]::InvariantCulture)
>>"%~1" echo ^   $st  = [TimeSpan]::FromSeconds($acc)
>>"%~1" echo ^   $et  = [TimeSpan]::FromSeconds($acc + [Math]::Max($dur - 0.04, 0.01))
>>"%~1" echo ^   $stf = $st.ToString('hh\:mm\:ss\.ff')
>>"%~1" echo ^   $etf = $et.ToString('hh\:mm\:ss\.ff')
>>"%~1" echo ^   $safe = $label -replace "\\{","(" -replace "\\}"," )"
>>"%~1" echo ^   $safe = "$idx - $safe"
>>"%~1" echo ^   $lines += "Dialogue: 0,$stf,$etf,Top,,0000,0000,0000,,$safe"
>>"%~1" echo ^   $acc += $dur; $idx++
>>"%~1" echo ^ }
>>"%~1" echo }
>>"%~1" echo Set-Content -LiteralPath $AssPath -Value $lines -Encoding UTF8
exit /b

:write_ps_srt
REM SRT fallback (top-center por force_style en ffmpeg)
> "%~1" echo param([string]$ListPath,[string]$SrtPath,[string]$FFProbe,[string]$Suffix)
>>"%~1" echo $ErrorActionPreference='Stop'
>>"%~1" echo $acc=0.0; $idx=1
>>"%~1" echo Remove-Item -LiteralPath $SrtPath -Force -ErrorAction SilentlyContinue
>>"%~1" echo Get-Content -LiteralPath $ListPath ^| ForEach-Object {
>>"%~1" echo ^ if ($_ -match "^file '(.+)'$") {
>>"%~1" echo ^   $p = $Matches[1].Replace('/','\')
>>"%~1" echo ^   $label = [IO.Path]::GetFileNameWithoutExtension($p)
>>"%~1" echo ^   if ($Suffix) { $label = [regex]::Replace($label,[regex]::Escape($Suffix)+'$','') }
>>"%~1" echo ^   $dur = ^& $FFProbe -v error -show_entries format^=duration -of default^=noprint_wrappers^=1:nokey^=1 "$p"
>>"%~1" echo ^   $dur = [double]::Parse($dur,[Globalization.CultureInfo]::InvariantCulture)
>>"%~1" echo ^   $st  = [TimeSpan]::FromSeconds($acc)
>>"%~1" echo ^   $et  = [TimeSpan]::FromSeconds($acc + [Math]::Max($dur - 0.04, 0.01))
>>"%~1" echo ^   $stf = $st.ToString('hh\:mm\:ss\,fff'); $etf = $et.ToString('hh\:mm\:ss\,fff')
>>"%~1" echo ^   Add-Content -LiteralPath $SrtPath -Value $idx
>>"%~1" echo ^   Add-Content -LiteralPath $SrtPath -Value "$stf --> $etf"
>>"%~1" echo ^   Add-Content -LiteralPath $SrtPath -Value $label
>>"%~1" echo ^   Add-Content -LiteralPath $SrtPath -Value ""
>>"%~1" echo ^   $acc += $dur; $idx++
>>"%~1" echo ^ }
>>"%~1" echo }
exit /b

:LOG
set "LVL=%~1"
shift
set "MSG=%*"
echo [!TIME:~0,8!] [%LVL%] %MSG%
>>"%LOG%" echo [!TIME:~0,8!] [%LVL%] %MSG%
exit /b

:END
call :LOG INFO "==== RUN END ===="
if defined _DID_PUSHD popd
endlocal
exit /b


