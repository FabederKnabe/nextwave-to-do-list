#Requires -Version 5.1
<#
  cleanup-old-tasks.ps1

  Einmalig nach Merge ausfuehren. Migration weg vom alten Mo/Mi-Push-Task
  hin zur neuen On-Demand-Pipeline (Watcher + Self-Scheduling-Retry).

  Entfernt:
    - "nextWAVE Push Patches" (alter Dauer-Push-Task, Mo/Mi 18:00)
    - "nextWAVE Push Retry"   (Retry-Task aus neuem System, falls vorhanden)

  Aufruf (keine Admin-Rechte noetig fuer User-Tasks):
    powershell -ExecutionPolicy Bypass -File scripts\cleanup-old-tasks.ps1
#>

$ErrorActionPreference = 'Continue'

$tasksToRemove = @(
  'nextWAVE Push Patches'
  'nextWAVE Push Retry'
)

foreach ($name in $tasksToRemove) {
  $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if ($task) {
    try {
      Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
      Write-Host "Removed scheduled task: $name" -ForegroundColor Green
    } catch {
      Write-Host "Failed to remove '$name': $($_.Exception.Message)" -ForegroundColor Yellow
    }
  } else {
    Write-Host "Task not found (already clean): $name" -ForegroundColor DarkGray
  }
}

# Counter-File aus altem/neuem System aufraeumen
$counterFile = 'C:\Videocalls\output\patches\.retry_count'
if (Test-Path -LiteralPath $counterFile) {
  Remove-Item -LiteralPath $counterFile -Force -ErrorAction SilentlyContinue
  Write-Host "Removed retry counter file." -ForegroundColor Green
}

Write-Host ""
Write-Host "Migration done. Watcher-Setup mit scripts\record\setup-call-watcher.ps1 starten." -ForegroundColor Cyan
