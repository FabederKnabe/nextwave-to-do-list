# Call-Recorder Setup

Vollautomatische Aufnahme + Pipeline fuer Mailbox-Meet-Calls auf Fabis Surface.

```
Scheduled Task (AtLogon)
        │
        ▼
watcher-supervisor.ps1  ──► startet watch-mailbox-call.ps1 als Subprocess
        │                   restartet automatisch bei jedem Exit (5s Pause)
        ▼
Edge-Tab meet.mailbox.org ──► Watcher erkennt ──► record-call.ps1 (ffmpeg)
                                                         │
                                                  Edge-Tab zu
                                                         │
                                          process-recording.ps1
                                                         │
        transcribe.py ── summarize-call.py ── extract-action-items.py
                                                         │
                                       JSON-Patch → push-patches.ps1 → Supabase
                                                         │
                                                Toast + done/
```

Push-Architektur: kein Dauer-Task. push-patches.ps1 laeuft sofort nach Extract.
Bei Fehler: scheduled sich selbst (5min, 30min, 2h) und entfernt den Retry-Task,
sobald `patches\` leer ist.

## Voraussetzungen

- **ffmpeg** (via `winget install --id=Gyan.FFmpeg` oder Chocolatey), in PATH
- **Screen Capturer Recorder** (liefert das DShow-Device `virtual-audio-capturer`):
  https://github.com/rdp/screen-capture-recorder-to-video-windows-free
- **Python 3.14** unter `C:\Python314\python.exe`
- Python-Pakete:
  ```
  C:\Python314\python.exe -m pip install faster-whisper google-genai
  ```
- **PowerShell-Modul BurntToast** (Toast-Notifications):
  ```
  Install-Module BurntToast -Force -Scope CurrentUser
  ```
- **Env-Variablen** (User-Scope):
  ```
  setx GEMINI_API_KEY "..."
  setx SUPABASE_SERVICE_ROLE_KEY "..."
  ```
- **Whisper-Modell** `large-v3-turbo` (laedt automatisch beim ersten Aufruf)

## Migration von alter Pipeline

Einmalig nach Merge ausfuehren:

```powershell
& C:\nextWAVE\nextwave-to-do-list\scripts\cleanup-old-tasks.ps1
```

Entfernt den alten Task `nextWAVE Push Patches` (Mo/Mi 18:00) und ggf.
vorhandene Reste vom neuen Retry-Task.

Die produktive `C:\Videocalls\transcribe.py` mit dem Inhalt von
`scripts\record\transcribe.py` ueberschreiben (large-v3-turbo + Chunking):

```powershell
Copy-Item C:\nextWAVE\nextwave-to-do-list\scripts\record\transcribe.py C:\Videocalls\transcribe.py -Force
```

## Installation

```powershell
# Als Admin
& C:\nextWAVE\nextwave-to-do-list\scripts\record\setup-call-watcher.ps1
```

Registriert `nextWAVE Call Watcher` als Scheduled Task. Trigger AtLogon,
laeuft hidden im Hintergrund. Ab naechstem Login automatisch aktiv.

Sofort starten ohne neuen Login:

```powershell
Start-ScheduledTask -TaskName 'nextWAVE Call Watcher'
```

## Push-Architektur

- **Pipeline-Ende:** `process-recording.ps1` ruft `push-patches.ps1` SYNCHRON auf.
  In Sekunden ist der Patch in Supabase.
- **Bei Fehler / Netzwerk weg:** `push-patches.ps1` legt One-Shot Task
  `nextWAVE Push Retry` an. Counter (`C:\Videocalls\output\patches\.retry_count`)
  steuert Backoff: 5min → 30min → 2h. Nach Runde 3 Toast "Push fehlgeschlagen".
- **`patches\` leer:** Retry-Task + Counter werden automatisch entfernt.
- **Kein Dauer-Polling-Task.** Nur der Watcher laeuft permanent (sehr lightweight).

## Manueller Test der Pipeline

Eine bereits vorhandene MP3 vollstaendig durch die Pipeline schicken:

```powershell
& C:\nextWAVE\nextwave-to-do-list\scripts\record\process-recording.ps1 `
  -Mp3Path 'C:\Videocalls\YYYYMMDD-HHMMSS.mp3'
```

Einzelne Stufen testen:

```powershell
# Transkription
C:\Python314\python.exe C:\Videocalls\transcribe.py 'C:\Videocalls\test.mp3'

# Summary (Stufe 1)
C:\Python314\python.exe `
  C:\nextWAVE\nextwave-to-do-list\scripts\record\summarize-call.py `
  'C:\Videocalls\test.txt'

# Extract (Stufe 2)
C:\Python314\python.exe `
  C:\nextWAVE\nextwave-to-do-list\scripts\record\extract-action-items.py `
  'C:\Videocalls\test_summary.md'

# Push manuell
& C:\nextWAVE\nextwave-to-do-list\scripts\push-patches.ps1
```

## Logs

| Log | Pfad |
|---|---|
| Supervisor    | `C:\Videocalls\watcher-supervisor.log` |
| Watcher       | `C:\Videocalls\watcher.log` |
| Aufnahme      | `C:\Videocalls\record.log` |
| Pipeline      | `C:\Videocalls\process.log` |
| Push          | `C:\Videocalls\output\patches\push-patches.log` |

## Troubleshooting

**Audio-Geraete pruefen:**
```powershell
ffmpeg -list_devices true -f dshow -i dummy
```
Erwartete Eintraege:
- `"virtual-audio-capturer"`
- `"Mikrofonarray (Realtek High Definition Audio)"`

**Watcher haengt / Lockfile stehengeblieben:**
```powershell
Remove-Item C:\Videocalls\.recording.lock -Force
Restart-ScheduledTask -TaskName 'nextWAVE Call Watcher'
```

**Watcher stirbt staendig:**
`watcher-supervisor.log` zeigt Restart-Counter und Exit-Codes. Wenn
`run #N` schnell hochzaehlt: Ursache in `watcher.log` (TICK-Eintraege,
Trap-Eintraege, ERROR-Zeilen). Supervisor restartet automatisch alle 5s.

**Retry-Task manuell stoppen/loeschen:**
```powershell
Unregister-ScheduledTask -TaskName 'nextWAVE Push Retry' -Confirm:$false
Remove-Item C:\Videocalls\output\patches\.retry_count -Force
```

Retry sofort ausloesen:
```powershell
Start-ScheduledTask -TaskName 'nextWAVE Push Retry'
```

**BurntToast nicht installiert:**
```powershell
Install-Module BurntToast -Force -Scope CurrentUser
```
Pipeline laeuft auch ohne, dann ohne Toasts.

**Aufnahme leer (< 1 KB):**
Pipeline bricht ab, Toast meldet "Aufnahme fehlgeschlagen oder leer".
Mp3 in `C:\Videocalls\` pruefen, dann manuell loeschen.

## Re-Install nach Update

Wenn `watcher-supervisor.ps1` oder `setup-call-watcher.ps1` geaendert wurden,
muss der Task neu registriert werden:

```powershell
# als Admin
Stop-ScheduledTask -TaskName 'nextWAVE Call Watcher' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*watcher-supervisor*' -or $_.CommandLine -like '*watch-mailbox-call*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
& C:\nextWAVE\nextwave-to-do-list\scripts\record\setup-call-watcher.ps1
Start-ScheduledTask -TaskName 'nextWAVE Call Watcher'
```

## Deinstallation

```powershell
# Watcher entfernen
Unregister-ScheduledTask -TaskName 'nextWAVE Call Watcher' -Confirm:$false

# Retry-Task entfernen falls vorhanden
Unregister-ScheduledTask -TaskName 'nextWAVE Push Retry' -Confirm:$false -ErrorAction SilentlyContinue

# Lockfile + Retry-Counter
Remove-Item C:\Videocalls\.recording.lock -Force -ErrorAction SilentlyContinue
Remove-Item C:\Videocalls\output\patches\.retry_count -Force -ErrorAction SilentlyContinue
```
