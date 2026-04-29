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
       Bei Fehler          → Datei nach failed\ + Logeintrag

  Endpoint hardcoded.
  Service-Role-Key wird aus User-Env-Var SUPABASE_SERVICE_ROLE_KEY gelesen.

  Aufruf via Scheduled Task — siehe docs\cowork\scheduled-task-setup.md.
#>

$ErrorActionPreference = 'Stop'

# --- Konfiguration ---
$BaseDir   = 'C:\Videocalls\output\patches'
$DoneDir   = Join-Path $BaseDir 'done'
$FailedDir = Join-Path $BaseDir 'failed'
$LogFile   = Join-Path $BaseDir 'push-patches.log'

$ProjectURL = 'https://eufqqvatktwzyrjzrhoi.supabase.co'
$Endpoint   = "$ProjectURL/rest/v1/todo_data?id=eq.1"

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

# --- Vorbereitung ---
foreach ($d in @($BaseDir, $DoneDir, $FailedDir)) {
  if (-not (Test-Path -LiteralPath $d)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
  }
}

if (-not $ServiceKey) {
  Write-Log 'ERROR' 'SUPABASE_SERVICE_ROLE_KEY env var not set. Aborting.'
  exit 1
}

$baseHeaders = @{
  'apikey'        = $AnonKey
  'Authorization' = "Bearer $ServiceKey"
}

$patches = Get-ChildItem -LiteralPath $BaseDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $patches -or $patches.Count -eq 0) {
  Write-Log 'INFO' 'No patches to process.'
  exit 0
}

Write-Log 'INFO' "Found $($patches.Count) patch(es) to process."

# --- Hauptschleife ---
foreach ($file in $patches) {
  try {
    # 1. Patch lesen
    $patchJson = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    $patch = $patchJson | ConvertFrom-Json

    # 2. Aktuellen master_data holen
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

    # 3. Arrays konkatenieren
    $now = Get-Date -Format 'dd.MM.yyyy HH:mm'
    $stamp = if ($patch.zuletzt_aktualisiert) { [string]$patch.zuletzt_aktualisiert } else { $now }

    $mergedTodos  = @((ConvertTo-Array $current.todos)         + (ConvertTo-Array $patch.todos))
    $mergedOffen  = @((ConvertTo-Array $current.offene_punkte) + (ConvertTo-Array $patch.offene_punkte))
    $mergedThemen = @((ConvertTo-Array $current.themen)        + (ConvertTo-Array $patch.themen))

    $merged = [ordered]@{
      todos                = $mergedTodos
      offene_punkte        = $mergedOffen
      themen               = $mergedThemen
      zuletzt_aktualisiert = $stamp
    }

    $body = [ordered]@{
      master_data          = $merged
      zuletzt_aktualisiert = $stamp
    } | ConvertTo-Json -Depth 20 -Compress

    # 4. PATCH abschicken
    $patchHeaders = @{
      'apikey'        = $AnonKey
      'Authorization' = "Bearer $ServiceKey"
      'Content-Type'  = 'application/json'
      'Prefer'        = 'return=minimal'
    }

    Invoke-WebRequest -Method Patch `
      -Uri $Endpoint `
      -Headers $patchHeaders `
      -Body $body `
      -UseBasicParsing | Out-Null

    # 5. Erfolg → nach done\
    Move-Item -LiteralPath $file.FullName -Destination (Join-Path $DoneDir $file.Name) -Force

    $tCount = (ConvertTo-Array $patch.todos).Count
    $oCount = (ConvertTo-Array $patch.offene_punkte).Count
    $hCount = (ConvertTo-Array $patch.themen).Count
    Write-Log 'OK' "$($file.Name): +$tCount todos, +$oCount offene_punkte, +$hCount themen"
  }
  catch {
    $errMsg = $_.Exception.Message
    $statusInfo = ''
    if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
      try { $statusInfo = " (HTTP $([int]$_.Exception.Response.StatusCode))" } catch {}
    } elseif ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      try { $statusInfo = " (HTTP $([int]$_.Exception.Response.StatusCode))" } catch {}
    }

    if (Test-Path -LiteralPath $file.FullName) {
      try {
        Move-Item -LiteralPath $file.FullName -Destination (Join-Path $FailedDir $file.Name) -Force
      } catch {
        Write-Log 'ERROR' "Could not move $($file.Name) to failed\: $($_.Exception.Message)"
      }
    }
    Write-Log 'FAIL' "$($file.Name)$statusInfo  $errMsg"
  }
}
