#Requires -Version 5.1
<#
  push-patches.ps1

  Liest Patch-JSONs aus C:\Videocalls\output\patches\ und pusht sie nach Supabase.

  Pro Datei:
    1. Patch-JSON lesen (enthält neue todos / offene_punkte / themen)
    2. Aktuellen master_data aus Supabase holen (GET)
    3. Arrays konkatenieren (current + patch)
    4. PATCH gegen todo_data Row id=1
    5. Bei Erfolg (HTTP 204) → Datei nach done\
       Bei Fehler          → siehe Retry/Failed-Logik unten

  Retry-Logik:
    - 5xx / Timeout / WebException ohne Response: 3 Retries (2s, 5s, 10s)
    - 429: 3 Retries (5s, 15s, 30s)
    - 4xx ausser 429: kein Retry, direkt failed\
    - Netzwerk weg (DNS / NameResolutionFailure): Datei bleibt liegen, naechste Datei

  Self-Scheduling:
    - Wenn nach Lauf noch *.json in patches\: One-Shot Task "nextWAVE Push Retry"
      Counter (5min, 30min, 2h). Nach 3 Runden: Toast + Counter reset.
    - Wenn patches\ leer: Counter-File + Retry-Task entfernen.

  Silent-Exit: keine Patches, kein Log, kein Toast, exit 0.

  Endpoint hardcoded. Service-Role-Key aus User-Env-Var SUPABASE_SERVICE_ROLE_KEY.
#>

$ErrorActionPreference = 'Stop'

# --- Konfiguration ---
$BaseDir    = 'C:\Videocalls\output\patches'
$DoneDir    = Join-Path $BaseDir 'done'
$FailedDir  = Join-Path $BaseDir 'failed'
$LogFile    = Join-Path $BaseDir 'push-patches.log'
$CounterFile = Join-Path $BaseDir '.retry_count'
$RetryTaskName = 'nextWAVE Push Retry'

$ProjectURL = 'https://eufqqvatktwzyrjzrhoi.supabase.co'
$Endpoint   = "$ProjectURL/rest/v1/todo_data?id=eq.1"
$SupabaseHost = 'eufqqvatktwzyrjzrhoi.supabase.co'

# Anon-Key ist öffentlich (siehe index.html), darf hardcoded sein.
$AnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV1ZnFxdmF0a3R3enlyanpyaG9pIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc0MDY2OTUsImV4cCI6MjA5Mjk4MjY5NX0.JaFG4n3Y223H7EsCxiD3skHdaNmnKU8yNHHQ6D3ZErU'

$ServiceKey = $env:SUPABASE_SERVICE_ROLE_KEY

# --- Helpers ---
function Write-Log {
  param([string]$Level, [string]$Message)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  "[$ts] $Level $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function ConvertTo-Array {
  param($Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return $Value }
  return ,$Value
}

function Test-NetworkAvailable {
  try {
    $null = [System.Net.Dns]::GetHostEntry($SupabaseHost)
    return $true
  } catch {
    return $false
  }
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

function Get-HttpStatusFromError {
  param($ErrorRecord)
  try {
    if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
      return [int]$ErrorRecord.Exception.Response.StatusCode
    }
  } catch { }
  return 0
}

function Get-HttpErrorBody {
  param($ErrorRecord)
  try {
    $resp = $ErrorRecord.Exception.Response
    if (-not $resp) { return '' }
    $stream = $resp.GetResponseStream()
    if (-not $stream) { return '' }
    try { $stream.Position = 0 } catch { }
    $reader = New-Object System.IO.StreamReader($stream)
    $body = $reader.ReadToEnd()
    try { $reader.Dispose() } catch { }
    return ($body -replace '\s+', ' ').Trim()
  } catch {
    return ''
  }
}

function Test-NetworkError {
  param($ErrorRecord)
  if ($ErrorRecord.Exception -is [System.Net.WebException]) {
    $st = $ErrorRecord.Exception.Status
    if ($st -eq [System.Net.WebExceptionStatus]::NameResolutionFailure) { return $true }
    if ($st -eq [System.Net.WebExceptionStatus]::ConnectFailure) { return $true }
  }
  return -not (Test-NetworkAvailable)
}

function Get-RetryCount {
  if (Test-Path -LiteralPath $CounterFile) {
    try { return [int](Get-Content -LiteralPath $CounterFile -Raw).Trim() } catch { return 0 }
  }
  return 0
}

function Set-RetryCount {
  param([int]$Value)
  $Value | Out-File -LiteralPath $CounterFile -Encoding ascii -Force
}

function Remove-RetryCount {
  if (Test-Path -LiteralPath $CounterFile) { Remove-Item -LiteralPath $CounterFile -Force }
}

function Remove-RetryTask {
  try {
    if (Get-ScheduledTask -TaskName $RetryTaskName -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $RetryTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
  } catch { }
}

function Register-RetryTask {
  param([int]$DelayMinutes)
  Remove-RetryTask
  $scriptPath = $MyInvocation.MyCommand.Path
  if (-not $scriptPath) { $scriptPath = $PSCommandPath }
  $argLine = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$scriptPath`"") -join ' '
  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($DelayMinutes)
  $settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $RetryTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'On-demand Retry for push-patches.ps1' -Force | Out-Null
}

function Invoke-PatchUpload {
  param([string]$FilePath, [string]$FileName)

  $patchJson = Get-Content -LiteralPath $FilePath -Raw -Encoding utf8
  $patch = $patchJson | ConvertFrom-Json

  $baseHeaders = @{
    'apikey'        = $AnonKey
    'Authorization' = "Bearer $ServiceKey"
  }

  $resp = Invoke-RestMethod -Method Get `
    -Uri "$Endpoint&select=master_data" `
    -Headers $baseHeaders

  $current = $null
  if ($resp -and $resp.Count -ge 1) { $current = $resp[0].master_data }
  if (-not $current) {
    $current = [PSCustomObject]@{
      todos         = @()
      offene_punkte = @()
      themen        = @()
    }
  }

  $now = Get-Date -Format 'dd.MM.yyyy HH:mm'
  $stamp = if ($patch.zuletzt_aktualisiert) { [string]$patch.zuletzt_aktualisiert } else { $now }

  $mergedTodos  = @((ConvertTo-Array $current.todos)         + (ConvertTo-Array $patch.todos))
  $mergedOffen  = @((ConvertTo-Array $current.offene_punkte) + (ConvertTo-Array $patch.offene_punkte))
  $mergedThemen = @((ConvertTo-Array $current.themen)        + (ConvertTo-Array $patch.themen))

  $merged = @{
    todos                = $mergedTodos
    offene_punkte        = $mergedOffen
    themen               = $mergedThemen
    zuletzt_aktualisiert = $stamp
  }

  # Nur master_data als Top-Level-Key senden. Das zuletzt_aktualisiert
  # gehoert NUR ins master_data-JSON, nicht als eigene Tabellenspalte -
  # PostgREST lehnt ein doppeltes Top-Level-Feld mit HTTP 400 ab.
  $body = @{ master_data = $merged } | ConvertTo-Json -Depth 20 -Compress

  # Body explizit als UTF-8 Bytes senden. Invoke-WebRequest mit String-Body
  # codet in PS 5.1 default als ISO-8859-1 wenn der Content-Type kein
  # charset enthaelt - deutsche Umlaute in Transcripts werden dann zu
  # Mojibake und Supabase antwortet mit PGRST102 "Empty or invalid json".
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

  $preview = if ($body.Length -gt 300) { $body.Substring(0, 300) + '...' } else { $body }
  Write-Log 'DEBUG' "PATCH body chars=$($body.Length) bytes=$($bodyBytes.Length) preview=$preview"

  $patchHeaders = @{
    'apikey'        = $AnonKey
    'Authorization' = "Bearer $ServiceKey"
    'Content-Type'  = 'application/json; charset=utf-8'
    'Prefer'        = 'return=minimal'
  }

  Invoke-WebRequest -Method Patch `
    -Uri $Endpoint `
    -Headers $patchHeaders `
    -Body $bodyBytes `
    -UseBasicParsing | Out-Null

  return @{
    Todos = (ConvertTo-Array $patch.todos).Count
    Offen = (ConvertTo-Array $patch.offene_punkte).Count
    Themen = (ConvertTo-Array $patch.themen).Count
  }
}

# --- Vorbereitung ---
foreach ($d in @($BaseDir, $DoneDir, $FailedDir)) {
  if (-not (Test-Path -LiteralPath $d)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
  }
}

# Silent-Exit wenn keine Patches
$patches = Get-ChildItem -LiteralPath $BaseDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $patches -or $patches.Count -eq 0) {
  Remove-RetryCount
  Remove-RetryTask
  exit 0
}

if (-not $ServiceKey) {
  Write-Log 'ERROR' 'SUPABASE_SERVICE_ROLE_KEY env var not set. Aborting.'
  exit 1
}

Write-Log 'INFO' "Found $($patches.Count) patch(es) to process."

$networkFailedFiles = 0

# --- Hauptschleife ---
foreach ($file in $patches) {
  $attempt = 0
  $maxAttempts = 3
  $success = $false
  $lastError = $null
  $lastStatus = 0
  $isNetworkFail = $false

  while ($attempt -lt $maxAttempts -and -not $success) {
    $attempt++
    try {
      if (-not (Test-NetworkAvailable)) {
        $isNetworkFail = $true
        break
      }
      $counts = Invoke-PatchUpload -FilePath $file.FullName -FileName $file.Name
      $success = $true
      Move-Item -LiteralPath $file.FullName -Destination (Join-Path $DoneDir $file.Name) -Force
      Write-Log 'OK' "$($file.Name): +$($counts.Todos) todos, +$($counts.Offen) offene_punkte, +$($counts.Themen) themen"
    }
    catch {
      $lastError = $_
      $lastStatus = Get-HttpStatusFromError $_

      if (Test-NetworkError $_) {
        $isNetworkFail = $true
        break
      }

      # 4xx (ohne 429) -> kein Retry
      if ($lastStatus -ge 400 -and $lastStatus -lt 500 -and $lastStatus -ne 429) {
        break
      }

      # Backoff bestimmen
      $backoff = 0
      if ($lastStatus -eq 429) {
        switch ($attempt) { 1 { $backoff = 5 } 2 { $backoff = 15 } 3 { $backoff = 30 } }
      } else {
        switch ($attempt) { 1 { $backoff = 2 } 2 { $backoff = 5 } 3 { $backoff = 10 } }
      }

      if ($attempt -lt $maxAttempts) {
        Write-Log 'WARN' "$($file.Name): attempt $attempt failed (HTTP $lastStatus) - retry in ${backoff}s"
        Start-Sleep -Seconds $backoff
      }
    }
  }

  if (-not $success) {
    if ($isNetworkFail) {
      $networkFailedFiles++
      Write-Log 'NET' "$($file.Name): network unavailable, file left in patches\"
      # Datei bleibt liegen - keine weiteren Versuche in dieser Schleife
      break
    } else {
      $errMsg = if ($lastError) { $lastError.Exception.Message } else { 'unknown error' }
      $statusInfo = if ($lastStatus -gt 0) { " (HTTP $lastStatus)" } else { '' }
      $respBody = if ($lastError) { Get-HttpErrorBody $lastError } else { '' }
      $bodyInfo = if ($respBody) { " body=$respBody" } else { '' }
      try {
        Move-Item -LiteralPath $file.FullName -Destination (Join-Path $FailedDir $file.Name) -Force
      } catch {
        Write-Log 'ERROR' "Could not move $($file.Name) to failed\: $($_.Exception.Message)"
      }
      Write-Log 'FAIL' "$($file.Name)$statusInfo  $errMsg$bodyInfo"
    }
  }
}

# --- Self-Scheduling ---
$remaining = Get-ChildItem -LiteralPath $BaseDir -Filter '*.json' -File -ErrorAction SilentlyContinue
if ($remaining -and $remaining.Count -gt 0) {
  $count = Get-RetryCount
  $count++
  $schedule = @{
    1 = @{ Delay = 5;   Label = '5 minutes' }
    2 = @{ Delay = 30;  Label = '30 minutes' }
    3 = @{ Delay = 120; Label = '2 hours' }
  }

  if ($count -ge 4) {
    Send-Toast -Title 'nextWAVE Push' -Message 'Push fehlgeschlagen - bitte manuell pruefen'
    Write-Log 'ERROR' "Retry exhausted after 3 rounds. $($remaining.Count) file(s) remain. Counter reset."
    Remove-RetryCount
    Remove-RetryTask
  } else {
    $entry = $schedule[$count]
    Set-RetryCount -Value $count
    try {
      Register-RetryTask -DelayMinutes $entry.Delay
      Write-Log 'INFO' "$($remaining.Count) file(s) remain. Retry $count scheduled in $($entry.Label)."
    } catch {
      Write-Log 'ERROR' "Could not schedule retry task: $($_.Exception.Message)"
    }
  }
} else {
  Remove-RetryCount
  Remove-RetryTask
  Write-Log 'INFO' 'All patches processed. Retry state cleared.'
}
