# nextWAVE Digital — E-Mail Pipeline

## Kontext
Fabian schickt E-Mail-Text direkt als Nachricht in Cowork.
Extrahierte Daten (Todos, offene Punkte, Themen) schreibt Cowork als
Patch-Datei nach `C:\Videocalls\output\patches\` — ein separater
Windows-Scheduled-Task pusht sie dann nach Supabase.

`master.json` existiert nicht mehr. Alle gemeinsamen Daten leben in der
Spalte `master_data` der Tabelle `todo_data` (Row `id=1`) in Supabase.

**Cowork hat keinen Internet-Zugriff** → kein direkter API-Call.
Alle Schreibvorgänge laufen über das Push-Script (`scripts/push-patches.ps1`),
das via Scheduled Task Mo/Mi 18:00 Uhr läuft. E-Mail-Patches können
zwischendurch geschrieben werden und bleiben einfach in der Queue liegen,
bis der nächste Push-Task-Lauf sie abholt.
Setup-Doku siehe `docs/cowork/scheduled-task-setup.md`.

---

## Trigger
Wenn Fabian eine Nachricht schickt, die mit `E-Mail:` oder `Neue E-Mail:` beginnt,
oder wenn er sagt „verarbeite diese E-Mail".

---

## Schritt 1 — Analysieren

Analysiere den E-Mail-Text. Es handelt sich um E-Mails zwischen Fabian und Iris (nextWAVE Digital / craftmaster.io).
Falls mehrere E-Mails (getrennt durch `---` oder Leerzeilen): jede separat analysieren und zu denselben Listen hinzufügen.

Sprache: **immer Deutsch**.

**ID-Vergabe:**
Format `email-YYYYMMDD-NNN`. `YYYYMMDD` = heutiges Datum. `NNN` = laufende Nummer ab `001`,
über alle drei Listen gemeinsam hochzählen (Todos + offene Punkte + Themen teilen sich den Zähler pro Tag).

**Eintrags-Schemas:**

```json
// todos
{
  "id": "email-YYYYMMDD-NNN",
  "text": "Kurze prägnante Aufgabenbeschreibung",
  "kontext": "Ausführlicher Kontext — mind. 2-3 Sätze. Was genau ist zu tun, warum, was war der Hintergrund?",
  "deadline": null,
  "person": "fabian oder iris",
  "quelle": "E-Mail DD.MM.YYYY"
}

// offene_punkte
{
  "id": "email-YYYYMMDD-NNN",
  "text": "Offener Punkt",
  "kontext": "Ausführlicher Kontext — warum offen, was fehlt noch?",
  "quelle": "E-Mail DD.MM.YYYY"
}

// themen
{
  "id": "email-YYYYMMDD-NNN",
  "titel": "Thema — prägnant und klar",
  "details": "Was wurde erwähnt, welche Entscheidungen getroffen? Mind. 2-3 Sätze.",
  "quelle": "E-Mail DD.MM.YYYY"
}
```

**Regeln:**
- `quelle` Format immer `E-Mail DD.MM.YYYY` — wird in der App als Datum angezeigt.
- `todos.text` kurz und aktionsorientiert (max. 1 Zeile).
- `todos.kontext` ausführlich — Fabian muss am nächsten Tag noch verstehen worum es geht.
- `themen.titel` prägnant, max. 1 Zeile.
- `themen.details` inhaltlich vollständig, mind. 2-3 Sätze.

---

## Schritt 2 — Patch-Datei schreiben

Schreibe die neuen Einträge nach
```
C:\Videocalls\output\patches\YYYYMMDD-HHMMSS.json
```
(Datei-Zeitstempel = Zeitpunkt des Schreibens. Beispiel: `20260429-211758.json`.
Falls der Ordner nicht existiert, anlegen.)

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

---

## Schritt 3 — Fertig melden
- Anzahl neuer Einträge je Liste (Todos / offene Punkte / Themen).
- Pfad der geschriebenen Patch-Datei.
- Hinweis: „Patch wartet auf den nächsten Push-Task-Lauf (Mo/Mi 18:00) — kann bis dahin liegen bleiben."

---

## Wichtige Hinweise
- C:\Videocalls als freigegebener Ordner in Cowork.
- Patches **nicht** ändern oder löschen, nachdem sie geschrieben wurden — das Push-Script verschiebt sie selbst nach `done\` oder `failed\`.
- `master.json` existiert nicht mehr — alle Daten leben in Supabase `todo_data` Row `id=1`.
- Sprache: immer Deutsch.
