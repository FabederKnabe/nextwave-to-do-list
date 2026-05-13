#Requires -Version 5.1
<#
  watcher-supervisor.ps1

  Outer-Loop fuer den Watcher. Startet watch-mailbox-call.ps1 als
  Subprocess, wartet auf Exit, restartet nach 5s. Ueberlebt damit
  jeden Watcher-Crash und auch stille Exits unter Task-Context.

  Wird als Scheduled-Task-Action ausgefuehrt (statt watch-mailbox-call.ps1
  direkt). Setup via setup-call-watcher.ps1.

  Logs:
    C:\Videocalls\watcher-supervisor.log  (Supervisor selbst)
    C:\Videocalls\watcher.log             (Watcher-Subprocess)
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$BaseDir       = 'C:\Videocalls'
$SuperLog      = Join-Path $BaseDir 'watcher-supervisor.log'

# $PSScriptRoot-Fallback fuer alle Aufruf-Varianten
if ([string]::IsNullOrEmpty($PSScriptRoot)) {
  if ($PSCommandPath) {
    $ScriptDir = Split-Path -Parent $PSCommandPath
  } else {
    $ScriptDir = (Get-Location).Path
  }
} else {
  $ScriptDir = $PSScriptRoot
}
$WatcherScript = Join-Path $ScriptDir 'watch-mailbox-call.ps1'

function Write-SuperLog {
  param([string]$Level, [string]$Message)
  try {
    if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "[$ts] $Level $Message" | Out-File -FilePath $SuperLog -Append -Encoding utf8
  } catch { }
}

trap {
  Write-SuperLog 'FATAL' "Supervisor trap: $($_.Exception.Message)"
  continue
}

Write-SuperLog 'INFO' "Supervisor started (PID=$PID) Watcher=$WatcherScript"

if (-not (Test-Path -LiteralPath $WatcherScript)) {
  Write-SuperLog 'FATAL' "Watcher script not found: $WatcherScript"
  exit 1
}

$restartCount = 0
$RestartDelaySeconds = 5

while ($true) {
  $restartCount++
  $startTime = Get-Date
  Write-SuperLog 'INFO' "Launching watcher (run #$restartCount)"

  try {
    $argsList = @(
      '-NoProfile'
      '-ExecutionPolicy', 'Bypass'
      '-File', $WatcherScript
    )
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -WindowStyle Hidden -PassThru
    if (-not $proc) {
      Write-SuperLog 'ERROR' "Start-Process returned null"
      Start-Sleep -Seconds $RestartDelaySeconds
      continue
    }
    $proc.WaitForExit()
    $duration = ((Get-Date) - $startTime).TotalSeconds
    $exitCode = $proc.ExitCode
    Write-SuperLog 'WARN' "Watcher exited after $([math]::Round($duration,1))s, ExitCode=$exitCode - restart in ${RestartDelaySeconds}s"
  } catch {
    Write-SuperLog 'ERROR' "Supervisor loop iter ${restartCount}: $($_.Exception.Message)"
  }

  try {
    Start-Sleep -Seconds $RestartDelaySeconds
  } catch {
    Start-Sleep -Milliseconds ($RestartDelaySeconds * 1000)
  }
}
