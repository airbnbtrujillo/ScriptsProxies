# Watchdog-BAT-AutoENTER.ps1
# Lanza un .BAT y, cada X min, si el BAT ya termino y no quedan procesos paralelos
# (ffmpeg/cmd/etc.), envia ENTER a este PowerShell para destrabar un Read-Host.
# Soporta -LogFile para registrar stdout+stderr del BAT (append).

# ===== Cargas nativas (seguras/idempotentes) =====
if (-not ([type]::GetType("Util.Win32"))) {
$src = @"
using System;
using System.Runtime.InteropServices;
namespace Util {
  public static class Win32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  }
}
"@;
  Add-Type -TypeDefinition $src -Language CSharp
}
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null

# ===== Helpers =====
function Get-ConsoleHwnd {
    $p = Get-Process -Id $PID -ErrorAction SilentlyContinue
    $hwnd = [IntPtr]::Zero
    if ($p -and $p.MainWindowHandle) { $hwnd = $p.MainWindowHandle }
    if ($hwnd -eq [IntPtr]::Zero) { $hwnd = [Util.Win32]::GetConsoleWindow() }
    return $hwnd
}

function Send-EnterToSelf {
    param([IntPtr]$Hwnd)
    if ($null -eq $Hwnd -or $Hwnd -eq [IntPtr]::Zero) { return $false }
    [Util.Win32]::ShowWindow($Hwnd, 9)  | Out-Null  # SW_RESTORE
    [Util.Win32]::SetForegroundWindow($Hwnd) | Out-Null
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    return $true
}

function Get-ParallelProcesses {
    param(
        [int[]]   $ExcludePids = @(),
        [string[]]$WatchNames  = @("ffmpeg","cmd","ffprobe","HandBrakeCLI","powershell")
    )
    if (-not $WatchNames) { return @() }
    $names = $WatchNames | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { ($names -contains $_.ProcessName.ToLowerInvariant()) -and (-not ($ExcludePids -contains $_.Id)) }
}

function Invoke-BatAndAutoEnter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$BatPath,
        [int]$CheckMinutes = 3,
        [string[]]$AlsoWatch = @("ffmpeg","cmd","ffprobe","HandBrakeCLI","powershell"),
        [string]$LogFile,
        [switch]$VerboseWatch
    )

    # Resolver ruta del BAT
    if (-not (Test-Path -LiteralPath $BatPath)) {
        $try = Join-Path -Path (Get-Location) -ChildPath $BatPath
        if (Test-Path -LiteralPath $try) { $BatPath = (Resolve-Path -LiteralPath $try).Path }
    }
    if (-not (Test-Path -LiteralPath $BatPath)) { throw "No se encontro el BAT: $BatPath" }

    # Info del host (NO usar $Host)
    $hostInfo = [pscustomobject]@{
        Pid  = $PID
        Hwnd = Get-ConsoleHwnd
    }

    # Preparar redireccion a log (si se pide)
    $argList = '/c "' + $BatPath + '"'
    if ($LogFile) {
        $lfDir = Split-Path -Parent $LogFile
        if ($lfDir) { New-Item -ItemType Directory -Force -Path $lfDir | Out-Null }
        $hdr = "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $BatPath ====="
        $hdr | Out-File -FilePath $LogFile -Append -Encoding UTF8
        $argList += ' 1>>"' + $LogFile + '" 2>&1'
    }

    Write-Host ""
    Write-Host "=========== LAUNCH BAT ===========" -ForegroundColor Cyan
    Write-Host "[LAUNCH] $BatPath"
    Write-Host "[INFO] Check cada $CheckMinutes min | Watch: $($AlsoWatch -join ', ')"
    if ($LogFile) { Write-Host "[INFO] Log BAT: $LogFile" }

    # Lanzar BAT (no bloquea)
    $batProc = Start-Process -FilePath "cmd.exe" -ArgumentList $argList -WindowStyle Normal -PassThru

    # Watchdog asincrono
    $timer = New-Object System.Timers.Timer
    $timer.Interval  = [Math]::Max(1, $CheckMinutes) * 60 * 1000
    $timer.AutoReset = $true

    $script:WD_BatPid   = $batProc.Id
    $script:WD_Watch    = $AlsoWatch
    $script:WD_HostPid  = $hostInfo.Pid
    $script:WD_HostHwnd = $hostInfo.Hwnd
    $script:WD_Fired    = $false
    $srcId = "WATCHDOG_$($batProc.Id)_$(Get-Random)"

    if ($VerboseWatch) {
        Write-Host "[WATCHDOG] Arrancado. PID BAT: $($batProc.Id). HostPID: $($hostInfo.Pid). Intervalo: $($timer.Interval) ms"
    }

    Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier $srcId -Action {
        try {
            $batAlive = $false
            $bat = Get-Process -Id $script:WD_BatPid -ErrorAction SilentlyContinue
            if ($bat) { $batAlive = $true }
            if ($batAlive) {
                Write-Host "[WATCHDOG] BAT aun en ejecucion (PID $($script:WD_BatPid))."
                return
            }

            $others = Get-ParallelProcesses -ExcludePids @($script:WD_BatPid, $script:WD_HostPid) -WatchNames $script:WD_Watch
            if ($others -and $others.Count -gt 0) {
                $names = ($others | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
                Write-Host "[WATCHDOG] Esperando procesos paralelos: $names"
                return
            }

            if (-not $script:WD_Fired) {
                $script:WD_Fired = $true
                $ok = Send-EnterToSelf -Hwnd $script:WD_HostHwnd
                if ($ok) {
                    Write-Host "[WATCHDOG] ENTER enviado a este .ps1. BAT finalizado y sin procesos paralelos."
                } else {
                    Write-Host "[WATCHDOG] No se pudo enviar ENTER (host sin ventana visible)."
                }
                $sender = $event.Sender
                $sender.Stop(); $sender.Dispose()
                Unregister-Event -SourceIdentifier $event.SourceIdentifier -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            Write-Host "[WATCHDOG] Error: $($_.Exception.Message)"
        }
    } | Out-Null

    $timer.Start()
    return $batProc
}
