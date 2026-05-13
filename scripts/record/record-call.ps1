#Requires -Version 5.1
<#
  record-call.ps1

  Startet ffmpeg-Aufnahme (Systemaudio + Mikrofon, gemixt), traegt die
  ffmpeg-PID ins Lockfile (JSON) ein und blockiert via WaitForExit bis
  der Watcher ffmpeg ueber das Lockfile killt.

  Geraete sind hardcoded. Auto-Detection wurde entfernt:
    - ffmpeg -list_devices schreibt nach stderr und exitet mit Code 1
    - PowerShell 5.1 wandelt "2>&1" stderr-Zeilen in NativeCommandError
    - $ErrorActionPreference='Stop' macht die erste solche Zeile terminierend
  Resultat: Get-AudioDevices warf willkuerlich bevor das Audio-Section-
  Parsing griff, sys/mic blieben false, Aufnahme brach ab.

  Falls sich die Device-Namen aendern: hier $SystemAudioDevice /
  $MicrophoneDevice anpassen. Verfuegbare Namen einmalig pruefen via:
    ffmpeg -hide_banner -list_devices true -f dshow -i dummy

  Parameter:
    -OutputPath   Ziel-MP3 (z.B. C:\Videocalls\20260101-180000.mp3)
    -LockfilePath Pfad des Lockfiles (z.B. C:\Videocalls\.recording.lock)

  Aufruf erfolgt vom Watcher als detached PowerShell-Prozess.
#>

param(
  [Parameter(Mandatory = $true)] [string]$OutputPath,
  [Parameter(Mandatory = $true)] [string]$LockfilePath
)

$ErrorActionPreference = 'Stop'

$LogFile           = 'C:\Videocalls\record.log'
$SystemAudioDevice = 'virtual-audio-capturer'
$MicrophoneDevice  = 'Mikrofonarray (Realtek High Definition Audio)'

function Write-Log {
  param([string]$Level, [string]$Message)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts] $Level $Message"
  $dir = Split-Path -Parent $LogFile
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
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

function Update-Lockfile {
  param([int]$FfmpegPid)
  if (-not (Test-Path -LiteralPath $LockfilePath)) {
    Write-Log 'WARN' "Lockfile $LockfilePath not present - skipping PID update"
    return
  }
  try {
    $json = Get-Content -LiteralPath $LockfilePath -Raw -Encoding utf8 | ConvertFrom-Json
    $json | Add-Member -NotePropertyName ffmpeg_pid -NotePropertyValue $FfmpegPid -Force
    ($json | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $LockfilePath -Encoding utf8 -Force
  } catch {
    Write-Log 'ERROR' "Failed to update lockfile with PID: $($_.Exception.Message)"
  }
}

try {
  $outDir = Split-Path -Parent $OutputPath
  if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

  $ffmpegLog = "$OutputPath.ffmpeg.log"

  # Array-Args umgehen jegliches PS-Quoting-Problem: jedes Element wird einzeln
  # an CreateProcess uebergeben. Speziell der Mic-Name enthaelt Klammern und
  # Leerzeichen, da gewinnt Array-Splatting gegen String-Interpolation.
  $ffmpegArgs = @(
    '-y','-hide_banner','-nostdin',
    '-f','dshow','-i',"audio=$SystemAudioDevice",
    '-f','dshow','-i',"audio=$MicrophoneDevice",
    '-filter_complex','[1:a]volume=2.0[mic];[0:a][mic]amix=inputs=2:duration=longest:dropout_transition=2:weights=1 2[a]',
    '-map','[a]','-acodec','libmp3lame','-q:a','4',
    $OutputPath
  )

  Write-Log 'INFO' "Starting ffmpeg -> $OutputPath (stderr -> $ffmpegLog)"
  Write-Log 'DEBUG' ("ffmpeg args: " + ($ffmpegArgs -join ' '))

  $proc = Start-Process -FilePath 'ffmpeg' `
    -ArgumentList $ffmpegArgs `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardError $ffmpegLog

  if (-not $proc) {
    throw "Start-Process returned null - ffmpeg konnte nicht gestartet werden"
  }

  Update-Lockfile -FfmpegPid $proc.Id
  Write-Log 'OK' "ffmpeg started, PID=$($proc.Id) - waiting for exit"

  # Blockiert bis ffmpeg stirbt - entweder gracefully, durch Watcher-Kill via
  # Lockfile-PID, oder durch eigenen Crash.
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode

  $tail = ''
  if (Test-Path -LiteralPath $ffmpegLog) {
    try {
      $tail = (Get-Content -LiteralPath $ffmpegLog -Tail 5 -Encoding utf8) -join ' | '
    } catch { }
  }

  if ($exitCode -ne 0) {
    Write-Log 'ERROR' "ffmpeg exited with code $exitCode. stderr tail: $tail"
  } else {
    Write-Log 'INFO' "ffmpeg exited cleanly (code 0)"
  }
  exit 0
}
catch {
  $detail = ($_ | Out-String).Trim()
  Write-Log 'ERROR' "record-call.ps1 failed: $detail"
  Send-Toast -Title 'nextWAVE Recorder' -Message "Aufnahme-Start fehlgeschlagen: $($_.Exception.Message)"
  exit 1
}
