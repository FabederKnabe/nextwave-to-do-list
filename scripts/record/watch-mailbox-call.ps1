#Requires -Version 5.1
<#
  watch-mailbox-call.ps1

  Endlos-Watcher (5s Polling). Erkennt Edge-Fenster mit "meet.mailbox.org"
  im Titel und steuert Aufnahme + nachgelagerte Pipeline.

  Ablauf:
    - Edge-Fenster gefunden + kein Lockfile           -> Aufnahme starten
    - Kein Edge-Fenster mehr (3 Polls in Folge = 15s) -> Aufnahme stoppen
                                                         + process-recording.ps1 starten

  Lockfile-Schema (JSON):
    {
      "mp3_path":    "C:\Videocalls\YYYYMMDD-HHMMSS.mp3",
      "watcher_pid": 1234,
      "ffmpeg_pid":  5678,
      "started_at":  "ISO timestamp"
    }
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# --- Win32-Window-Enumeration ---
# Get-Process MainWindowTitle ist nur fuer aktive Fenster gesetzt. Hintergrund-
# Edge-Fenster haben leeren Titel -> Watcher denkt Call ist vorbei sobald User
# kurz auf VS Code wechselt. Stattdessen: EnumWindows + GetWindowText liest
# Titel ALLER sichtbaren Top-Level-Fenster.
# Add-Type ist nicht idempotent: zweiter Aufruf wirft "type already exists".
# Try-catch um Type-Check kapselt den Fall (PS-Session-Reuse).
try { [Win32Windows] | Out-Null } catch {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win32Windows {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
}
"@
}

function Get-AllWindowTitles {
  $titles = New-Object System.Collections.ArrayList
  $callback = {
    param($hWnd, $lParam)
    if ([Win32Windows]::IsWindowVisible($hWnd)) {
      $len = [Win32Windows]::GetWindowTextLength($hWnd)
      if ($len -gt 0) {
        $sb = New-Object System.Text.StringBuilder ($len + 1)
        [Win32Windows]::GetWindowText($hWnd, $sb, $sb.Capacity) | Out-Null
        [void]$titles.Add($sb.ToString())
      }
    }
    return $true
  }
  [Win32Windows]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
  return $titles
}

# --- Konfiguration ---
$BaseDir       = 'C:\Videocalls'
$LockfilePath  = Join-Path $BaseDir '.recording.lock'
$LogFile       = Join-Path $BaseDir 'watcher.log'
$PollSeconds   = 5
$EmptyPollsToStop = 3
$HeartbeatEveryNIter = 12   # 12 * 5s = 60s

# $PSScriptRoot-Fallback: bei -File mit nicht-absolutem Aufruf evtl. leer
if ([string]::IsNullOrEmpty($PSScriptRoot)) {
  if ($PSCommandPath) {
    $ScriptDir = Split-Path -Parent $PSCommandPath
  } else {
    $ScriptDir = (Get-Location).Path
  }
} else {
  $ScriptDir = $PSScriptRoot
}
$RecordScript  = Join-Path $ScriptDir 'record-call.ps1'
$ProcessScript = Join-Path $ScriptDir 'process-recording.ps1'

# --- Helpers ---
function Write-Log {
  param([string]$Level, [string]$Message)
  try {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Level $Message"
    if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
  } catch { }
}

# BurntToast einmalig beim Start pruefen, dann cachen (kein wiederholter Modul-Scan im Hot-Path)
$Script:BurntToastAvailable = $false
try {
  if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
    $Script:BurntToastAvailable = $true
  }
} catch { }

function Send-Toast {
  param([string]$Title, [string]$Message)
  if (-not $Script:BurntToastAvailable) { return }
  try {
    Import-Module BurntToast -ErrorAction Stop
    New-BurntToastNotification -Text $Title, $Message
  } catch { }
}

function Test-MailboxCallActive {
  try {
    $titles = Get-AllWindowTitles
    $hits = @($titles | Where-Object { $_ -match '(meet\.mailbox\.org|OpenTalk-Meeting|mailbox Suite - Meet)' })
    return ($hits.Count -gt 0)
  } catch {
    Write-Log 'WARN' "Test-MailboxCallActive error: $($_.Exception.Message)"
    return $false
  }
}

function Start-Recording {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $mp3Path = Join-Path $BaseDir "$stamp.mp3"

  $lockData = [ordered]@{
    mp3_path    = $mp3Path
    watcher_pid = $PID
    ffmpeg_pid  = $null
    started_at  = (Get-Date).ToString('o')
  }
  try {
    ($lockData | ConvertTo-Json) | Out-File -LiteralPath $LockfilePath -Encoding utf8 -Force
  } catch {
    Write-Log 'ERROR' "Could not write lockfile: $($_.Exception.Message)"
    return $null
  }

  $recArgs = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
    '-File', "`"$RecordScript`"",
    '-OutputPath', "`"$mp3Path`"",
    '-LockfilePath', "`"$LockfilePath`""
  )
  try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList $recArgs -WindowStyle Hidden | Out-Null
  } catch {
    Write-Log 'ERROR' "Could not start record-call.ps1: $($_.Exception.Message)"
    return $null
  }
  Write-Log 'INFO' "Recording start -> $mp3Path"
  Send-Toast -Title 'nextWAVE Recorder' -Message "Aufnahme laeuft: $stamp.mp3"
  return $mp3Path
}

function Stop-Recording {
  if (-not (Test-Path -LiteralPath $LockfilePath)) { return $null }

  $mp3Path = $null
  $ffmpegPid = $null
  try {
    $lock = Get-Content -LiteralPath $LockfilePath -Raw -Encoding utf8 | ConvertFrom-Json
    $mp3Path = $lock.mp3_path
    $ffmpegPid = $lock.ffmpeg_pid
  } catch {
    Write-Log 'ERROR' "Could not read lockfile: $($_.Exception.Message)"
  }

  if ($ffmpegPid) {
    try { Stop-Process -Id $ffmpegPid -ErrorAction SilentlyContinue } catch { }
    try { & taskkill.exe /F /PID $ffmpegPid 2>$null | Out-Null } catch { }
  } else {
    try {
      Get-Process ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch { }
  }

  Start-Sleep -Seconds 2
  Remove-Item -LiteralPath $LockfilePath -Force -ErrorAction SilentlyContinue
  Write-Log 'INFO' "Recording stopped -> $mp3Path"
  return $mp3Path
}

function Test-RecordingValid {
  param([string]$Mp3Path)
  if (-not (Test-Path -LiteralPath $Mp3Path)) { return $false }
  try {
    return (Get-Item -LiteralPath $Mp3Path).Length -gt 1024
  } catch { return $false }
}

function Start-PostProcessing {
  param([string]$Mp3Path)
  if (-not (Test-RecordingValid -Mp3Path $Mp3Path)) {
    Send-Toast -Title 'nextWAVE Recorder' -Message 'Aufnahme fehlgeschlagen oder leer'
    Write-Log 'ERROR' "MP3 missing or too small: $Mp3Path"
    return
  }

  $procArgs = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
    '-File', "`"$ProcessScript`"",
    '-Mp3Path', "`"$Mp3Path`""
  )
  try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList $procArgs -WindowStyle Hidden | Out-Null
    Write-Log 'INFO' "Pipeline started for $Mp3Path"
  } catch {
    Write-Log 'ERROR' "Could not start process-recording.ps1: $($_.Exception.Message)"
  }
}

# --- Watch-Loop ---
function Invoke-WatchLoop {
  $emptyPolls = 0
  $iter = 0
  while ($true) {
    $iter++
    try {
      $callActive = Test-MailboxCallActive
      $hasLock    = Test-Path -LiteralPath $LockfilePath

      if (($iter % $HeartbeatEveryNIter) -eq 1) {
        Write-Log 'TICK' "iter=$iter callActive=$callActive hasLock=$hasLock emptyPolls=$emptyPolls"
      }

      if ($callActive -and -not $hasLock) {
        Start-Recording | Out-Null
        $emptyPolls = 0
      }
      elseif (-not $callActive -and $hasLock) {
        $emptyPolls++
        if ($emptyPolls -ge $EmptyPollsToStop) {
          $mp3 = Stop-Recording
          $emptyPolls = 0
          if ($mp3) { Start-PostProcessing -Mp3Path $mp3 }
        }
      }
      elseif ($callActive -and $hasLock) {
        $emptyPolls = 0
      }
    } catch {
      Write-Log 'ERROR' "Loop iter=$iter error: $($_.Exception.Message)"
    }

    try {
      Start-Sleep -Seconds $PollSeconds
    } catch {
      Write-Log 'ERROR' "Start-Sleep error iter=${iter}: $($_.Exception.Message)"
      Start-Sleep -Milliseconds ($PollSeconds * 1000)
    }
  }
}

# Top-level trap: faengt auch terminating errors, die sich aus dem Loop heraussprengen
trap {
  Write-Log 'FATAL' "Top-level trap: $($_.Exception.Message)"
  continue
}

Write-Log 'INFO' "Watcher started (PID=$PID) ScriptDir=$ScriptDir BurntToast=$($Script:BurntToastAvailable)"

# Endlos-Loop in Funktion eingekapselt: einzige Wege raus sind Kill von aussen
# oder unbehandelter terminating error (vom trap geloggt).
while ($true) {
  try {
    Invoke-WatchLoop
  } catch {
    Write-Log 'FATAL' "Invoke-WatchLoop crashed: $($_.Exception.Message). Restart in 5s."
    Start-Sleep -Seconds 5
  }
}
