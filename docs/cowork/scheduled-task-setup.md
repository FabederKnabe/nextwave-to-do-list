# Scheduled Task — Push Patches nach Supabase

Richtet einen Windows-Task ein, der `scripts\push-patches.ps1` auf der Cowork-Maschine
periodisch ausführt und die von Cowork geschriebenen Patch-JSONs nach Supabase pusht.

**Trigger:**
- **Montag** 18:00 Uhr — wiederholt alle 30 Min für 2 Std (also 18:00 / 18:30 / 19:00 / 19:30 / 20:00)
- **Mittwoch** 18:00 Uhr — gleicher Rhythmus

**Aktion:**
- PowerShell startet versteckt mit höchsten Rechten und ruft `push-patches.ps1` auf.

**Hintergrund zur Zeitwahl:** Calls mit Iris laufen Mo/Mi 16:00–17:05.
Cowork verarbeitet ab 17:00 (eigene Pipeline). Push-Task ab 18:00 gibt Cowork
genug Puffer zum Fertig-Sein. E-Mail-Patches können ad-hoc geschrieben werden
und liegen einfach bis zum nächsten Mo/Mi-Lauf in der Queue.

---

## Voraussetzungen

1. Pfad zum Script kennen, z.B. `C:\nextWAVE\nextwave-to-do-list\scripts\push-patches.ps1`.
2. Service-Role-Key als User-Umgebungsvariable hinterlegt:
   ```powershell
   [Environment]::SetEnvironmentVariable('SUPABASE_SERVICE_ROLE_KEY', '<KEY_HIER>', 'User')
   ```
   Findest du im Supabase-Dashboard → Project Settings → API → "service_role".
   **Geheim** — nicht in Repo, nicht in Logs einfügen.
3. PowerShell-Fenster nach dem Setzen der Env-Var einmal schließen + neu öffnen,
   damit der Task die Variable beim Start sieht.

---

## Variante A — per PowerShell-Cmdlets (empfohlen)

Die folgenden Befehle in einer **PowerShell-Sitzung als Administrator** ausführen.
Pfad ggf. anpassen.

```powershell
$ScriptPath = 'C:\nextWAVE\nextwave-to-do-list\scripts\push-patches.ps1'
$TaskName   = 'nextWAVE Push Patches'

# Aktion: PowerShell mit dem Push-Script, versteckt, ohne Profil-Loading
$Action = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

# Repetition (alle 30 Min für 2 Std) — Workaround: über einen einmaligen
# Trigger erzeugen und dann auf den Wochentags-Trigger anwenden.
$Repetition = (New-ScheduledTaskTrigger `
  -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 30) `
  -RepetitionDuration (New-TimeSpan -Hours 2)
).Repetition

$TriggerMon = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday    -At 18:00
$TriggerMon.Repetition = $Repetition

$TriggerWed = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Wednesday -At 18:00
$TriggerWed.Repetition = $Repetition

# Einstellungen: hidden, startet auch wenn Termin verpasst, max. 15 Min Laufzeit
$Settings = New-ScheduledTaskSettingsSet `
  -Hidden `
  -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
  -MultipleInstances IgnoreNew

# Als angemeldeter User mit höchsten Rechten
$Principal = New-ScheduledTaskPrincipal `
  -UserId $env:USERNAME `
  -LogonType Interactive `
  -RunLevel Highest

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $Action `
  -Trigger @($TriggerMon, $TriggerWed) `
  -Settings $Settings `
  -Principal $Principal `
  -Description 'Push Cowork-Patches nach Supabase (Mo/Mi 18:00, alle 30 Min für 2h)' `
  -Force
```

Verifikation: `Get-ScheduledTask -TaskName 'nextWAVE Push Patches' | Select-Object TaskName, State`

Manueller Testlauf: `Start-ScheduledTask -TaskName 'nextWAVE Push Patches'`

---

## Variante B — XML in den Task Scheduler importieren

Die folgende XML in eine Datei `push-patches-task.xml` speichern, **Pfad zum Script
in der `<Arguments>`-Zeile anpassen**, dann im Task Scheduler:
**Aktion → Aufgabe importieren** → Datei auswählen.

```xml
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Push Cowork-Patches nach Supabase (Mo/Mi 18:00, alle 30 Min fuer 2h)</Description>
    <URI>\nextWAVE Push Patches</URI>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-01-05T18:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT30M</Interval>
        <Duration>PT2H</Duration>
        <StopAtDurationEnd>true</StopAtDurationEnd>
      </Repetition>
      <ScheduleByWeek>
        <DaysOfWeek>
          <Monday />
        </DaysOfWeek>
        <WeeksInterval>1</WeeksInterval>
      </ScheduleByWeek>
    </CalendarTrigger>
    <CalendarTrigger>
      <StartBoundary>2026-01-07T18:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT30M</Interval>
        <Duration>PT2H</Duration>
        <StopAtDurationEnd>true</StopAtDurationEnd>
      </Repetition>
      <ScheduleByWeek>
        <DaysOfWeek>
          <Wednesday />
        </DaysOfWeek>
        <WeeksInterval>1</WeeksInterval>
      </ScheduleByWeek>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT15M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\nextWAVE\nextwave-to-do-list\scripts\push-patches.ps1"</Arguments>
    </Exec>
  </Actions>
</Task>
```

Beim Import fragt der Task Scheduler nach dem User-Account — angemeldeten User
auswählen, Häkchen bei „Mit höchsten Privilegien ausführen".

Wichtig: XML-Datei als **UTF-16 LE mit BOM** speichern (Notepad → „Speichern unter" →
Codierung „Unicode" oder PowerShell `Out-File -Encoding Unicode`). Sonst Import-Fehler.

---

## Manueller Testlauf

Sofort einmal laufen lassen, ohne auf Mo/Mi zu warten:

```powershell
# 1. Test-Patch erzeugen
$testPatch = @{
  todos = @(
    @{
      id       = 'test-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
      text     = 'Push-Patches Smoke Test'
      kontext  = 'Automatischer Test des Push-Scripts. Kann nach erfolgreichem Lauf manuell aus der App entfernt werden.'
      deadline = $null
      person   = 'fabian'
      quelle   = 'Test ' + (Get-Date -Format 'dd.MM.yyyy')
    }
  )
  zuletzt_aktualisiert = (Get-Date -Format 'dd.MM.yyyy HH:mm')
} | ConvertTo-Json -Depth 10

$dir = 'C:\Videocalls\output\patches'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$testPatch | Out-File -FilePath (Join-Path $dir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')) -Encoding utf8

# 2. Script direkt ausführen
& 'C:\nextWAVE\nextwave-to-do-list\scripts\push-patches.ps1'

# 3. Log-Datei lesen
Get-Content 'C:\Videocalls\output\patches\push-patches.log' -Tail 5
```

Erfolgreich, wenn:
- Log-Eintrag `OK <dateiname>: +1 todos, +0 offene_punkte, +0 themen`
- Datei in `C:\Videocalls\output\patches\done\` verschoben
- Test-Todo erscheint live in der App (Realtime-Sync)

---

## Troubleshooting

| Symptom | Wahrscheinliche Ursache |
|---|---|
| Task läuft, aber Log sagt `ERROR: SUPABASE_SERVICE_ROLE_KEY env var not set` | Env-Var fehlt oder nur in einer anderen Session gesetzt. User-Variable setzen, neu einloggen, oder Task im System-Kontext laufen lassen mit gespeicherten Credentials. |
| Log sagt `FAIL ... (HTTP 401)` | Service-Role-Key ungültig oder vertauscht mit Anon-Key. |
| Log sagt `FAIL ... (HTTP 403)` | RLS-Policy blockt Service-Role (sollte eigentlich nicht passieren — Service-Role bypasst RLS). Prüfen ob wirklich der Service-Role-Key gesetzt ist. |
| Log sagt `FAIL ... (HTTP 404)` | Endpoint-URL falsch. Erwartet: `https://eufqqvatktwzyrjzrhoi.supabase.co/rest/v1/todo_data?id=eq.1`. |
| Patches stapeln sich, kein Lauf | Task-State prüfen: `Get-ScheduledTask -TaskName 'nextWAVE Push Patches' \| Select State, NextRunTime`. „Disabled" oder „Ready" mit weiter Vergangenheit als NextRunTime → Task neu registrieren. |
| Datei in `failed\` mit unklarer Meldung | Log-Datei `push-patches.log` öffnen, der zugehörige `FAIL`-Eintrag enthält Exception-Message + HTTP-Status. |

---

## Aufräumen / Deinstallation

```powershell
Unregister-ScheduledTask -TaskName 'nextWAVE Push Patches' -Confirm:$false
```
