# nextWAVE Digital — Call Pipeline

## Kontext
Fabian nimmt Calls mit OBS auf. MP4 landet in C:\Videocalls.
Transkripte gehen nach C:\Videocalls\output\ (MP3 + TXT).
Extrahierte Daten (Todos, offene Punkte, Themen) schreibt Cowork als
Patch-Datei nach `C:\Videocalls\output\patches\` — ein separater
Windows-Scheduled-Task pusht sie dann nach Supabase.

`master.json` existiert nicht mehr. Alle gemeinsamen Daten leben in der
Spalte `master_data` der Tabelle `todo_data` (Row `id=1`) in Supabase.

**Cowork hat keinen Internet-Zugriff** → kein direkter API-Call.
Alle Schreibvorgänge laufen über das Push-Script (`scripts/push-patches.ps1`),
das via Scheduled Task Mo/Mi 18:00 Uhr läuft (Setup-Doku siehe
`docs/cowork/scheduled-task-setup.md`).

---

## Geplante Aufgabe — Montag + Mittwoch ab 17:00 Uhr

### Schritt 1 — Neue MP4 erkennen
Prüfe ob in C:\Videocalls eine MP4 liegt, die heute erstellt wurde und noch nicht verarbeitet ist.
Falls keine: jede Minute erneut prüfen bis 18:00 Uhr, dann beenden.

### Schritt 2 — MP4 zu MP3
```
ffmpeg -y -i "C:\Videocalls\[DATEINAME].mp4" -vn -acodec libmp3lame -q:a 2 "C:\Videocalls\output\[DATEINAME].mp3"
```

### Schritt 3 — Transkribieren
```
C:\Python314\python.exe C:\Videocalls\transcribe.py "C:\Videocalls\output\[DATEINAME].mp3"
```

`transcribe.py` liest das Whisper-Medium-Modell **direkt** aus
`C:\Users\user\.cache\huggingface\hub\...` (kein Kopieren — das sprengt jede
Sandbox). Das Audio wird vor der Transkription mit ffmpeg in 10-Minuten-Stücke
gesplittet, jedes Segment einzeln transkribiert und anschließend gelöscht. Das
hält den Speicherbedarf konstant niedrig und vermeidet FUSE-Crashes bei großen
MP3-Dateien.

Falls `faster-whisper` in der Sandbox installiert werden muss: immer mit
`pip install --no-cache-dir faster-whisper` arbeiten und danach
`pip cache purge` aufrufen, damit der pip-Cache nicht zusätzlich Speicher
auffrisst.

### Schritt 4 — Transkript analysieren

Lies C:\Videocalls\output\[DATEINAME].txt und extrahiere neue Einträge.
Sprache: **immer Deutsch**.

**ID-Vergabe:**
Format `call-YYYYMMDD-NNN`. `YYYYMMDD` = heutiges Datum. `NNN` = laufende Nummer ab `001`,
über alle drei Listen gemeinsam hochzählen (Todos + offene Punkte + Themen teilen sich den Zähler pro Tag).

**Eintrags-Schemas:**

```json
// todos
{
  "id": "call-YYYYMMDD-NNN",
  "text": "Kurze prägnante Aufgabenbeschreibung",
  "kontext": "Ausführlicher Kontext — mind. 2-3 Sätze. Was genau ist zu tun, warum, was war der Hintergrund?",
  "deadline": null,
  "person": "fabian oder iris",
  "quelle": "Call DD.MM.YYYY"
}

// offene_punkte
{
  "id": "call-YYYYMMDD-NNN",
  "text": "Offener Punkt",
  "kontext": "Ausführlicher Kontext — warum offen, was fehlt noch?",
  "quelle": "Call DD.MM.YYYY"
}

// themen
{
  "id": "call-YYYYMMDD-NNN",
  "titel": "Thema — prägnant und klar",
  "details": "Was wurde besprochen, welche Entscheidungen getroffen? Mind. 2-3 Sätze.",
  "quelle": "Call DD.MM.YYYY"
}
```

**Regeln:**
- `quelle` Format immer `Call DD.MM.YYYY` — wird in der App als Datum angezeigt.
- `todos.text` kurz und aktionsorientiert (max. 1 Zeile).
- `todos.kontext` ausführlich — Fabian muss am nächsten Tag noch verstehen worum es geht.
- `themen.titel` prägnant, max. 1 Zeile.
- `themen.details` inhaltlich vollständig, mind. 2-3 Sätze.

### Schritt 5 — Patch-Datei schreiben

Schreibe die neuen Einträge nach
```
C:\Videocalls\output\patches\YYYYMMDD-HHMMSS.json
```
(Datei-Zeitstempel = Zeitpunkt des Schreibens, **nicht** der Call-Zeitpunkt.
Beispiel: `20260429-174203.json`. Falls der Ordner nicht existiert, anlegen.)

**Format der Patch-Datei** (nur die NEUEN Einträge, kein gemergtes Gesamtobjekt):
```json
{
  "todos": [<neue Todo-Einträge>],
  "offene_punkte": [<neue offene-Punkte-Einträge>],
  "themen": [<neue Themen-Einträge>],
  "zuletzt_aktualisiert": "DD.MM.YYYY HH:MM"
}
```

Leere Listen weglassen oder als `[]` schreiben — beides OK.

**Kein API-Call, kein curl.** Das Push-Script liest die Datei beim nächsten
Scheduled-Task-Lauf (Mo/Mi 18:00 Uhr, alle 30 min für 2h), holt den aktuellen
Stand aus Supabase, hängt die Patch-Einträge an und schickt das Ergebnis zurück.

### Schritt 6 — Fertig melden
- Anzahl neuer Einträge je Liste (Todos / offene Punkte / Themen).
- Pfad der geschriebenen Patch-Datei.
- Hinweis: „Patch wartet auf den nächsten Push-Task-Lauf — Browser aktualisiert sich danach automatisch (Realtime-Sync)."

---

## Wichtige Hinweise
- C:\Videocalls und C:\Users\user\.cache\huggingface\hub als freigegebene Ordner in Cowork.
- C:\Python314\python.exe für alle Python-Aufrufe.
- Patches **nicht** ändern oder löschen, nachdem sie geschrieben wurden — das Push-Script verschiebt sie selbst nach `done\` oder `failed\`.
- `master.json` existiert nicht mehr — alle Daten leben in Supabase `todo_data` Row `id=1`.
- Sprache: immer Deutsch.
