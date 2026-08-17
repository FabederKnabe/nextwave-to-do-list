#Requires -Version 5.1
<#
  setup-call-watcher.ps1

  Registriert "nextWAVE Call Watcher" als Scheduled Task.
    Trigger : AtLogon (angemeldeter User)
    Action  : watcher-supervisor.ps1 (hidden, NoProfile, Bypass)
              -> startet watch-mailbox-call.ps1 als Subprocess
              -> restartet bei jedem Watcher-Exit (5s Pause)
    Restart : alle 1 Min, max 5 Versuche (Backup gegen Supervisor-Crash)
    Hidden  : ja, StartWhenAvailable
    Time-Limit: 9999h (effektiv unbegrenzt)

  Admin-Rechte erforderlich.

  Aufruf:
    powershell -ExecutionPolicy Bypass -File scripts\record\setup-call-watcher.ps1
#>

$ErrorActionPreference = 'Stop'

$TaskName    = 'nextWAVE Call Watcher'
$ScriptPath  = Join-Path $PSScriptRoot 'watcher-supervisor.ps1'
$WatcherPath = Join-Path $PSScriptRoot 'watch-mailbox-call.ps1'
$VbsLauncher = Join-Path $PSScriptRoot 'launch-supervisor.vbs'

foreach ($p in @($ScriptPath, $WatcherPath, $VbsLauncher)) {
  if (-not (Test-Path -LiteralPath $p)) {
    Write-Host "FEHLER: Script nicht gefunden: $p" -ForegroundColor Red
    exit 1
  }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host "FEHLER: Bitte PowerShell als Administrator starten." -ForegroundColor Red
  exit 1
}

# VBScript-Bootstrap statt direktem powershell.exe-Aufruf.
# Grund: PowerShell mit -WindowStyle Hidden stirbt unter AtLogon-Trigger
# silently (Exit 0, kein Log). wscript.exe + VBS hat kein Window-Lifecycle-
# Problem im Task-Scheduler-Kontext.
$ActionArgs = "`"$VbsLauncher`""

$Action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $ActionArgs

$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$Settings = New-ScheduledTaskSettingsSet `
  -Hidden `
  -StartWhenAvailable `
  -RestartCount 5 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Hours 9999)

# Akku-Flags aus: Surface laeuft oft auf Batterie, sonst Watcher tot
# nach Wake-from-Standby (siehe Incident 2026-05-28).
$Settings.DisallowStartIfOnBatteries = $false
$Settings.StopIfGoingOnBatteries = $false

$Principal = New-ScheduledTaskPrincipal `
  -UserId $env:USERNAME `
  -LogonType Interactive `
  -RunLevel Highest

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $Action `
  -Trigger $Trigger `
  -Settings $Settings `
  -Principal $Principal `
  -Description 'nextWAVE Call Watcher: Supervisor haelt watch-mailbox-call.ps1 dauerhaft am Leben (Browser-Fenstererkennung, Aufnahme, Pipeline).' `
  -Force | Out-Null

Write-Host ""
Write-Host "Task '$TaskName' erfolgreich registriert." -ForegroundColor Green
Write-Host ""
$task = Get-ScheduledTask -TaskName $TaskName
Write-Host ("  State    : {0}" -f $task.State)
Write-Host ("  Action   : {0} {1}" -f $task.Actions[0].Execute, $task.Actions[0].Arguments)
Write-Host ""
Write-Host "Supervisor startet beim naechsten Login automatisch." -ForegroundColor Cyan
Write-Host "Sofort starten:" -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Get-Content 'C:\Videocalls\watcher-supervisor.log' -Tail 10 -Wait"
Write-Host "  Get-Content 'C:\Videocalls\watcher.log' -Tail 10 -Wait"
