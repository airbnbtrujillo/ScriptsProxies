@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001>nul
REM IMPORTANTE: usar PUSHD en vez de CD, porque CD falla con rutas de red UNC \\servidor\carpeta
set "_DID_PUSHD="
pushd "%~dp0" || (
  echo([ERROR] No pude entrar a la carpeta del script: "%~dp0"
  echo([ERROR] Si esta en red, verifica permisos o mapea la ruta como unidad.
  endlocal
  exit /b 1
)
set "_DID_PUSHD=1"

REM ================== CONFIG (GEAR 360) ==================
set "TEMP_DIR=Proxy GEAR 360 RAW"
set "PROXY_SUFFIX= Gear360Proxy.mp4"
set "DIM_EXPECT=1024x576" REM verificaciÃ³n de resoluciÃ³n del proxy
set "TOL_SEC=5"           REM tolerancia de duraciÃ³n (seg)
set "CHECK_DIM=1"         REM 1=verificar DIM_EXPECT leyendo ffmpeg -i
set "V_FPS=30"            REM fps deseado para los proxies
set "STRICT_COUNT=0"      REM 1=exige PROXY_COUNT==TOTAL; 0=permite concat si falta el final

REM --- ffmpeg / ffprobe ---
set "FFMPEG=ffmpeg"
%FFMPEG% -version >nul 2>&1 || if exist "C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffmpeg.exe" set "FFMPEG=C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffmpeg.exe"
%FFMPEG% -version >nul 2>&1 || (echo [ERROR] No se encontro ffmpeg.& exit /b 2)

set "FFPROBE=ffprobe"
%FFPROBE% -version >nul 2>&1 || if exist "C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffprobe.exe" set "FFPROBE=C:\ffmpeg\ffmpeg-8.0-full_build\bin\ffprobe.exe"
%FFPROBE% -version >nul 2>&1 || (echo [ERROR] No se encontro ffprobe.& exit /b 2)

REM --- params encode ---
set "V_CODEC=h264_nvenc"
%FFMPEG% -hide_banner -v error -h encoder=%V_CODEC% >nul 2>&1 || set "V_CODEC=libx264"
set "V_PRESET=slow"
set "V_CQ=23"
set "V_BV=600k"
set "V_MAX=900k"
set "A_BR=32k"
set "A_AR=16000"
set "A_CH=1"
set "VF=scale=1024:576:force_original_aspect_ratio=decrease,pad=1024:576:(ow-iw)/2:(oh-ih)/2,fps=%V_FPS%"

REM --- OUT = CARPETA PADRE DEL SCRIPT ---
for %%I in ("%CD%\..") do (
  set "OUT_DIR=%%~fI"
  set "PROJECT=%%~nxI"
)
if not defined OUT_DIR echo [ERROR] No se pudo resolver carpeta padre.& exit /b 2
if not defined PROJECT echo [ERROR] No se pudo resolver nombre de proyecto.& exit /b 2

set "OUT_FILE=%PROJECT% GEAR 360 RAW PROXY Complete.mp4"
set "OUT_FULL=%OUT_DIR%\%OUT_FILE%"
set "SIG_FILE=%OUT_DIR%\_concat_sig_gear360.txt"
set "STATUS_LOG=%OUT_DIR%\_keeper_status_gear360.txt"
set "FFMPEG_LOG=%OUT_DIR%\_concat_lastlog_gear360.txt"

REM --- Archivos de overlay ---
set "ASS=overlay.ass"
set "PS_ASS=_mk_overlay_ass.ps1"
set "SUFFIX_NOEXT=%PROXY_SUFFIX:.mp4=%"

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%" >nul 2>&1
if exist "%STATUS_LOG%" del /q "%STATUS_LOG%" >nul 2>&1

call :LOG "==== GEAR360 Proxy Keeper (overlay N - NombreDelClip) ===="
call :LOG "[DBG] OUT_DIR=\"%OUT_DIR%\""
call :LOG "[DBG] OUT_FULL=\"%OUT_FULL%\""
if exist "%OUT_FULL%" (call :LOG "[DBG] Final existe: SI") else (call :LOG "[DBG] Final existe: NO")

if not exist "%TEMP_DIR%" mkdir "%TEMP_DIR%"

REM ================== PASO 1: PROCESAR ORIGINALES ==================
if exist "filelist.txt" del /q "filelist.txt"
set /a TOTAL=0
set /a OK=0
set /a CREATED=0
set /a REUSED=0

for %%F in (*.mp4) do (
  set "FN=%%~nxF"
  set "CHK=!FN:%PROXY_SUFFIX%=!"
  if /I "!CHK!"=="!FN!" (
    set /a TOTAL+=1
    call :ONE "%%~fF" "%%~nF"
  )
)

call :LOG "==== RESUMEN ===="
call :LOG "Originales: %TOTAL%"
call :LOG "Proxies OK: %OK%   (Reusados:%REUSED%  Nuevos:%CREATED%)"

REM ================== PASO 2: RECONSTRUIR FILELIST (si hiciera falta) ==================
set "PROXY_COUNT=0"
if exist "filelist.txt" for /f %%# in ('find /v /c "" ^< "filelist.txt"') do set "PROXY_COUNT=%%#"
if %PROXY_COUNT% LSS %OK% (
  call :LOG "[FIX] Reconstruyendo filelist desde los originales..."
  if exist "filelist.txt" del /q "filelist.txt"
  for %%F in (*.mp4) do (
    set "FN=%%~nxF"
    set "CHK=!FN:%PROXY_SUFFIX%=!"
    if /I "!CHK!"=="!FN!" (
      set "BASE=%%~nF"
      set "P=%TEMP_DIR%\!BASE!%PROXY_SUFFIX%"
      if exist "!P!" call :ADD_TO_LIST "!P!"
    )
  )
  set "PROXY_COUNT=0"
  if exist "filelist.txt" for /f %%# in ('find /v /c "" ^< "filelist.txt"') do set "PROXY_COUNT=%%#"
)
call :LOG "[INFO] filelist: %PROXY_COUNT% entradas"

if %PROXY_COUNT% EQU 0 (
  call :LOG "[ERROR] No hay proxies listados. Nada que concatenar."
  goto :END
)

REM ================== PASO 3: FIRMAR SET DE PROXIES ==================
set "_SIGSRC=%TEMP%\sigsrc_%RANDOM%%RANDOM%.txt"
if exist "%_SIGSRC%" del /q "%_SIGSRC%"
for %%F in (*.mp4) do (
  set "FN=%%~nxF"
  set "CHK=!FN:%PROXY_SUFFIX%=!"
  if /I "!CHK!"=="!FN!" (
    set "BASE=%%~nF"
    set "P=%TEMP_DIR%\!BASE!%PROXY_SUFFIX%"
    for %%Z in ("!P!") do if exist "%%~fZ" >>"%_SIGSRC%" echo %%~zZ;%%~tZ;!BASE!
  )
)
call :MD5 "%_SIGSRC%" NEW_SIG
if exist "%_SIGSRC%" del /q "%_SIGSRC%"
set "OLD_SIG="
if exist "%SIG_FILE%" set /p OLD_SIG=<"%SIG_FILE%"
call :LOG "[DBG] NEW_SIG=%NEW_SIG%"
call :LOG "[DBG] OLD_SIG=%OLD_SIG%"

REM ================== PASO 4: DECIDIR ==================
set "NEED_CONCAT=0"
set "REASON="

if not exist "%OUT_FULL%" (
  if %PROXY_COUNT% GTR 0 (
    set "NEED_CONCAT=1"
    set "REASON=missing_output"
  ) else (
    call :LOG "[ERROR] filelist vacia: 0 entradas. Nada que concatenar."
    goto :END
  )
) else (
  if not "%NEW_SIG%"=="%OLD_SIG%" (
    set "NEED_CONCAT=1"
    set "REASON=sig_changed"
  )
)

set "COUNT_OK=1"
if %PROXY_COUNT% NEQ %TOTAL% (
  call :LOG "[WARN] Conteo inconsistente: proxies=%PROXY_COUNT% vs originales=%TOTAL%."
  if "%STRICT_COUNT%"=="1" (
    call :LOG "[WARN] STRICT_COUNT=1 -> no concateno."
    set "COUNT_OK=0"
  ) else (
    if exist "%OUT_FULL%" (
      call :LOG "[WARN] Final existe y conteo desigual -> no concateno (seguro)."
      set "COUNT_OK=0"
    ) else (
      call :LOG "[WARN] Final NO existe -> concatenare igual con lo disponible."
      set "COUNT_OK=1"
    )
  )
)

call :LOG "[DBG] NEED_CONCAT=%NEED_CONCAT%  REASON=%REASON%  COUNT_OK=%COUNT_OK%"

if "%COUNT_OK%"=="0" goto :END
if "%NEED_CONCAT%"=="0" (
  call :LOG "[INFO] Sin cambios y final existe. Skip concat."
  goto :END
)

call :LOG "[INFO] Concat trigger: %REASON%"
call :LOG "[INFO] Log ffmpeg: \"%FFMPEG_LOG%\""
if exist "%FFMPEG_LOG%" del /q "%FFMPEG_LOG%" >nul 2>&1

REM ================== PASO 5: CREAR OVERLAY (ASS con N - Nombre) ==================
call :MAKE_ASS "%PS_ASS%" || (call :LOG "[ERROR] No se pudo escribir %PS_ASS%" & goto :END)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_ASS%" -ListPath "filelist.txt" -AssPath "%ASS%" -FFProbe "%FFPROBE%" -Suffix "%SUFFIX_NOEXT%"
if errorlevel 1 (call :LOG "[ERROR] Powershell/ffprobe fallo creando ASS" & goto :END)
if not exist "%ASS%" (call :LOG "[ERROR] overlay.ass no existe" & goto :END)

set "SUBFILTER=subtitles='%ASS:\=\\%'"
set "SUBFILTER=%SUBFILTER::=\:%"

REM ================== PASO 6: CONCAT + OVERLAY (re-encode SIEMPRE) ==================
%FFMPEG% -y -hide_banner -loglevel warning -stats -f concat -safe 0 -i "filelist.txt" ^
  -vf "%SUBFILTER%" ^
  -c:v %V_CODEC% -rc vbr_hq -cq %V_CQ% -b:v %V_BV% -maxrate %V_MAX% -bufsize %V_MAX% -pix_fmt yuv420p -preset %V_PRESET% ^
  -c:a aac -b:a %A_BR% -ar %A_AR% -ac %A_CH% "%OUT_FULL%" >"%FFMPEG_LOG%" 2>&1
if errorlevel 1 (
  call :LOG "[ERROR] ffmpeg fallo, ver \"%FFMPEG_LOG%\"."
  goto :END
)

echo %NEW_SIG%>"%SIG_FILE%"
call :LOG "==== LISTO ==== \"%OUT_FULL%\""
goto :END


:: ================== SUBRUTINAS ==================
:LOG
echo %~1
>>"%STATUS_LOG%" echo %~1
goto :EOF

:ONE
REM %1=originalAbs  %2=base
set "IN=%~1"
set "BASE=%~2"
set "PX=%TEMP_DIR%\%BASE%%PROXY_SUFFIX%"
call :LOG "[PROC] \"%BASE%\""

REM --- fast keep: si ya existe el canÃ³nico, Ãºsalo y listo ---
if exist "%PX%" (
  call :LOG "       [KEEP] ya existe canonico â†’ skip"
  call :ADD_TO_LIST "%PX%"
  set /a OK+=1
  set /a REUSED+=1
  goto :EOF
)

REM --- validar/adoptar ---
call :VALID "%IN%" "%PX%" OKPX
if /I "!OKPX!"=="1" (
  call :LOG "       [SKIP] proxy OK"
  call :ADD_TO_LIST "%PX%"
  set /a OK+=1
  set /a REUSED+=1
  goto :EOF
)

set "ADOPT="
for %%C in ("%TEMP_DIR%\*.mp4") do (
  if /I not "%%~fC"=="%PX%" (
    set "NAME=%%~nxC"
    set "TMP=!NAME:%BASE%=!"
    if not "!TMP!"=="!NAME!" (
      call :VALID "%IN%" "%%~fC" OKC
      if /I "!OKC!"=="1" (move /y "%%~fC" "%PX%" >nul & set "ADOPT=1" & goto :AFTER_ADOPT)
    )
  )
)
if not defined ADOPT (
  set "BEST=" & set "BESTD=999999"
  call :DUR "%IN%" SO
  for %%C in ("%TEMP_DIR%\*.mp4") do (
    if /I not "%%~fC"=="%PX%" (
      call :DUR "%%~fC" SC
      if defined SC if defined SO (
        call :ABS "|!SO!|!SC!" D
        if defined D if !D! LSS !BESTD! (set "BESTD=!D!" & set "BEST=%%~fC")
      )
    )
  )
  if defined BEST if !BESTD! LEQ %TOL_SEC% (
    call :VALID "%IN%" "!BEST!" OKB
    if /I "!OKB!"=="1" move /y "!BEST!" "%PX%" >nul & set "ADOPT=1"
  )
)
:AFTER_ADOPT
if defined ADOPT (
  call :LOG "       [ADOPT] renombrado a canonico"
  call :ADD_TO_LIST "%PX%"
  set /a OK+=1
  set /a REUSED+=1
  goto :EOF
)

REM --- crear ---
call :LOG "       [ENCODE] creando proxy..."
%FFMPEG% -y -hide_banner -loglevel warning -stats -analyzeduration 100M -probesize 100M ^
  -i "%IN%" -vf "%VF%" ^
  -c:v %V_CODEC% -rc vbr_hq -cq %V_CQ% -b:v %V_BV% -maxrate %V_MAX% -bufsize %V_MAX% -pix_fmt yuv420p -preset %V_PRESET% ^
  -c:a aac -b:a %A_BR% -ar %A_AR% -ac %A_CH% "%PX%"
if errorlevel 1 (call :LOG "       [ERROR] fallo encode: \"%~nx1\"" & goto :EOF)
call :ADD_TO_LIST "%PX%"
set /a OK+=1
set /a CREATED+=1
goto :EOF


:VALID
REM %1=orig %2=proxy -> %3=1 si valido (duracion Â±TOL y resolucion DIM_EXPECT opcional)
set "%~3=0"
if not exist "%~2" goto :EOF
call :DUR "%~1" S1
call :DUR "%~2" S2
if not defined S1 goto :EOF
if not defined S2 goto :EOF
call :ABS "|!S1!|!S2!" D
if not defined D goto :EOF
if !D! GTR %TOL_SEC% goto :EOF
if %CHECK_DIM%==1 call :HAS_DIM "%~2" DOK & if /I not "!DOK!"=="1" goto :EOF
set "%~3=1"
goto :EOF


:ADD_TO_LIST
set "ABS=%CD%\%~1"
setlocal EnableDelayedExpansion
set "ABS_UNIX=!ABS:\=/!"
>>"filelist.txt" echo file '!ABS_UNIX!'
endlocal & goto :EOF


:DUR
REM segundos enteros, evitando octal (08/09)
set "%~2="
set "_T=%TEMP%\ffinf_%RANDOM%%RANDOM%.txt"
"%FFMPEG%" -hide_banner -i "%~1" 1>nul 2>"%_T%"
set "_DL="
for /f "usebackq delims=" %%L in ("%_T%") do (
  set "L=%%L"
  if not "!L:Duration:=!"=="!L!" if not defined _DL set "_DL=!L!"
)
if defined _DL (
  set "D=!_DL:*Duration: =!"
  for /f "tokens=1 delims=," %%A in ("!D!") do set "D=%%A"
  for /f "tokens=1-3 delims=:" %%H in ("!D!") do (set "H=%%H" & set "M=%%I" & set "SX=%%J")
  for /f "tokens=1 delims=." %%S in ("!SX!") do set "S=%%S"
  if defined H if defined M if defined S (
    set /a _H=1%H%-100 & set /a _M=1%M%-100 & set /a _S=1%S%-100
    if !_H! LSS 0 set /a _H=0
    if !_M! LSS 0 set /a _M=0
    if !_S! LSS 0 set /a _S=0
    set /a _SEC=_H*3600 + _M*60 + _S
    set "%~2=!_SEC!"
  )
)
del /q "%_T%" >nul 2>&1
set "_DL=" & set "L=" & set "D=" & set "SX=" & set "H=" & set "M=" & set "S=" & set "_SEC=" & set "_H=" & set "_M=" & set "_S="
goto :EOF


:HAS_DIM
REM %1=path %2=ret -> 1 si aparece DIM_EXPECT en cualquier linea del -i
set "%~2="
set "_T=%TEMP%\ffinf_%RANDOM%%RANDOM%.txt"
"%FFMPEG%" -hide_banner -i "%~1" 1>nul 2>"%_T%"
for /f "usebackq delims=" %%L in ("%_T%") do (
  set "L=%%L"
  set "K=!L: %DIM_EXPECT%=!"
  if not "!K!"=="!L!" (
    set "%~2=1"
    goto :HX
  )
)
:HX
del /q "%_T%" >nul 2>&1
set "L=" & set "K="
goto :EOF


:ABS
REM arg formato "|A|B|" para no pelear con negativos/vacios
set "%~2="
set "P=%~1"
for /f "tokens=2-3 delims=|" %%a in ("%P%") do (set "A=%%a" & set "B=%%b")
if not defined A goto :EOF
if not defined B goto :EOF
for /f "delims=0123456789" %%x in ("!A!") do set "X=%%x"
if defined X (set "X=" & goto :EOF)
for /f "delims=0123456789" %%x in ("!B!") do set "X=%%x"
if defined X (set "X=" & goto :EOF)
set /a D=A-B & if !D! LSS 0 set /a D=-D
set "%~2=!D!"
set "X=" & set "A=" & set "B="
goto :EOF


:MD5
set "%~2="
if not exist "%~1" goto :EOF
set "_T=%TEMP%\md5_%RANDOM%%RANDOM%.txt"
certutil -hashfile "%~1" MD5 > "%_T%" 2>nul
for /f "usebackq skip=1 delims=" %%L in ("%_T%") do (
  if not "%%L"=="" set "S=%%L" & set "S=!S: =!" & set "%~2=!S!" & goto :AFT
)
:AFT
del /q "%_T%" >nul 2>&1
set "S="
goto :EOF


:MAKE_ASS
REM Genera _mk_overlay_ass.ps1 que crea overlay.ass con lÃ­neas "N - NombreDelClip" alineadas a cada clip
> "%~1" echo param([string]$ListPath,[string]$AssPath,[string]$FFProbe,[string]$Suffix)
>>"%~1" echo $ErrorActionPreference='Stop'
>>"%~1" echo $acc=0.0; $idx=1
>>"%~1" echo $lines = @()
>>"%~1" echo $lines += "[Script Info]"
>>"%~1" echo $lines += "ScriptType: v4.00+"
>>"%~1" echo $lines += "PlayResX: 1024"
>>"%~1" echo $lines += "PlayResY: 576"
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

:END
if exist "%STATUS_LOG%" (
  call :LOG "[END] ExitCode=%ERRORLEVEL%"
)
if defined _DID_PUSHD popd
exit /b
