#Requires -Version 5.1
<#
  setup-scheduled-task.ps1

  Registriert den Scheduled Task "nextWAVE Push Patches".
  In Admin-PowerShell ausführen:
    & C:\nextWAVE\nextwave-to-do-list\scripts\setup-scheduled-task.ps1

  Trigger: Mo + Mi je 18:00, wiederholt alle 30 Min für 2 Std.
  Aktion:  push-patches.ps1 hidden, höchste Rechte, ohne Profil.
#>

$ErrorActionPreference = 'Stop'

# Pfad zum Push-Script — relativ zum Speicherort dieser Datei
$ScriptPath = Join-Path $PSScriptRoot 'push-patches.ps1'
$TaskName   = 'nextWAVE Push Patches'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "FEHLER: push-patches.ps1 nicht gefunden unter $ScriptPath" -ForegroundColor Red
    exit 1
}

# Admin-Check
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "FEHLER: Bitte PowerShell als Administrator starten." -ForegroundColor Red
    exit 1
}

$RunAt = (Get-Date).Date.AddHours(18)

# Action via Splatting (keine langen Zeilen)
$ActionArgs = @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-WindowStyle', 'Hidden'
    '-File', "`"$ScriptPath`""
) -join ' '

$ActionParams = @{
    Execute  = 'powershell.exe'
    Argument = $ActionArgs
}
$Action = New-ScheduledTaskAction @ActionParams

# Repetition-Stub (alle 30 Min für 2h)
$RepStubParams = @{
    Once                = $true
    At                  = (Get-Date)
    RepetitionInterval  = (New-TimeSpan -Minutes 30)
    RepetitionDuration  = (New-TimeSpan -Hours 2)
}
$RepStub    = New-ScheduledTaskTrigger @RepStubParams
$Repetition = $RepStub.Repetition

# Wochentriger Mo / Mi
$TriggerMonParams = @{ Weekly = $true; DaysOfWeek = 'Monday';    At = $RunAt }
$TriggerMon = New-ScheduledTaskTrigger @TriggerMonParams
$TriggerMon.Repetition = $Repetition

$TriggerWedParams = @{ Weekly = $true; DaysOfWeek = 'Wednesday'; At = $RunAt }
$TriggerWed = New-ScheduledTaskTrigger @TriggerWedParams
$TriggerWed.Repetition = $Repetition

# Settings
$SettingsParams = @{
    Hidden               = $true
    StartWhenAvailable   = $true
    ExecutionTimeLimit   = (New-TimeSpan -Minutes 15)
    MultipleInstances    = 'IgnoreNew'
}
$Settings = New-ScheduledTaskSettingsSet @SettingsParams

# Principal: angemeldeter User mit höchsten Rechten
$PrincipalParams = @{
    UserId     = $env:USERNAME
    LogonType  = 'Interactive'
    RunLevel   = 'Highest'
}
$Principal = New-ScheduledTaskPrincipal @PrincipalParams

# Registrieren
$RegisterParams = @{
    TaskName    = $TaskName
    Action      = $Action
    Trigger     = @($TriggerMon, $TriggerWed)
    Settings    = $Settings
    Principal   = $Principal
    Description = 'Push Cowork-Patches nach Supabase (Mo/Mi 18:00, alle 30 Min fuer 2h)'
    Force       = $true
}
Register-ScheduledTask @RegisterParams | Out-Null

Write-Host ""
Write-Host "Task '$TaskName' erfolgreich registriert." -ForegroundColor Green
Write-Host ""
$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ("  State    : {0}" -f $task.State)
Write-Host ("  NextRun  : {0}" -f $info.NextRunTime)
Write-Host ("  Action   : {0} {1}" -f $task.Actions[0].Execute, $task.Actions[0].Arguments)
Write-Host ""
Write-Host "Manueller Testlauf jetzt:" -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Get-Content 'C:\Videocalls\output\patches\push-patches.log' -Tail 5"
