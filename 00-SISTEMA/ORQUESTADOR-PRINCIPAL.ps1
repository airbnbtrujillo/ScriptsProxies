<#
Scan-Proyectos.ps1  (versiÃ³n con espera inteligente)
- Pide RootPath si no se pasÃ³ por parÃ¡metro (modo interactivo), o usa carpeta actual con -NoPrompt.
- Invoke-Bat-Watch: lanza BAT y espera por ciclos:
    * si el BAT sigue vivo -> sigue esperando
    * si terminÃ³ y no hay procesos paralelos (ffmpeg/ffprobe/HandBrakeCLI) -> continua
- No usa SendKeys ni ENTER programÃ¡tico (si Run-GIF-Splitter pide ruta, la ingresas tÃº).
#>

param(
    [string]$RootPath,
    [string]$ReportOut,
    [switch]$NoPrompt,   # usa -NoPrompt para ejecuciÃ³n automÃ¡tica (sin preguntar)
    [switch]$SkipPreflight,
    [switch]$PreflightOnly
)

# Validacion central antes de copiar o ejecutar cualquier script.
$RepoRoot = Split-Path -Parent $PSScriptRoot
$PreflightScript = Join-Path $RepoRoot 'tools\Test-Scripts.ps1'
if (-not $SkipPreflight -and (Test-Path -LiteralPath $PreflightScript)) {
    Write-Host "[PREFLIGHT] Validando instalacion de scripts..." -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PreflightScript -Root $RepoRoot -Quick
    $preflightCode = $LASTEXITCODE
    if ($preflightCode -ge 2) {
        Write-Host "[PREFLIGHT][ERROR] Hay errores criticos. Usa la opcion Diagnostico del menu principal." -ForegroundColor Red
        exit $preflightCode
    }
    if ($preflightCode -eq 1) {
        Write-Host "[PREFLIGHT][AVISO] Hay advertencias no bloqueantes; el flujo puede continuar." -ForegroundColor Yellow
    }
} elseif (-not $SkipPreflight) {
    Write-Host "[PREFLIGHT][AVISO] No existe $PreflightScript; continuo en modo compatible." -ForegroundColor Yellow
}

if ($PreflightOnly) {
    Write-Host "[PREFLIGHT] Diagnostico terminado; no se procesaron proyectos."
    exit 0
}

# === Pedir ruta si no se pasÃ³ por argumento ===
if ([string]::IsNullOrWhiteSpace($RootPath)) {
    if (-not $NoPrompt) {
        $RootPath = Read-Host "Ruta raÃ­z a escanear (ENTER = carpeta actual)"
        if ([string]::IsNullOrWhiteSpace($RootPath)) {
            $RootPath = (Get-Location).Path
        }
    } else {
        # modo headless: usar carpeta actual
        $RootPath = (Get-Location).Path
    }
}

# ValidaciÃ³n y mensaje claro si la ruta no existe
if (-not (Test-Path -LiteralPath $RootPath)) {
    Write-Host "[ERROR] La ruta '$RootPath' no existe. Corrige e intÃ©ntalo de nuevo." -ForegroundColor Red
    Pause
    exit 1
}

# Antes de decidir que finales se pueden saltar, comprobar que los originales,
# proxies intermedios y finales siguen siendo coherentes. Los archivos dudosos
# se apartan de forma recuperable; los bloques normales de cada camara crean
# despues solamente lo que haya quedado pendiente.
$IntegrityScript = Join-Path $RepoRoot 'tools\Test-ProxyIntegrity.ps1'
if (Test-Path -LiteralPath $IntegrityScript -PathType Leaf) {
    Write-Host '[INTEGRIDAD] Verificando cambios, parciales y videos corruptos...' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $IntegrityScript -RootPath $RootPath -Repair
    $integrityCode = $LASTEXITCODE
    if ($integrityCode -ge 2) {
        Write-Host '[INTEGRIDAD][ERROR] La validacion no pudo completarse con seguridad; se detiene el procesamiento.' -ForegroundColor Red
        exit $integrityCode
    }
    if ($integrityCode -eq 1) {
        Write-Host '[INTEGRIDAD] Se prepararon solamente las camaras afectadas para su reconstruccion.' -ForegroundColor Yellow
    }
} else {
    Write-Host "[INTEGRIDAD][AVISO] No existe $IntegrityScript; continuo en modo compatible." -ForegroundColor Yellow
}

Write-Host "===== RUN START ====="
Write-Host "RootPath = $RootPath"

# ================================
# Config de "procesos paralelos" y periodo de chequeo
# ================================
$WatchParallel   = @('ffmpeg','ffprobe','HandBrakeCLI')  # agrega 'cmd' si de verdad lo necesitas
$CheckPeriodSecs = 15                                    # respuesta rapida sin sondeo agresivo

# ================================
# Helper: lanzar BAT y esperar por ciclos
# ================================
function Invoke-Bat-Watch {
    param(
        [Parameter(Mandatory=$true)][string]$BatFullPath,
        [Parameter(Mandatory=$true)][string]$WorkDir,
        [string[]]$AlsoWatch = $WatchParallel,
        [int]$PeriodSeconds = $CheckPeriodSecs
    )

    if (-not (Test-Path -LiteralPath $BatFullPath)) { throw "[WATCH] No se encontro el BAT: $BatFullPath" }
    if (-not (Test-Path -LiteralPath $WorkDir))     { throw "[WATCH] No existe WorkingDirectory: $WorkDir" }

    Write-Host ("[WATCH] Lanzando: {0}" -f $BatFullPath)
    $argList = '/c "' + $BatFullPath + '"'
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList $argList -WorkingDirectory $WorkDir -PassThru

    while ($true) {
        # Â¿Sigue vivo el BAT?
        $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($alive) {
            Write-Host ("[WATCH] BAT PID {0} en ejecucion. Reviso en {1}s..." -f $proc.Id, $PeriodSeconds)
            try { Wait-Process -Id $proc.Id -Timeout $PeriodSeconds -ErrorAction SilentlyContinue } catch {}
            continue
        }

        # BAT ya terminÃ³. Â¿Quedan procesos "paralelos"?
        $others = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { ($AlsoWatch -contains $_.ProcessName) -and ($_.Id -ne $PID) })
        if ($others.Count -gt 0) {
            $names = ($others | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
            Write-Host ("[WATCH] BAT finalizado, pero aun hay procesos paralelos: {0}. Reviso en {1}s..." -f $names, $PeriodSeconds)
            Start-Sleep -Seconds $PeriodSeconds
            continue
        }

        Write-Host "[WATCH] BAT finalizado y sin procesos paralelos. Continuando..."
        break
    }

    # (opcional) salida del cÃ³digo del cmd
    try {
        $p2 = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if (-not $p2 -and $proc.HasExited) { Write-Host ("[WATCH] ExitCode del cmd: {0}" -f $proc.ExitCode) }
    } catch {}
}

function Test-CameraIntegrityBlocked {
    param([string]$ProjectPath,[string]$CameraId)
    $statePath=Join-Path $ProjectPath ('.proxy-integrity\{0}.json' -f $CameraId)
    if(-not(Test-Path -LiteralPath $statePath -PathType Leaf)){return $false}
    try{return [bool](Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json).Blocked}catch{return $false}
}

# ================================
# Rutas fijas de scripts origen
# ================================
$ScriptsRoot             = Join-Path $RepoRoot '01-CAMARAS'
$GifScriptsRoot          = Join-Path $RepoRoot '02-GIFS'
$VuzeProxyScriptSrc      = Join-Path $ScriptsRoot 'CAM-01-VUZE-PROXY-960x960-20fps.bat'
$QooProxyScriptSrc       = Join-Path $ScriptsRoot 'CAM-02-QOOCAM-PROXY.bat'
$GoProProxyScriptSrc     = Join-Path $ScriptsRoot 'CAM-03-GOPRO-PROXY.bat'
$Gear360ProxyScriptSrc   = Join-Path $ScriptsRoot 'CAM-04-GEAR360-PROXY.bat'
$DjiOsmoProxyScriptSrc   = Join-Path $ScriptsRoot 'CAM-05-DJI-OSMO-PROXY-960x960-20fps.bat'
$InstaEvoProxyScriptSrc  = Join-Path $ScriptsRoot 'CAM-06-INSTA-EVO-PROXY-960x960-20fps.bat'
$TarsierProxyScriptSrc   = Join-Path $ScriptsRoot 'CAM-07-TARSIER-PROXY.bat'
$TecheProxyScriptSrc     = Join-Path $ScriptsRoot 'CAM-08-TECHE-PROXY.bat'
$TecheSyncScriptSrc      = Join-Path $ScriptsRoot 'CAM-08-TECHE-CORREGIR-TIEMPO.ps1'
$GifCmdSrc               = Join-Path $GifScriptsRoot 'GIF-01-EJECUTAR-SEPARADOR.cmd'
$GifPs1Src               = Join-Path $GifScriptsRoot 'GIF-02-SEPARAR-AUTOMATICO.ps1'

# ================================
# Definir salida del CSV
# ================================
if (-not $ReportOut -or $ReportOut -eq "") {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $ReportOut = Join-Path $RootPath ("ScanReport_{0}.csv" -f $timestamp)
}

Write-Host "====================================================="
Write-Host " Escaneando raÃ­z: $RootPath"
Write-Host " Reporte final:   $ReportOut"
Write-Host "====================================================="

# ================================
# BLOQUE ESPECIAL QOOCAM DESACTIVADO
# ================================
# Antes este script copiaba SIEMPRE a E:\191 - Laly Paragaya\100QOOCAM.
# Se desactiva para que el unificador solo trabaje dentro de la raiz elegida.

# ================================
# BLOQUE ESPECIAL INSTA EVO DESACTIVADO
# ================================
# Antes este script podia copiar/ejecutar siempre en E:\189 - Ari Lights\Camera01.
# Se desactiva para que el unificador solo trabaje dentro de la raiz elegida.

# Donde acumulamos info para Excel
$report = @()

# ================================
# Tomar solo carpetas que empiezan con nÃºmero
# ================================
$projectFolders = Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d' } | Sort-Object Name

foreach ($proj in $projectFolders) {

    Write-Host ""
    Write-Host "==== Procesando: $($proj.FullName) ====" -ForegroundColor Cyan

    $projName = $proj.Name
    $projPath = $proj.FullName
    $blockedVuze    = Test-CameraIntegrityBlocked $projPath 'CAM-01'
    $blockedQoo     = Test-CameraIntegrityBlocked $projPath 'CAM-02'
    $blockedGopro   = Test-CameraIntegrityBlocked $projPath 'CAM-03'
    $blockedGear    = Test-CameraIntegrityBlocked $projPath 'CAM-04'
    $blockedDji     = Test-CameraIntegrityBlocked $projPath 'CAM-05'
    $blockedInsta   = Test-CameraIntegrityBlocked $projPath 'CAM-06'
    $blockedTarsier = Test-CameraIntegrityBlocked $projPath 'CAM-07'
    $blockedTeche   = Test-CameraIntegrityBlocked $projPath 'CAM-08'

    # -------------------------
    # Paths base dentro del proyecto
    # -------------------------
    $vuzeDirPath   = Join-Path $projPath "100VUZXR"
    $hasVuzeDir    = Test-Path -LiteralPath $vuzeDirPath

    $qooDirPath    = Join-Path $projPath "100QOOCAM"
    $hasQooDir     = Test-Path -LiteralPath $qooDirPath
	
	$tarsierDirPath    = Join-Path $projPath "Tarsier"
    $hasTarsierDir     = Test-Path -LiteralPath $tarsierDirPath


    $goproDirPath  = Join-Path $projPath "100GOPRO"
    $hasGoproDir   = Test-Path -LiteralPath $goproDirPath

    $gearDirPath   = Join-Path $projPath "101PHOTO"  # Gear360
    $hasGearDir    = Test-Path -LiteralPath $gearDirPath

    $instaCam01Dir = Join-Path $projPath "Camera01"  # INSTA EVO (genÃ©rico)
    $djiOsmoDirPath = Join-Path $projPath "CAM_001"
    $hasDjiOsmoDir  = Test-Path -LiteralPath $djiOsmoDirPath

    # Carpetas con formato fecha YYYY_MM_DD
    $dateDirs = Get-ChildItem -LiteralPath $projPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}_\d{2}_\d{2}$' }
    $hasDateDir   = ($dateDirs.Count -gt 0)
    $dateDirNames = $dateDirs.Name -join '; '

    # -------------------------
    # Archivos "* RAW PROXY Complete*" (en raÃ­z del proyecto)
    # -------------------------
    $vuzeCompleteFile   = Get-ChildItem -LiteralPath $projPath -File -Filter "*VUZE RAW PROXY Complete*"  -ErrorAction SilentlyContinue | Select-Object -First 1
    $hasVuzeComplete    = $null -ne $vuzeCompleteFile

    $techeCompleteFile  = Get-ChildItem -LiteralPath $projPath -File -Filter "*TECHE RAW PROXY Complete*" -ErrorAction SilentlyContinue | Select-Object -First 1
    $hasTecheComplete   = $null -ne $techeCompleteFile

    $instaCompleteFile  = Get-ChildItem -LiteralPath $projPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*INSTA RAW PROXY Complete*" } | Select-Object -First 1
    $hasInstaComplete   = $null -ne $instaCompleteFile

    $goproCompleteFile  = Get-ChildItem -LiteralPath $projPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*GOPRO RAW PROXY Complete*" } | Select-Object -First 1
    $hasGoproComplete   = $null -ne $goproCompleteFile
	
	$tarsierCompleteFile  = Get-ChildItem -LiteralPath $projPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*TARSIER RAW PROXY Complete*" } | Select-Object -First 1
    $hasTarsierComplete   = $null -ne $tarsierCompleteFile

    $gearCompleteFile   = Get-ChildItem -LiteralPath $projPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*GEAR 360 RAW PROXY Complete*" } | Select-Object -First 1
    $hasGearComplete    = $null -ne $gearCompleteFile

    $djiOsmoCompleteFile = Get-ChildItem -LiteralPath $projPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*DJI OSMO RAW Proxy Complete*" } | Select-Object -First 1
    $hasDjiOsmoComplete  = $null -ne $djiOsmoCompleteFile

    # -------------------------
    # Flags de acciones ejecutadas
    # -------------------------
    $ranVuzeProxy        = $false
    $ranTecheProxy       = $false
    $ranGifSplitter      = $false
    $copiedQooProxy      = $false
    $ranQooProxy         = $false
    $copiedInstaEvoProxy = $false
    $ranInstaEvoProxy    = $false
    $copiedGoproProxy    = $false
    $ranGoproProxy       = $false
    $copiedGear360Proxy  = $false
    $ranGear360Proxy     = $false
    $copiedDjiOsmoProxy  = $false
    $ranDjiOsmoProxy     = $false

    # =====================================
    # BLOQUE VUZE PROXY
    # =====================================
    if ($blockedVuze) {
        Write-Host ' [VUZE][BLOQUEADO] Hay un original ilegible; se conserva lo existente y no se procesa esta camara.' -ForegroundColor Red
    } elseif ($hasVuzeDir) {
        Write-Host " [VUZE] Carpeta 100VUZXR encontrada."
        if (-not $hasVuzeComplete) {
            Write-Host " [VUZE] Falta '*VUZE RAW PROXY Complete*' en la raÃ­z del proyecto."
            if (Test-Path -LiteralPath $VuzeProxyScriptSrc) {
                $dstVuzeScript = Join-Path $vuzeDirPath (Split-Path $VuzeProxyScriptSrc -Leaf)
                Write-Host " [VUZE] Copiando script -> $dstVuzeScript"
                Copy-Item -LiteralPath $VuzeProxyScriptSrc -Destination $dstVuzeScript -Force
                Write-Host " [VUZE] Ejecutando script proxy VUZE en $vuzeDirPath ..."
                Invoke-Bat-Watch -BatFullPath $dstVuzeScript -WorkDir $vuzeDirPath
                $ranVuzeProxy = $true
                # (re)validaciÃ³n opcional
                $vuzeCompleteFile = Get-ChildItem -LiteralPath $projPath -File -Filter "*VUZE RAW PROXY Complete*" -ErrorAction SilentlyContinue | Select-Object -First 1
                $hasVuzeComplete  = $null -ne $vuzeCompleteFile
            } else {
                Write-Host " [VUZE][ADVERTENCIA] No encontrÃ© $VuzeProxyScriptSrc"
            }
        } else {
            Write-Host " [VUZE] Ya existe '*VUZE RAW PROXY Complete*'. OK."
        }
    } else {
        Write-Host " [VUZE] NO hay carpeta 100VUZXR."
    }

    # =====================================
    # BLOQUE QOOCAM (copiar y EJECUTAR solo si existe 100QOOCAM; NO crear)
    # =====================================
    if ($blockedQoo) {
        Write-Host ' [QOO][BLOQUEADO] Hay un original ilegible; se conserva lo existente y no se procesa esta camara.' -ForegroundColor Red
    } elseif ($hasQooDir) {
        Write-Host " [QOO] Carpeta 100QOOCAM encontrada."
        if ($QooProxyScriptSrc -and (Test-Path -LiteralPath $QooProxyScriptSrc)) {
            $dstQooScript = Join-Path $qooDirPath (Split-Path $QooProxyScriptSrc -Leaf)
            Write-Host " [QOO] Copiando script QOOCAM -> $dstQooScript"
            try {
                Copy-Item -LiteralPath $QooProxyScriptSrc -Destination $dstQooScript -Force
                $copiedQooProxy = $true
                Write-Host " [QOO] Ejecutando script QOOCAM (espera inteligente) en $qooDirPath ..."
                Invoke-Bat-Watch -BatFullPath $dstQooScript -WorkDir $qooDirPath
                $ranQooProxy = $true
            } catch {
                Write-Host " [QOO][ERROR] $($_.Exception.Message)"
            }
        } else {
            Write-Host " [QOO][ADVERTENCIA] No encontrÃ© script QOOCAM en $ScriptsRoot"
        }
    } else {
        Write-Host " [QOO] NO hay carpeta 100QOOCAM. (No se crea; se continua)"
    }

	    # =====================================
    # BLOQUE TARSIER (copiar y EJECUTAR solo si existe TARSIER; NO crear)
    # =====================================
    if ($blockedTarsier) {
        Write-Host ' [TARSIER][BLOQUEADO] Hay un original ilegible; se conserva lo existente y no se procesa esta camara.' -ForegroundColor Red
    } elseif ($hasTarsierDir) {
        Write-Host " [TARSIER] Carpeta TARSIER encontrada."
        if (-not $hasTarsierComplete) {
		if ($TarsierProxyScriptSrc -and (Test-Path -LiteralPath $TarsierProxyScriptSrc)) {
                $dstTarsier = Join-Path $tarsierDirPath (Split-Path $TarsierProxyScriptSrc -Leaf)
                Write-Host " [TARSIER] Copiando -> $dstTarsier"
                try {
                    Copy-Item -LiteralPath $TarsierProxyScriptSrc -Destination $dstTarsier -Force
                    $copiedTarsierProxy = $true
                    Write-Host " [TARSIER] Ejecutando (espera inteligente) en $tarsierDirPath ..."
                    Invoke-Bat-Watch -BatFullPath $dstTarsier -WorkDir $tarsierDirPath
                    $ranTarsierProxy = $true
                    # revalidar
                    $tarsierCompleteFile = Get-ChildItem -LiteralPath $projPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*TARSIER RAW PROXY Complete*" } | Select-Object -First 1
                    $hasTarsierComplete  = $null -ne $tarsierCompleteFile
                } catch {
                    Write-Host " [TARSIER][ERROR] $($_.Exception.Message)"
                }
            } else {
                Write-Host " [TARSIER][ADVERTENCIA] No encontrÃ© '$TarsierProxyScriptSrc'"
            }
        } else {
            Write-Host " [TARSIER] Ya existe 'TARSIER RAW PROXY Complete'. OK."
        }
    } else {
        Write-Host " [TARSIER] NO hay carpeta TARSIER."
    }
		
				
    # =====================================
    # BLOQUE GOPRO (100GOPRO)
    # =====================================
    if ($blockedGopro) {
        Write-Host ' [GOPRO][BLOQUEADO] Hay un original ilegible; se conserva lo existente y no se procesa esta camara.' -ForegroundColor Red
    } elseif ($hasGoproDir) {
        Write-Host " [GOPRO] Carpeta 100GOPRO encontrada."
        if (-not $hasGoproComplete) {
            if ($GoProProxyScriptSrc -and (Test-Path -LiteralPath $GoProProxyScriptSrc)) {
                $dstGoPro = Join-Path $goproDirPath (Split-Path $GoProProxyScriptSrc -Leaf)
                Write-Host " [GOPRO] Copiando -> $dstGoPro"
                try {
                    Copy-Item -LiteralPath $GoProProxyScriptSrc -Destination $dstGoPro -Force
                    $copiedGoproProxy = $true
                    Write-Host " [GOPRO] Ejecutando (espera inteligente) en $goproDirPath ..."
                    Invoke-Bat-Watch -BatFullPath $dstGoPro -WorkDir $goproDirPath
                    $ranGoproProxy = $true
                    # revalidar
                    $goproCompleteFile = Get-ChildItem -LiteralPath $projPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*GOPRO RAW PROXY Complete*" } | Select-Object -First 1
                    $hasGoproComplete  = $null -ne $goproCompleteFile
                } catch {
                    Write-Host " [GOPRO][ERROR] $($_.Exception.Message)"
                }
            } else {
                Write-Host " [GOPRO][ADVERTENCIA] No encontrÃ© '$GoProProxyScriptSrc'"
            }
        } else {
            Write-Host " [GOPRO] Ya existe 'GOPRO RAW PROXY Complete'. OK."
        }
    } else {
        Write-Host " [GOPRO] NO hay carpeta 100GOPRO."
    }

    # =====================================
    # BLOQUE GEAR 360 (101PHOTO)
    # =====================================
    if ($blockedGear) {
        Write-Host ' [GEAR360][BLOQUEADO] Hay un original ilegible; se conserva lo existente y no se procesa esta camara.' -ForegroundColor Red
    } elseif ($hasGearDir) {
        Write-Host " [GEAR360] Carpeta 101PHOTO encontrada."
        if (-not $hasGearComplete) {
            if ($Gear360ProxyScriptSrc -and (Test-Path -LiteralPath $Gear360ProxyScriptSrc)) {
                $dstGear = Join-Path $gearDirPath (Split-Path $Gear360ProxyScriptSrc -Leaf)
                Write-Host " [GEAR360] Copiando -> $dstGear"
                try {
                    Copy-Item -LiteralPath $Gear360ProxyScriptSrc -Destination $dstGear -Force
                    $copiedGear360Proxy = $true
                    Write-Host " [GEAR360] Ejecutando (espera inteligente) en $gearDirPath ..."
                    Invoke-Bat-Watch -BatFullPath $dstGear -WorkDir $gearDirPath
                    $ranGear360Proxy = $true
                    # revalidar
                    $gearCompleteFile = Get-ChildItem -LiteralPath $projPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*GEAR 360 RAW PROXY Complete*" } | Select-Object -First 1
                    $hasGearComplete   = $null -ne $gearCompleteFile
                } catch {
                    Write-Host " [GEAR360][ERROR] $($_.Exception.Message)"
                }
            } else {
                Write-Host " [GEAR360][ADVERTENCIA] No encontrÃ© '$Gear360ProxyScriptSrc'"
            }
        } else {
            Write-Host " [GEAR360] Ya existe 'GEAR 360 RAW PROXY Complete'. OK."
        }
    } else {
        Write-Host " [GEAR360] NO hay carpeta 101PHOTO."
    }

    # =====================================
    # BLOQUE DJI OSMO 360 (CAM_001)
    # =====================================
    if ($blockedDji) {
        Write-Host ' [DJI OSMO][BLOQUEADO] Hay un original ilegible; se conserva lo existente y no se procesa esta camara.' -ForegroundColor Red
    } elseif ($hasDjiOsmoDir) {
        Write-Host " [DJI OSMO] Carpeta CAM_001 encontrada."
        if (-not $hasDjiOsmoComplete) {
            if ($DjiOsmoProxyScriptSrc -and (Test-Path -LiteralPath $DjiOsmoProxyScriptSrc)) {
                $dstDjiOsmo = Join-Path $djiOsmoDirPath (Split-Path $DjiOsmoProxyScriptSrc -Leaf)
                Write-Host " [DJI OSMO] Copiando -> $dstDjiOsmo"
                try {
                    Copy-Item -LiteralPath $DjiOsmoProxyScriptSrc -Destination $dstDjiOsmo -Force
                    $copiedDjiOsmoProxy = $true
                    Write-Host " [DJI OSMO] Ejecutando (espera inteligente) en $djiOsmoDirPath ..."
                    Invoke-Bat-Watch -BatFullPath $dstDjiOsmo -WorkDir $djiOsmoDirPath
                    $ranDjiOsmoProxy = $true
                    $djiOsmoCompleteFile = Get-ChildItem -LiteralPath $projPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*DJI OSMO RAW Proxy Complete*" } | Select-Object -First 1
                    $hasDjiOsmoComplete  = $null -ne $djiOsmoCompleteFile
                } catch {
                    Write-Host " [DJI OSMO][ERROR] $($_.Exception.Message)"
                }
            } else {
                Write-Host " [DJI OSMO][ADVERTENCIA] No encontré '$DjiOsmoProxyScriptSrc'"
            }
        } else {
            Write-Host " [DJI OSMO] Ya existe 'DJI OSMO RAW Proxy Complete'. OK."
        }
    } else {
        Write-Host " [DJI OSMO] NO hay carpeta CAM_001."
    }
    # =====================================
    # BLOQUE INSTA EVO (GENÃ‰RICO POR PROYECTO)
    # =====================================
    if ($blockedInsta) {
        Write-Host ' [INSTA][BLOQUEADO] Hay un original ilegible; se conserva lo existente y no se procesa esta camara.' -ForegroundColor Red
    } elseif (-not $hasInstaComplete) {
        if (Test-Path -LiteralPath $instaCam01Dir) {
            if ($InstaEvoProxyScriptSrc -and (Test-Path -LiteralPath $InstaEvoProxyScriptSrc)) {
                $dstInstaEvoScript = Join-Path $instaCam01Dir (Split-Path $InstaEvoProxyScriptSrc -Leaf)
                Write-Host " [INSTA] Copiando INSTA EVO Proxy -> $dstInstaEvoScript"
                try {
                    Copy-Item -LiteralPath $InstaEvoProxyScriptSrc -Destination $dstInstaEvoScript -Force
                    $copiedInstaEvoProxy = $true
                    Write-Host " [INSTA] Ejecutando INSTA EVO Proxy (espera inteligente) en $instaCam01Dir ..."
                    Invoke-Bat-Watch -BatFullPath $dstInstaEvoScript -WorkDir $instaCam01Dir
                    $ranInstaEvoProxy = $true
                    # revalidar
                    $instaCompleteFile = Get-ChildItem -LiteralPath $projPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*INSTA RAW PROXY Complete*" } | Select-Object -First 1
                    $hasInstaComplete   = $null -ne $instaCompleteFile
                } catch {
                    Write-Host " [INSTA][ERROR] $($_.Exception.Message)"
                }
            } else {
                Write-Host " [INSTA][ADVERTENCIA] No encontrÃ© el BAT 'INSTA EVO RAW Proxy 960x960_20fps' en $ScriptsRoot"
            }
        } else {
            Write-Host " [INSTA] NO existe carpeta '$instaCam01Dir'. No se crea; se omite."
        }
    } else {
        Write-Host " [INSTA] Ya existe 'INSTA RAW PROXY Complete' en la raÃ­z del proyecto. Omitido."
    }

    # =====================================
    # BLOQUE TECHE PROXY
    # =====================================
    if ($blockedTeche) {
        Write-Host ' [TECHE][BLOQUEADO] Hay un original ilegible; se conserva lo existente y no se procesa esta camara.' -ForegroundColor Red
    } elseif ($hasDateDir) {
        Write-Host " [TECHE] Carpeta(s) fecha encontrada(s): $dateDirNames"
        if (-not $hasTecheComplete) {
            Write-Host " [TECHE] Falta '*TECHE RAW PROXY Complete*' en la raÃ­z del proyecto."
            if (Test-Path -LiteralPath $TecheProxyScriptSrc) {
                foreach ($dateDir in $dateDirs) {
                    $dstTecheScript = Join-Path $dateDir.FullName (Split-Path $TecheProxyScriptSrc -Leaf)
                    Write-Host " [TECHE] Copiando script -> $dstTecheScript"
                    Copy-Item -LiteralPath $TecheProxyScriptSrc -Destination $dstTecheScript -Force
                    if (Test-Path -LiteralPath $TecheSyncScriptSrc) {
                        $dstTecheSync = Join-Path $dateDir.FullName (Split-Path $TecheSyncScriptSrc -Leaf)
                        Write-Host " [TECHE] Copiando corrector temporal -> $dstTecheSync"
                        Copy-Item -LiteralPath $TecheSyncScriptSrc -Destination $dstTecheSync -Force
                    } else {
                        Write-Host " [TECHE][ADVERTENCIA] Falta $TecheSyncScriptSrc; se usara el modo compatible."
                    }
                    Write-Host " [TECHE] Ejecutando script proxy TECHE en $($dateDir.FullName) ..."
                    Invoke-Bat-Watch -BatFullPath $dstTecheScript -WorkDir $dateDir.FullName
                    $ranTecheProxy = $true
                }
                # revalidaciÃ³n opcional
                $techeCompleteFile = Get-ChildItem -LiteralPath $projPath -File -Filter "*TECHE RAW PROXY Complete*" -ErrorAction SilentlyContinue | Select-Object -First 1
                $hasTecheComplete  = $null -ne $techeCompleteFile
            } else {
                Write-Host " [TECHE][ADVERTENCIA] No encontrÃ© $TecheProxyScriptSrc"
            }
        } else {
            Write-Host " [TECHE] Ya existe '*TECHE RAW PROXY Complete*'. OK."
        }
    } else {
        Write-Host " [TECHE] NO hay carpeta con formato YYYY_MM_DD (ej. 2023_12_08)."
    }

    # =====================================
    # BLOQUE GIFs (VUZE, TECHE, GOPRO, GEAR 360)
    # =====================================
    $gifSplitRoot  = Join-Path $projPath "GIFs_split"
    $gifVuzeDirOk  = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF VUZE")
    $gifTecheDirOk = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF TECHE")
    $gifGoproDirOk = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF GOPRO")
    $gifGearDirOk  = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF GEAR 360")
    $gifDjiOsmoDirOk = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF DJI OSMO")
	$gifTarsierDirOk  = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF TARSIER")

    $needGifForVuze  = $hasVuzeComplete  -and (-not $gifVuzeDirOk)
    $needGifForTeche = $hasTecheComplete -and (-not $gifTecheDirOk)
    $needGifForGopro = $hasGoproComplete -and (-not $gifGoproDirOk)
    $needGifForGear  = $hasGearComplete  -and (-not $gifGearDirOk)
    $needGifForDjiOsmo = $hasDjiOsmoComplete -and (-not $gifDjiOsmoDirOk)
	$needGifForTarsier  = $hasTarsierComplete  -and (-not $gifTarsierDirOk)

    if ($needGifForVuze -or $needGifForTeche -or $needGifForGopro -or $needGifForGear -or $needGifForDjiOsmo -or $needGifForTarsier) {
        $faltantes = @()
        if ($needGifForVuze)  { $faltantes += 'VUZE' }
        if ($needGifForTeche) { $faltantes += 'TECHE' }
        if ($needGifForGopro) { $faltantes += 'GOPRO' }
        if ($needGifForGear)  { $faltantes += 'GEAR 360' }
        if ($needGifForDjiOsmo) { $faltantes += 'DJI OSMO' }
		if ($needGifForTarsier)  { $faltantes += 'TARSIER' }
        Write-Host (" [GIF] Faltan GIFs_split para: {0}" -f ($faltantes -join ', '))

        $gifCmdExists = Test-Path -LiteralPath $GifCmdSrc
        $gifPs1Exists = Test-Path -LiteralPath $GifPs1Src
        if ($gifCmdExists -and $gifPs1Exists) {
            $dstGifCmd = Join-Path $projPath (Split-Path $GifCmdSrc -Leaf)
            $dstGifPs1 = Join-Path $projPath (Split-Path $GifPs1Src -Leaf)

            Write-Host " [GIF] Copiando $GifCmdSrc -> $dstGifCmd"
            Copy-Item -LiteralPath $GifCmdSrc -Destination $dstGifCmd -Force
            Write-Host " [GIF] Copiando $GifPs1Src -> $dstGifPs1"
            Copy-Item -LiteralPath $GifPs1Src -Destination $dstGifPs1 -Force

            Write-Host " [GIF] Ejecutando generador de GIFs en $projPath ..."
            Write-Host "      Cuando pida 'Ruta de la carpeta', pega:"
            Write-Host "      $projPath"
            Invoke-Bat-Watch -BatFullPath $dstGifCmd -WorkDir $projPath
            $ranGifSplitter = $true

            # Revalidar subcarpetas tras la ejecuciÃ³n
            $gifVuzeDirOk  = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF VUZE")
            $gifTecheDirOk = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF TECHE")
            $gifGoproDirOk = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF GOPRO")
            $gifGearDirOk  = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF GEAR 360")
            $gifDjiOsmoDirOk = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF DJI OSMO")
			$gifTarsierDirOk  = Test-Path -LiteralPath (Join-Path $gifSplitRoot "GIF TARSIER")
        } else {
            if (-not $gifCmdExists) { Write-Host " [GIF][ADVERTENCIA] No encontrÃ© $GifCmdSrc" }
            if (-not $gifPs1Exists) { Write-Host " [GIF][ADVERTENCIA] No encontrÃ© $GifPs1Src" }
        }
    } else {
        Write-Host " [GIF] GIFs_split ya estÃ¡ OK."
    }

    # =====================================
    # Diagnostico visible de faltantes
    # =====================================
    $techeValidClipCount = 0
    $techeProxyCount = 0
    $techeMissingProxyNames = @()
    if ($hasDateDir) {
        foreach ($dateDir in $dateDirs) {
            $validTecheDirs = @(Get-ChildItem -LiteralPath $dateDir.FullName -Directory -Filter "VIDEO_TECHE_*" -ErrorAction SilentlyContinue | Where-Object {
                Test-Path -LiteralPath (Join-Path $_.FullName "TechePrev.mp4")
            })
            $techeValidClipCount += $validTecheDirs.Count

            $proxyTecheDir = Join-Path $dateDir.FullName "Proxy TECHE RAW"
            $proxyFiles = @(Get-ChildItem -LiteralPath $proxyTecheDir -File -Filter "*.mp4" -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like "* TECHEProxy.mp4" -or $_.Name -like "*__TecheMain_proxy.mp4"
            })
            $techeProxyCount += $proxyFiles.Count

            $proxyBases = @{}
            foreach ($pf in $proxyFiles) {
                $bn = [IO.Path]::GetFileNameWithoutExtension($pf.Name) `
                    -replace '__TecheMain_proxy$','' `
                    -replace ' TECHEProxy$',''
                $proxyBases[$bn] = $true
            }
            foreach ($vd in $validTecheDirs) {
                if (-not $proxyBases.ContainsKey($vd.Name)) {
                    $techeMissingProxyNames += $vd.Name
                }
            }
        }
    }

    $faltantes = @()
    $advertencias = @()

    if ($hasVuzeDir -and (-not $hasVuzeComplete)) { $faltantes += 'VUZE Complete' }
    if ($hasDateDir -and (-not $hasTecheComplete)) { $faltantes += 'TECHE Complete' }
    if ((Test-Path -LiteralPath $instaCam01Dir) -and (-not $hasInstaComplete)) { $faltantes += 'INSTA Complete' }
    if ($hasGoproDir -and (-not $hasGoproComplete)) { $faltantes += 'GOPRO Complete' }
    if ($hasGearDir -and (-not $hasGearComplete)) { $faltantes += 'GEAR360 Complete' }
    if ($hasDjiOsmoDir -and (-not $hasDjiOsmoComplete)) { $faltantes += 'DJI OSMO Complete' }

    if ($hasVuzeComplete -and (-not $gifVuzeDirOk)) { $faltantes += 'GIF VUZE' }
    if ($hasTecheComplete -and (-not $gifTecheDirOk)) { $faltantes += 'GIF TECHE' }
    if ($hasGoproComplete -and (-not $gifGoproDirOk)) { $faltantes += 'GIF GOPRO' }
    if ($hasGearComplete -and (-not $gifGearDirOk)) { $faltantes += 'GIF GEAR360' }
    if ($hasDjiOsmoComplete -and (-not $gifDjiOsmoDirOk)) { $faltantes += 'GIF DJI OSMO' }
    if ($hasTarsierComplete -and (-not $gifTarsierDirOk)) { $faltantes += 'GIF TARSIER' }

    if ($hasDateDir -and $techeValidClipCount -ne $techeProxyCount) {
        $msg = "TECHE: clips validos=$techeValidClipCount, proxies=$techeProxyCount"
        if ($techeMissingProxyNames.Count -gt 0) {
            $msg += "; faltan proxies: " + (($techeMissingProxyNames | Sort-Object -Unique) -join ', ')
        }
        $advertencias += $msg
    }

    $estadoGeneral = if ($faltantes.Count -eq 0 -and $advertencias.Count -eq 0) { 'OK' } else { 'FALTAN' }

    # =====================================
    # Agregar fila al reporte
    # =====================================
    $report += [PSCustomObject]@{
        CarpetaProyecto                    = $projName
        RutaProyecto                       = $projPath
        Estado_General                     = $estadoGeneral
        Faltantes                          = ($faltantes -join '; ')
        Advertencias                       = ($advertencias -join '; ')
        Tiene_100VUZXR                     = $hasVuzeDir
        Tiene_100QOOCAM                    = $hasQooDir
        Tiene_100GOPRO                     = $hasGoproDir
        Tiene_101PHOTO                     = $hasGearDir
        Tiene_Carpeta_Fecha_YYYY_MM_DD     = $hasDateDir
        Carpetas_Fecha_Nombres             = $dateDirNames
        TECHE_ClipsValidos                 = $techeValidClipCount
        TECHE_ProxiesParciales             = $techeProxyCount
        TECHE_ProxiesFaltantes             = (($techeMissingProxyNames | Sort-Object -Unique) -join '; ')
        Tiene_VUZE_RAW_PROXY_Complete      = $hasVuzeComplete
        Tiene_TECHE_RAW_PROXY_Complete     = $hasTecheComplete
        Tiene_INSTA_RAW_PROXY_Complete     = $hasInstaComplete
        Tiene_GOPRO_RAW_PROXY_Complete     = $hasGoproComplete
        Tiene_GEAR360_RAW_PROXY_Complete   = $hasGearComplete
        Tiene_DJI_OSMO_RAW_PROXY_Complete  = $hasDjiOsmoComplete
        Tiene_GIF_VUZE                     = $gifVuzeDirOk
        Tiene_GIF_TECHE                    = $gifTecheDirOk
        Tiene_GIF_GOPRO                    = $gifGoproDirOk
        Tiene_GIF_GEAR360                  = $gifGearDirOk
        Tiene_GIF_DJI_OSMO                 = $gifDjiOsmoDirOk
        Ejecutado_VUZE_Proxy               = $ranVuzeProxy
        Copiado_QOOCAM_Proxy               = $copiedQooProxy
        Ejecutado_QOOCAM_Proxy             = $ranQooProxy
        Copiado_GOPRO_Proxy                = $copiedGoproProxy
        Ejecutado_GOPRO_Proxy              = $ranGoproProxy
        Copiado_GEAR360_Proxy              = $copiedGear360Proxy
        Ejecutado_GEAR360_Proxy            = $ranGear360Proxy
        Copiado_DJI_OSMO_Proxy             = $copiedDjiOsmoProxy
        Ejecutado_DJI_OSMO_Proxy           = $ranDjiOsmoProxy
        Copiado_INSTA_EVO_Proxy            = $copiedInstaEvoProxy
        Ejecutado_INSTA_EVO_Proxy          = $ranInstaEvoProxy
        Ejecutado_TECHE_Proxy              = $ranTecheProxy
        Ejecutado_GIF_Splitter             = $ranGifSplitter
    }
}

# ================================
# Exportar reporte CSV + Excel visible
# ================================
Write-Host ""
Write-Host "Guardando reporte CSV en $ReportOut ..."
$report | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportOut

$ExcelOut = [IO.Path]::ChangeExtension($ReportOut, '.xlsx')
try {
    Write-Host "Creando Excel visual en $ExcelOut ..."
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $csvPath = (Resolve-Path -LiteralPath $ReportOut).ProviderPath
    $wb = $excel.Workbooks.Open($csvPath)
    $ws = $wb.Worksheets.Item(1)
    $used = $ws.UsedRange
    $lastRow = $used.Rows.Count
    $lastCol = $used.Columns.Count

    $used.Font.Name = 'Calibri'
    $used.Font.Size = 11
    $header = $ws.Range($ws.Cells.Item(1,1), $ws.Cells.Item(1,$lastCol))
    $header.Font.Bold = $true
    $header.Interior.Color = 0x404040
    $header.Font.Color = 0xFFFFFF

    $colEstado = 0; $colFaltantes = 0; $colAdvertencias = 0
    for ($c=1; $c -le $lastCol; $c++) {
        $h = [string]$ws.Cells.Item(1,$c).Text
        if ($h -eq 'Estado_General') { $colEstado = $c }
        if ($h -eq 'Faltantes') { $colFaltantes = $c }
        if ($h -eq 'Advertencias') { $colAdvertencias = $c }
    }

    if ($lastRow -ge 2) {
        for ($r=2; $r -le $lastRow; $r++) {
            $estado = if ($colEstado -gt 0) { [string]$ws.Cells.Item($r,$colEstado).Text } else { '' }
            $faltan = if ($colFaltantes -gt 0) { [string]$ws.Cells.Item($r,$colFaltantes).Text } else { '' }
            $adv    = if ($colAdvertencias -gt 0) { [string]$ws.Cells.Item($r,$colAdvertencias).Text } else { '' }
            if ($estado -eq 'OK') {
                if ($colEstado -gt 0) {
                    $ws.Cells.Item($r,$colEstado).Interior.Color = 0xC6EFCE
                    $ws.Cells.Item($r,$colEstado).Font.Color = 0x006100
                    $ws.Cells.Item($r,$colEstado).Font.Bold = $true
                }
            } else {
                $ws.Range($ws.Cells.Item($r,1), $ws.Cells.Item($r,$lastCol)).Interior.Color = 0xF2DCDB
                if ($colEstado -gt 0) {
                    $ws.Cells.Item($r,$colEstado).Interior.Color = 0xFFC7CE
                    $ws.Cells.Item($r,$colEstado).Font.Color = 0x9C0006
                    $ws.Cells.Item($r,$colEstado).Font.Bold = $true
                }
            }
            if ($faltan -ne '' -and $colFaltantes -gt 0) {
                $ws.Cells.Item($r,$colFaltantes).Interior.Color = 0xFFF2CC
                $ws.Cells.Item($r,$colFaltantes).Font.Bold = $true
            }
            if ($adv -ne '' -and $colAdvertencias -gt 0) {
                $ws.Cells.Item($r,$colAdvertencias).Interior.Color = 0xFCE4D6
            }
        }
    }

    $ws.Application.ActiveWindow.SplitRow = 1
    $ws.Application.ActiveWindow.FreezePanes = $true
    $used.AutoFilter() | Out-Null
    $used.EntireColumn.AutoFit() | Out-Null
    if ($colFaltantes -gt 0) { $ws.Columns.Item($colFaltantes).ColumnWidth = 45 }
    if ($colAdvertencias -gt 0) { $ws.Columns.Item($colAdvertencias).ColumnWidth = 65 }

    $wb.SaveAs($ExcelOut, 51)
    $wb.Close($true)
    $excel.Quit()
    [Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
    [Runtime.InteropServices.Marshal]::ReleaseComObject($wb) | Out-Null
    [Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
    Write-Host "Listo. Abre el Excel: $ExcelOut"
} catch {
    Write-Host "[ADVERTENCIA] No pude crear XLSX con Excel COM: $($_.Exception.Message)"
    Write-Host "CSV disponible: $ReportOut"
    try { if ($wb) { $wb.Close($false) } } catch {}
    try { if ($excel) { $excel.Quit() } } catch {}
}

