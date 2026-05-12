#Requires -Version 5.1
<#
  setup-call-watcher.ps1

  Registriert "nextWAVE Call Watcher" als Scheduled Task.
    Trigger : AtLogon (angemeldeter User)
    Action  : watch-mailbox-call.ps1 (hidden, NoProfile, Bypass)
    Restart : alle 1 Min, max 5 Versuche
    Hidden  : ja, StartWhenAvailable

  Admin-Rechte erforderlich.

  Aufruf:
    powershell -ExecutionPolicy Bypass -File scripts\record\setup-call-watcher.ps1
#>

$ErrorActionPreference = 'Stop'

$TaskName    = 'nextWAVE Call Watcher'
$ScriptPath  = Join-Path $PSScriptRoot 'watch-mailbox-call.ps1'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
  Write-Host "FEHLER: watch-mailbox-call.ps1 nicht gefunden unter $ScriptPath" -ForegroundColor Red
  exit 1
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host "FEHLER: Bitte PowerShell als Administrator starten." -ForegroundColor Red
  exit 1
}

$ActionArgs = @(
  '-NoProfile'
  '-ExecutionPolicy', 'Bypass'
  '-WindowStyle', 'Hidden'
  '-File', "`"$ScriptPath`""
) -join ' '

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $ActionArgs

$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$Settings = New-ScheduledTaskSettingsSet `
  -Hidden `
  -StartWhenAvailable `
  -RestartCount 5 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit ([TimeSpan]::Zero)

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
  -Description 'nextWAVE Call Watcher: erkennt Mailbox-Meet-Tab im Edge, steuert Aufnahme und Pipeline.' `
  -Force | Out-Null

Write-Host ""
Write-Host "Task '$TaskName' erfolgreich registriert." -ForegroundColor Green
Write-Host ""
$task = Get-ScheduledTask -TaskName $TaskName
Write-Host ("  State    : {0}" -f $task.State)
Write-Host ("  Action   : {0} {1}" -f $task.Actions[0].Execute, $task.Actions[0].Arguments)
Write-Host ""
Write-Host "Watcher startet beim naechsten Login automatisch." -ForegroundColor Cyan
Write-Host "Sofort starten:" -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Get-Content 'C:\Videocalls\watcher.log' -Tail 10 -Wait"
