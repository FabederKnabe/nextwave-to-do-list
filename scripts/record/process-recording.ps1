#Requires -Version 5.1
<#
  process-recording.ps1

  TEMP: Gemini-Pipeline reaktiviert (Test gemini-2.5-pro).
  Skripte liegen in scripts/record/_unused/ - werden von hier referenziert,
  nicht zurueckkopiert. Push deaktiviert - JSON nur lokal zur Inspektion.
  Bei schlechtem Output: diese Datei revertn.

  Pipeline NACH Aufnahme (TEST-Modus):
    1. transcribe.py        -> <basename>.txt
    2. summarize-call.py    -> <basename>_summary.md  (Stufe 1, Gemini 2.5 Pro, _unused/)
    3. extract-action-items.py -> JSON (Stufe 2, Gemini 2.5 Pro, _unused/)
    4. JSON-Validierung: leer -> private, archiviert
    5. JSON nach C:\Videocalls\output\patches\YYYYMMDD-HHMMSS.json (kein Push!)
    6. Push DEAKTIVIERT
    7. MP3 + TXT + Summary nach C:\Videocalls\done\
    8. Toast: "Call verarbeitet (TEST) - ..."

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
$SummarizePy   = Join-Path $PSScriptRoot '_unused\summarize-call.py'
$ExtractPy     = Join-Path $PSScriptRoot '_unused\extract-action-items.py'
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

Import-Module "$PSScriptRoot\pipeline-toast.psm1" -Force

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

  # --- 1. Transkription (mit Live-Progress via PROGRESS:-Zeilen auf stdout) ---
  Write-Log 'INFO' "[$basename] Transcribe start"
  Send-PipelineToast -Status 'Transkribierung startet...' -ProgressValue 0.0 -ValueDisplay '0%'

  # transcribe.py wird hier - im Gegensatz zu summarize/extract - NICHT ueber
  # Invoke-PythonScript gestartet, weil wir stdout zeilenweise live lesen
  # muessen (PROGRESS:<float>-Zeilen pro Whisper-Segment).
  $tPsi = New-Object System.Diagnostics.ProcessStartInfo
  $tPsi.FileName               = $PythonExe
  $tPsi.Arguments              = "`"$TranscribePy`" `"$Mp3Path`""
  $tPsi.UseShellExecute        = $false
  $tPsi.CreateNoWindow         = $true
  $tPsi.RedirectStandardOutput = $true
  $tPsi.RedirectStandardError  = $true
  $tPsi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $tPsi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
  $tPsi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'

  $tProc = New-Object System.Diagnostics.Process
  $tProc.StartInfo = $tPsi
  [void]$tProc.Start()

  # stderr async einsammeln (Pipe-Buffer darf nicht blocken)
  $tStderrTask = $tProc.StandardError.ReadToEndAsync()
  $tStdoutBuf  = New-Object System.Text.StringBuilder
  $invariant   = [System.Globalization.CultureInfo]::InvariantCulture
  $numStyles   = [System.Globalization.NumberStyles]::Float

  while (-not $tProc.StandardOutput.EndOfStream) {
    $line = $tProc.StandardOutput.ReadLine()
    if ($null -eq $line) { break }
    if ($line.StartsWith('PROGRESS:')) {
      $valStr = $line.Substring(9).Trim()
      $val = 0.0
      if ([double]::TryParse($valStr, $numStyles, $invariant, [ref]$val)) {
        $pct = [int]([math]::Round($val * 100))
        Send-PipelineToast -Status 'Transkribierung läuft...' -ProgressValue $val -ValueDisplay "$pct%"
      }
    } else {
      [void]$tStdoutBuf.AppendLine($line)
    }
  }
  $tProc.WaitForExit()
  $tStderr = ''
  try { $tStderr = $tStderrTask.GetAwaiter().GetResult() } catch { $tStderr = '' }
  $tExit = $tProc.ExitCode

  if ($tExit -ne 0) {
    throw "transcribe.py failed (exit $tExit): $tStderr"
  }
  if (-not (Test-Path -LiteralPath $txtPath)) {
    throw "transcribe.py did not produce $txtPath"
  }
  Send-PipelineToast -Status 'Transkribierung beendet' -NoProgress
  Write-Log 'OK' "[$basename] Transcribe done"

  # --- 2. Summary (Stufe 1) ---
  Send-PipelineToast -Status 'Gemini verarbeitet...' -Indeterminate
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
    Send-PipelineToast -Status 'Kein relevanter Inhalt - vermutlich privater Call. Audio archiviert.' -NoProgress
    exit 0
  }

  # --- 5. JSON-Patch schreiben ---
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $patchPath = Join-Path $PatchesDir "$stamp.json"
  $jsonText | Out-File -LiteralPath $patchPath -Encoding utf8 -Force
  Write-Log 'OK' "[$basename] Patch written -> $patchPath"

  # --- 6. Push deaktiviert (TEST-Modus, JSON nur lokal inspizieren) ---
  Write-Log 'INFO' "[$basename] Push skipped (TEST mode)"

  # --- 7. Dateien nach done\ ---
  foreach ($f in @($Mp3Path, $txtPath, $summaryPath)) {
    if (Test-Path -LiteralPath $f) {
      Move-Item -LiteralPath $f -Destination $DoneDir -Force -ErrorAction SilentlyContinue
    }
  }

  # --- 8. Toast (Fertig - aktualisiert denselben Pipeline-Toast) ---
  Send-PipelineToast `
    -Status "Call verarbeitet (TEST) - $tCount Todos, $oCount offene Punkte, $hCount Themen" `
    -NoProgress
  Write-Log 'OK' "[$basename] Pipeline complete (TEST): $tCount todos, $oCount offen, $hCount themen"
}
catch {
  $msg = $_.Exception.Message
  Write-Log 'ERROR' "Pipeline failed: $msg"
  Send-PipelineToast -Status "Fehler: $msg" -NoProgress
  exit 1
}
