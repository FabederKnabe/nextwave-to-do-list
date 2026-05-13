#Requires -Version 5.1
<#
  process-recording.ps1

  Vollautomatische Pipeline NACH Aufnahme:
    1. transcribe.py        -> <basename>.txt
    2. summarize-call.py    -> <basename>_summary.md  (Stufe 1, Gemini)
    3. extract-action-items.py -> JSON (Stufe 2, Gemini)
    4. JSON-Validierung: leer -> private, archiviert, kein Push
    5. JSON nach C:\Videocalls\output\patches\YYYYMMDD-HHMMSS.json
    6. push-patches.ps1 SYNCHRON ausfuehren
    7. MP3 + TXT + Summary nach C:\Videocalls\done\
    8. Toast mit Pipeline-Ergebnis

  Aufruf:
    process-recording.ps1 -Mp3Path C:\Videocalls\YYYYMMDD-HHMMSS.mp3
#>

param(
  [Parameter(Mandatory = $true)] [string]$Mp3Path
)

$ErrorActionPreference = 'Continue'

$BaseDir       = 'C:\Videocalls'
$DoneDir       = Join-Path $BaseDir 'done'
$PrivateDir    = Join-Path $DoneDir 'private'
$PatchesDir    = Join-Path $BaseDir 'output\patches'
$LogFile       = Join-Path $BaseDir 'process.log'
$PythonExe     = 'C:\Python314\python.exe'
$TranscribePy  = 'C:\Videocalls\transcribe.py'
$SummarizePy   = Join-Path $PSScriptRoot 'summarize-call.py'
$ExtractPy     = Join-Path $PSScriptRoot 'extract-action-items.py'
$PushScript    = Join-Path $PSScriptRoot '..\push-patches.ps1'

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
  # wir UTF-8 - sonst landen deutsche Umlaute als Mojibake in den Patch-
  # JSONs (Replacement Character U+FFFD im Frontend).
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

try {
  if (-not (Test-Path -LiteralPath $Mp3Path)) {
    throw "MP3 not found: $Mp3Path"
  }

  foreach ($d in @($DoneDir, $PrivateDir, $PatchesDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  }

  $basename = [System.IO.Path]::GetFileNameWithoutExtension($Mp3Path)
  $txtPath = Join-Path $BaseDir "$basename.txt"
  $summaryPath = Join-Path $BaseDir "$basename`_summary.md"

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

  # --- 2. Summary (Stufe 1) ---
  Write-Log 'INFO' "[$basename] Summarize start"
  $r = Invoke-PythonScript -ScriptPath $SummarizePy -InputArg $txtPath
  if ($r.ExitCode -ne 0) {
    throw "summarize-call.py failed (exit $($r.ExitCode)): $($r.Stderr)"
  }
  if (-not (Test-Path -LiteralPath $summaryPath)) {
    throw "summarize-call.py did not produce $summaryPath"
  }
  Write-Log 'OK' "[$basename] Summarize done"

  # --- 3. Extract (Stufe 2) ---
  Write-Log 'INFO' "[$basename] Extract start"
  $r = Invoke-PythonScript -ScriptPath $ExtractPy -InputArg $summaryPath
  if ($r.ExitCode -ne 0) {
    throw "extract-action-items.py failed (exit $($r.ExitCode)): $($r.Stderr)"
  }
  $jsonText = $r.Stdout.Trim()
  if (-not $jsonText) {
    throw "extract-action-items.py returned empty stdout"
  }
  $parsed = $jsonText | ConvertFrom-Json
  Write-Log 'OK' "[$basename] Extract done"

  # --- 4. Leer-Check ---
  $tCount = @($parsed.todos).Count
  $oCount = @($parsed.offene_punkte).Count
  $hCount = @($parsed.themen).Count

  if ($tCount -eq 0 -and $oCount -eq 0 -and $hCount -eq 0) {
    Write-Log 'INFO' "[$basename] Empty patch - archiving as private"
    foreach ($f in @($Mp3Path, $txtPath, $summaryPath)) {
      if (Test-Path -LiteralPath $f) {
        Move-Item -LiteralPath $f -Destination $PrivateDir -Force -ErrorAction SilentlyContinue
      }
    }
    Send-Toast -Title 'nextWAVE Pipeline' -Message 'Kein relevanter Inhalt - vermutlich privater Call. Audio archiviert.'
    exit 0
  }

  # --- 5. JSON-Patch schreiben ---
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $patchPath = Join-Path $PatchesDir "$stamp.json"
  $jsonText | Out-File -LiteralPath $patchPath -Encoding utf8 -Force
  Write-Log 'OK' "[$basename] Patch written -> $patchPath"

  # --- 6. push-patches.ps1 synchron ---
  Write-Log 'INFO' "[$basename] Push start"
  $pushResolved = Resolve-Path -LiteralPath $PushScript
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pushResolved.Path
  $pushExit = $LASTEXITCODE
  $pushStatus = if ($pushExit -eq 0) { 'erfolgreich' } else { 'in Retry' }
  Write-Log 'INFO' "[$basename] Push exit=$pushExit ($pushStatus)"

  # --- 7. Dateien nach done\ ---
  foreach ($f in @($Mp3Path, $txtPath, $summaryPath)) {
    if (Test-Path -LiteralPath $f) {
      Move-Item -LiteralPath $f -Destination $DoneDir -Force -ErrorAction SilentlyContinue
    }
  }

  # --- 8. Toast ---
  Send-Toast -Title 'nextWAVE Pipeline' `
    -Message "Call verarbeitet - $tCount Todos, $oCount offene Punkte, $hCount Themen | Push: $pushStatus"
  Write-Log 'OK' "[$basename] Pipeline complete: $tCount todos, $oCount offen, $hCount themen, push=$pushStatus"
}
catch {
  $msg = $_.Exception.Message
  Write-Log 'ERROR' "Pipeline failed: $msg"
  Send-Toast -Title 'nextWAVE Pipeline' -Message "Fehler: $msg"
  exit 1
}
