# nextWAVE Digital — E-Mail Pipeline

## Kontext
Fabian schickt E-Mail-Text direkt als Nachricht in Cowork.
Extrahierte Daten (Todos, offene Punkte, Themen) werden direkt in die Supabase-Datenbank
geschrieben — die App nextwave-to-do-list.netlify.app zeigt sie live an (Realtime-Sync).

`master.json` existiert nicht mehr. Alle gemeinsamen Daten leben in der Spalte
`master_data` der Tabelle `todo_data` (Row `id=1`).

---

## Trigger
Wenn Fabian eine Nachricht schickt, die mit `E-Mail:` oder `Neue E-Mail:` beginnt,
oder wenn er sagt „verarbeite diese E-Mail".

---

## Supabase-Setup (einmalig pro Cowork-Maschine)

### Endpoints
| Aktion | Methode | URL |
|---|---|---|
| Lesen | `GET`  | `https://eufqqvatktwzyrjzrhoi.supabase.co/rest/v1/todo_data?id=eq.1&select=master_data` |
| Schreiben | `PATCH` | `https://eufqqvatktwzyrjzrhoi.supabase.co/rest/v1/todo_data?id=eq.1` |

### Headers (alle Requests)
```
apikey:        <SUPABASE_ANON_KEY>
Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>
Content-Type:  application/json
Prefer:        return=minimal     (nur bei PATCH)
```

### Keys als User-Umgebungsvariablen hinterlegen
Einmalig in PowerShell ausführen:
```powershell
[Environment]::SetEnvironmentVariable('SUPABASE_ANON_KEY', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV1ZnFxdmF0a3R3enlyanpyaG9pIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc0MDY2OTUsImV4cCI6MjA5Mjk4MjY5NX0.JaFG4n3Y223H7EsCxiD3skHdaNmnKU8yNHHQ6D3ZErU', 'User')
[Environment]::SetEnvironmentVariable('SUPABASE_SERVICE_ROLE_KEY', '<SERVICE_ROLE_KEY_HIER>', 'User')
```

- `SUPABASE_ANON_KEY` = Dashboard → Project Settings → API → "anon public" (öffentlich, steht auch in `index.html`).
- `SUPABASE_SERVICE_ROLE_KEY` = Dashboard → Project Settings → API → "service_role" — **geheim**, niemals loggen oder in Chat einfügen.

Nach dem Setzen PowerShell schließen + neu öffnen, damit `$env:SUPABASE_*` greifen.

---

## Schritt 1 — Analysieren

Analysiere den E-Mail-Text. Es handelt sich um E-Mails zwischen Fabian und Iris (nextWAVE Digital / craftmaster.io).
Falls mehrere E-Mails (getrennt durch `---` oder Leerzeilen): jede separat analysieren und zu denselben Listen hinzufügen.

---

## Schritt 2 — Bestehende Daten lesen (GET)

```powershell
curl.exe -s "https://eufqqvatktwzyrjzrhoi.supabase.co/rest/v1/todo_data?id=eq.1&select=master_data" `
  -H "apikey: $env:SUPABASE_ANON_KEY" `
  -H "Authorization: Bearer $env:SUPABASE_SERVICE_ROLE_KEY" `
  -o C:\Videocalls\output\current.json
```

Antwort-Format (Array mit einem Objekt):
```json
[{"master_data": {"todos": [...], "offene_punkte": [...], "themen": [...], "zuletzt_aktualisiert": "..."}}]
```

Extrahiere `master_data`. Falls leer/null: starte mit
`{ "todos": [], "offene_punkte": [], "themen": [] }`.

---

## Schritt 3 — Neue Einträge bauen

**ID-Vergabe:**
Format `email-YYYYMMDD-NNN`. `YYYYMMDD` = heutiges Datum. `NNN` = laufende Nummer ab `001`.
Höchste bereits vergebene Nummer von **heute** über alle drei Listen finden, dann +1 weiterzählen.
Beispiel: bestehen `email-20260429-001` und `email-20260429-002`, beginnt der nächste neue Eintrag mit `email-20260429-003`.

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
- **Niemals** bestehende Einträge ändern oder löschen — nur HINZUFÜGEN.

---

## Schritt 4 — Mergen und PATCH

Baue das gemergte `master_data`-Objekt:
```json
{
  "todos":         [<alle bisherigen>, <neue>],
  "offene_punkte": [<alle bisherigen>, <neue>],
  "themen":        [<alle bisherigen>, <neue>],
  "zuletzt_aktualisiert": "DD.MM.YYYY HH:MM"
}
```

Schreibe den PATCH-Body nach `C:\Videocalls\output\patch.json`:
```json
{
  "master_data": <gemergtes Objekt von oben>,
  "zuletzt_aktualisiert": "DD.MM.YYYY HH:MM"
}
```

Hinweis: `zuletzt_aktualisiert` wird **zweimal** gesetzt — einmal als eigene DB-Spalte
(wird primär ausgelesen) und einmal innerhalb von `master_data` (Fallback).

PATCH abschicken:
```powershell
curl.exe -s -w "%{http_code}`n" -X PATCH "https://eufqqvatktwzyrjzrhoi.supabase.co/rest/v1/todo_data?id=eq.1" `
  -H "apikey: $env:SUPABASE_ANON_KEY" `
  -H "Authorization: Bearer $env:SUPABASE_SERVICE_ROLE_KEY" `
  -H "Content-Type: application/json" `
  -H "Prefer: return=minimal" `
  --data-binary "@C:\Videocalls\output\patch.json"
```

**Erwarteter Status: `204`** (kein Body wegen `Prefer: return=minimal`).
Bei `4xx`/`5xx`: NICHT blind erneut senden. Antwort-Body anzeigen, abbrechen, Fabian benachrichtigen.

---

## Schritt 5 — Fertig melden
- Anzahl neuer Einträge je Liste (Todos / offene Punkte / Themen).
- Hinweis: „Browser aktualisiert sich automatisch (Realtime-Sync) — kein manueller Reload nötig."

---

## Wichtige Hinweise
- C:\Videocalls als freigegebener Ordner in Cowork (für patch.json / current.json).
- `master.json` existiert nicht mehr — alle Daten leben in Supabase `todo_data` Row `id=1`.
- Neue Einträge HINZUFÜGEN, bestehende NIEMALS löschen oder ändern.
- Service-Role-Key ist GEHEIM — nicht in Logs/Transkripte/Chats einbauen.
- Sprache: immer Deutsch.
