#Requires -Version 5.1
<#
  record-call.ps1

  Startet ffmpeg-Aufnahme (Systemaudio + Mikrofon, gemixt), traegt die
  ffmpeg-PID ins Lockfile (JSON) ein und blockiert via WaitForExit bis
  der Watcher ffmpeg ueber das Lockfile killt.

  Geraete sind hardcoded. Auto-Detection wurde entfernt (PS 5.1 +
  ffmpeg-list_devices Output via 2>&1 brach das Parsing).

  Argumentuebergabe via [System.Diagnostics.Process] mit manuell
  gequoteter Command-Line. Start-Process -ArgumentList in PS 5.1
  re-quoted Array-Elemente mit Klammern+Spaces falsch (verifiziert:
  "Mikrofonarray (Realtek High Definition Audio)" landete bei ffmpeg
  als nackter "Mikrofonarray").

  Geraetenamen einmalig pruefen via:
    ffmpeg -hide_banner -list_devices true -f dshow -i dummy

  Parameter:
    -OutputPath   Ziel-MP3 (z.B. C:\Videocalls\20260101-180000.mp3)
    -LockfilePath Pfad des Lockfiles (z.B. C:\Videocalls\.recording.lock)
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

Import-Module "$PSScriptRoot\pipeline-toast.psm1" -Force

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

# Windows-CommandLine-Quoting: jedes Argument das Whitespace oder Quote
# enthaelt wird in doppelte Anfuehrungszeichen gewickelt, eingebettete
# Quotes werden mit Backslash escaped.
function Format-NativeArg {
  param([string]$Arg)
  if ([string]::IsNullOrEmpty($Arg)) { return '""' }
  if ($Arg -match '[\s"]') {
    $escaped = $Arg -replace '"', '\"'
    return '"' + $escaped + '"'
  }
  return $Arg
}

try {
  $outDir = Split-Path -Parent $OutputPath
  if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

  $ffmpegLog = "$OutputPath.ffmpeg.log"

  $ffmpegArgs = @(
    '-y','-hide_banner','-nostdin',
    '-f','dshow','-i', "audio=$SystemAudioDevice",
    '-f','dshow','-i', "audio=$MicrophoneDevice",
    '-filter_complex','[1:a]volume=2.0[mic];[0:a][mic]amix=inputs=2:duration=longest:dropout_transition=2:weights=1 2[a]',
    '-map','[a]','-acodec','libmp3lame','-q:a','4',
    $OutputPath
  )
  $cmdLine = ($ffmpegArgs | ForEach-Object { Format-NativeArg $_ }) -join ' '

  Write-Log 'INFO' "Starting ffmpeg -> $OutputPath (stderr -> $ffmpegLog)"
  Write-Log 'DEBUG' "ffmpeg cmdline: $cmdLine"

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = 'ffmpeg.exe'
  $psi.Arguments              = $cmdLine
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  $psi.RedirectStandardError  = $true
  $psi.RedirectStandardOutput = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi

  if (-not $proc.Start()) {
    throw "Process.Start() returned false - ffmpeg konnte nicht gestartet werden"
  }

  Update-Lockfile -FfmpegPid $proc.Id
  Write-Log 'OK' "ffmpeg started, PID=$($proc.Id) - waiting for exit"

  # Streams async lesen damit Pipe-Buffer nicht blockt waehrend Aufnahme laeuft.
  # ffmpeg schreibt v.a. Progress nach stderr (mit \r ueberschrieben).
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()

  $proc.WaitForExit()
  $exitCode = $proc.ExitCode

  $stderrText = ''
  $stdoutText = ''
  try { $stderrText = $stderrTask.GetAwaiter().GetResult() } catch { $stderrText = "<stderr read failed: $($_.Exception.Message)>" }
  try { $stdoutText = $stdoutTask.GetAwaiter().GetResult() } catch { }

  try {
    $logContent = ''
    if ($stdoutText) { $logContent += "--- stdout ---`n$stdoutText`n" }
    $logContent += "--- stderr ---`n$stderrText"
    $logContent | Out-File -LiteralPath $ffmpegLog -Encoding utf8 -Force
  } catch {
    Write-Log 'WARN' "Could not write ffmpeg log $($ffmpegLog): $($_.Exception.Message)"
  }

  $stderrTail = ''
  if ($stderrText) {
    $lines = $stderrText -split "`r?`n" | Where-Object { $_ -ne '' }
    $stderrTail = ($lines | Select-Object -Last 5) -join ' | '
  }

  if ($exitCode -ne 0) {
    Write-Log 'ERROR' "ffmpeg exited with code $exitCode. stderr tail: $stderrTail"
  } else {
    Write-Log 'INFO' "ffmpeg exited cleanly (code 0)"
  }

  # Phase 1 der Pipeline-Toast-Sequenz: Aufnahme beendet (Text-only, kein
  # ProgressBar). process-recording.ps1 uebernimmt anschliessend denselben
  # Toast via gleichem UniqueIdentifier.
  Send-PipelineToast -Status 'Aufnahme beendet' -NoProgress

  exit 0
}
catch {
  $detail = ($_ | Out-String).Trim()
  Write-Log 'ERROR' "record-call.ps1 failed: $detail"
  Send-Toast -Title 'nextWAVE Recorder' -Message "Aufnahme-Start fehlgeschlagen: $($_.Exception.Message)"
  exit 1
}
