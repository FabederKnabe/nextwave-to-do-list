#Requires -Version 5.1
<#
  process-recording.ps1

  Pipeline NACH Aufnahme - Transkript-only Variante:
    1. transcribe.py        -> <basename>.txt  (Whisper)
    2. MP3-Metadata via ffprobe -> Dauer (Sekunden -> Minuten)
    3. Markdown-Transkript schreiben nach
       C:\Videocalls\done\transkripte\YYYY-MM-DD_HHMM_call-<timestamp>.md
    4. MP3 + TXT nach C:\Videocalls\done\
    5. Toast: "Transkript bereit zur Auswertung" + Pfad

  Auswertung passiert manuell im Claude-Projekt (Webchat). Pipeline endet
  hier - kein Gemini, kein Supabase-Push mehr. Siehe scripts/record/_unused/
  fuer die alten Summarize/Extract-Skripte (Wiederverwendung moeglich).

  Aufruf:
    process-recording.ps1 -Mp3Path C:\Videocalls\YYYYMMDD-HHMMSS.mp3
#>

param(
  [Parameter(Mandatory = $true)] [string]$Mp3Path
)

$ErrorActionPreference = 'Continue'

$BaseDir         = 'C:\Videocalls'
$DoneDir         = Join-Path $BaseDir 'done'
$TranscriptDir   = Join-Path $DoneDir 'transkripte'
$LogFile         = Join-Path $BaseDir 'process.log'
$PythonExe       = 'C:\Python314\python.exe'
$TranscribePy    = 'C:\Videocalls\transcribe.py'
$FfprobeExe      = 'ffprobe.exe'

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

function Invoke-PythonScript {
  param([string]$ScriptPath, [string]$InputArg)
  $tmpOut = [System.IO.Path]::GetTempFileName()
  $tmpErr = [System.IO.Path]::GetTempFileName()
  # Python-stdout/stderr unter Windows ist default cp1252. Hier erzwingen
  # wir UTF-8 - sonst landen deutsche Umlaute als Mojibake.
  $prevPyEnc = $env:PYTHONIOENCODING
  $env:PYTHONIOENCODING = 'utf-8'
  try {
    $proc = Start-Process -FilePath $PythonExe `
      -ArgumentList @("`"$ScriptPath`"", "`"$InputArg`"") `
      -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput $tmpOut `
      -RedirectStandardError $tmpErr
    $stdout = Get-Content -LiteralPath $tmpOut -Raw -Encoding utf8
    $stderr = Get-Content -LiteralPath $tmpErr -Raw -Encoding utf8
    return [PSCustomObject]@{
      ExitCode = $proc.ExitCode
      Stdout   = $stdout
      Stderr   = $stderr
    }
  } finally {
    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue
    $env:PYTHONIOENCODING = $prevPyEnc
  }
}

function Get-Mp3DurationMinutes {
  param([string]$Mp3Path)
  try {
    $out = & $FfprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- $Mp3Path 2>$null
    if (-not $out) { return $null }
    $secs = [double]$out
    return [int][Math]::Round($secs / 60.0)
  } catch {
    Write-Log 'WARN' "ffprobe duration failed: $($_.Exception.Message)"
    return $null
  }
}

function ConvertTo-DateTimeFromStamp {
  param([string]$Stamp)
  # Stamp = YYYYMMDD-HHMMSS aus Filename
  try {
    return [datetime]::ParseExact($Stamp, 'yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
  } catch {
    return $null
  }
}

try {
  if (-not (Test-Path -LiteralPath $Mp3Path)) {
    throw "MP3 not found: $Mp3Path"
  }

  foreach ($d in @($DoneDir, $TranscriptDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  }

  $basename = [System.IO.Path]::GetFileNameWithoutExtension($Mp3Path)
  $txtPath  = Join-Path $BaseDir "$basename.txt"

  # --- 1. Transkription ---
  Write-Log 'INFO' "[$basename] Transcribe start"
  $r = Invoke-PythonScript -ScriptPath $TranscribePy -InputArg $Mp3Path
  if ($r.ExitCode -ne 0) {
    throw "transcribe.py failed (exit $($r.ExitCode)): $($r.Stderr)"
  }
  if (-not (Test-Path -LiteralPath $txtPath)) {
    throw "transcribe.py did not produce $txtPath"
  }
  Write-Log 'OK' "[$basename] Transcribe done"

  # --- 2. Metadata: Datum/Uhrzeit aus Filename, Dauer aus MP3 ---
  $callTime = ConvertTo-DateTimeFromStamp -Stamp $basename
  if (-not $callTime) {
    Write-Log 'WARN' "[$basename] Could not parse timestamp from filename, using file mtime"
    $callTime = (Get-Item -LiteralPath $Mp3Path).LastWriteTime
  }
  $durationMin = Get-Mp3DurationMinutes -Mp3Path $Mp3Path

  # --- 3. MP3 + TXT nach done\ verschieben (MP3-Pfad wird im MD referenziert) ---
  $doneMp3 = Join-Path $DoneDir ([System.IO.Path]::GetFileName($Mp3Path))
  $doneTxt = Join-Path $DoneDir ([System.IO.Path]::GetFileName($txtPath))
  Move-Item -LiteralPath $Mp3Path -Destination $doneMp3 -Force -ErrorAction SilentlyContinue
  Move-Item -LiteralPath $txtPath -Destination $doneTxt -Force -ErrorAction SilentlyContinue

  # --- 4. Markdown-Transkript schreiben ---
  $transcriptText = ''
  if (Test-Path -LiteralPath $doneTxt) {
    $transcriptText = (Get-Content -LiteralPath $doneTxt -Raw -Encoding utf8).TrimEnd()
  }

  $mdName = ('{0:yyyy-MM-dd}_{0:HHmm}_call-{1}.md' -f $callTime, $basename)
  $mdPath = Join-Path $TranscriptDir $mdName

  $durationLine = if ($durationMin) { "$durationMin Min" } else { 'unbekannt' }

  $md = @"
# Call-Transkript

- **Datum:** $($callTime.ToString('dd.MM.yyyy'))
- **Uhrzeit:** $($callTime.ToString('HH:mm'))
- **Dauer:** $durationLine
- **MP3:** $doneMp3

---

## Transkript

$transcriptText
"@

  $md | Out-File -LiteralPath $mdPath -Encoding utf8 -Force
  Write-Log 'OK' "[$basename] Transkript-MD geschrieben -> $mdPath"

  # --- 5. Toast ---
  Send-Toast -Title 'nextWAVE Pipeline' `
    -Message "Transkript bereit zur Auswertung`n$mdPath"
  Write-Log 'OK' "[$basename] Pipeline complete -> $mdPath"
}
catch {
  $msg = $_.Exception.Message
  Write-Log 'ERROR' "Pipeline failed: $msg"
  Send-Toast -Title 'nextWAVE Pipeline' -Message "Fehler: $msg"
  exit 1
}
