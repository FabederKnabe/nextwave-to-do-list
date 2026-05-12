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
      "ffmpeg_pid":  5678,         # null bis record-call.ps1 setzt
      "started_at":  "ISO timestamp"
    }
#>

$ErrorActionPreference = 'Continue'

$BaseDir       = 'C:\Videocalls'
$LockfilePath  = Join-Path $BaseDir '.recording.lock'
$LogFile       = Join-Path $BaseDir 'watcher.log'
$RecordScript  = Join-Path $PSScriptRoot 'record-call.ps1'
$ProcessScript = Join-Path $PSScriptRoot 'process-recording.ps1'
$PollSeconds   = 5
$EmptyPollsToStop = 3

function Write-Log {
  param([string]$Level, [string]$Message)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts] $Level $Message"
  if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
  $line | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Send-Toast {
  param([string]$Title, [string]$Message)
  if (Get-Module -ListAvailable -Name BurntToast) {
    try {
      Import-Module BurntToast -ErrorAction Stop
      New-BurntToastNotification -Text $Title, $Message
    } catch { }
  }
}

function Test-MailboxCallActive {
  $procs = Get-Process msedge -ErrorAction SilentlyContinue |
           Where-Object { $_.MainWindowTitle -match 'meet\.mailbox\.org' }
  return ($null -ne $procs -and @($procs).Count -gt 0)
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
  ($lockData | ConvertTo-Json) | Out-File -LiteralPath $LockfilePath -Encoding utf8 -Force

  $recArgs = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
    '-File', "`"$RecordScript`"",
    '-OutputPath', "`"$mp3Path`"",
    '-LockfilePath', "`"$LockfilePath`""
  )
  Start-Process -FilePath 'powershell.exe' -ArgumentList $recArgs -WindowStyle Hidden | Out-Null
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
    try {
      Stop-Process -Id $ffmpegPid -ErrorAction SilentlyContinue
    } catch { }
    & taskkill.exe /F /PID $ffmpegPid 2>$null | Out-Null
  } else {
    # Fallback: alle ffmpeg-Prozesse killen (nur 1 Mailbox-Call gleichzeitig)
    Get-Process ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
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
  Start-Process -FilePath 'powershell.exe' -ArgumentList $procArgs -WindowStyle Hidden | Out-Null
  Write-Log 'INFO' "Pipeline started for $Mp3Path"
}

Write-Log 'INFO' "Watcher started (PID=$PID)"

$emptyPolls = 0
while ($true) {
  try {
    $callActive = Test-MailboxCallActive
    $hasLock    = Test-Path -LiteralPath $LockfilePath

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
    Write-Log 'ERROR' "Loop error: $($_.Exception.Message)"
  }

  Start-Sleep -Seconds $PollSeconds
}
