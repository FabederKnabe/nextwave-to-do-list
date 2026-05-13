#Requires -Version 5.1
<#
  record-call.ps1

  Startet ffmpeg-Aufnahme (Systemaudio + Mikrofon, gemixt) und traegt
  ffmpeg-PID ins Lockfile (JSON) nach.

  Parameter:
    -OutputPath   Ziel-MP3 (z.B. C:\Videocalls\20260101-180000.mp3)
    -LockfilePath Pfad des Lockfiles (z.B. C:\Videocalls\.recording.lock)

  Aufruf erfolgt vom Watcher als detached PowerShell-Prozess.
  ffmpeg laeuft danach selbststaendig weiter; Watcher killt es spaeter
  per Stop-Process auf die in $LockfilePath hinterlegte ffmpeg_pid.

  Geraete (hardcoded, exakte Windows-DShow-Namen):
    Systemaudio: "virtual-audio-capturer"
    Mikrofon   : "Mikrofonarray (Realtek High Definition Audio)"

  Robustheit:
    - Beide Geraete fehlen   -> Toast Fehler, Abbruch
    - Nur Systemaudio da     -> nimmt nur Systemaudio auf (kein amix)
    - Nur Mikro da           -> nimmt nur Mikro auf (selten)
#>

param(
  [Parameter(Mandatory = $true)] [string]$OutputPath,
  [Parameter(Mandatory = $true)] [string]$LockfilePath
)

$ErrorActionPreference = 'Stop'

$LogFile = 'C:\Videocalls\record.log'
$SysDevice = 'virtual-audio-capturer'
$MicDevice = 'Mikrofonarray (Realtek High Definition Audio)'

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

function Get-AudioDevices {
  # ffmpeg -list_devices schreibt alles nach stderr und exitet mit Code 1.
  # In PowerShell 5.1 wandelt "2>&1" jede stderr-Zeile in einen NativeCommandError.
  # Mit $ErrorActionPreference='Stop' wird die erste solche Zeile terminierend,
  # daher hier lokal auf 'Continue' setzen.
  $prevPref = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = (& ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String)
  } finally {
    $ErrorActionPreference = $prevPref
  }
  $lines = $output -split "`r?`n"
  $devices = New-Object System.Collections.Generic.List[string]
  $audioSection = $false
  foreach ($line in $lines) {
    if ($line -match 'DirectShow audio devices') { $audioSection = $true; continue }
    if ($line -match 'DirectShow video devices') { $audioSection = $false; continue }
    if ($audioSection -and $line -match '"([^"]+)"') {
      $name = $matches[1]
      if ($devices -notcontains $name) { $devices.Add($name) }
    }
  }
  return $devices
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
  $devices = Get-AudioDevices
  $hasSys = $devices -contains $SysDevice
  $hasMic = $devices -contains $MicDevice
  Write-Log 'INFO' "Devices: sys=$hasSys mic=$hasMic"

  if (-not $hasSys -and -not $hasMic) {
    Send-Toast -Title 'nextWAVE Recorder' -Message 'Beide Audio-Geraete fehlen - Aufnahme abgebrochen'
    Write-Log 'ERROR' 'Both audio devices missing - abort'
    exit 1
  }

  $outDir = Split-Path -Parent $OutputPath
  if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

  $ffArgs = @('-y','-hide_banner','-nostdin')

  if ($hasSys -and $hasMic) {
    # Mikro pre-amix verstaerken (volume=2.0), dann amix mit weights System=1 Mikro=2
    $filterComplex = '[1:a]volume=2.0[mic];[0:a][mic]amix=inputs=2:duration=longest:dropout_transition=2:weights=1 2[a]'
    $ffArgs += @(
      '-f','dshow','-i',"audio=$SysDevice",
      '-f','dshow','-i',"audio=$MicDevice",
      '-filter_complex',$filterComplex,
      '-map','[a]'
    )
  } elseif ($hasSys) {
    $ffArgs += @('-f','dshow','-i',"audio=$SysDevice")
    Write-Log 'WARN' 'Mic missing - recording system audio only'
  } else {
    $ffArgs += @('-f','dshow','-i',"audio=$MicDevice")
    Write-Log 'WARN' 'System audio missing - recording mic only'
  }

  $ffArgs += @('-acodec','libmp3lame','-q:a','4',$OutputPath)

  # ffmpeg-stderr in eigene Logdatei umlenken, damit Crashes nachvollziehbar sind.
  $ffmpegLog = "$OutputPath.ffmpeg.log"
  Write-Log 'INFO' "Starting ffmpeg -> $OutputPath (stderr -> $ffmpegLog)"
  Write-Log 'DEBUG' ("ffmpeg args: " + ($ffArgs -join ' '))
  $proc = Start-Process -FilePath 'ffmpeg' `
    -ArgumentList $ffArgs `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardError $ffmpegLog
  Update-Lockfile -FfmpegPid $proc.Id
  Write-Log 'OK' "ffmpeg started, PID=$($proc.Id)"
  exit 0
}
catch {
  $detail = ($_ | Out-String).Trim()
  Write-Log 'ERROR' "record-call.ps1 failed: $detail"
  Send-Toast -Title 'nextWAVE Recorder' -Message "Aufnahme-Start fehlgeschlagen: $($_.Exception.Message)"
  exit 1
}
