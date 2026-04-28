# nextWAVE Digital — E-Mail Pipeline

## Kontext
Fabian schickt E-Mail-Text direkt als Nachricht in Cowork.
Das Ergebnis wird in C:\Videocalls\output\master.json gespeichert.

---

## Trigger
Wenn Fabian eine Nachricht schickt die mit "E-Mail:" oder "Neue E-Mail:" beginnt,
oder wenn er sagt "verarbeite diese E-Mail".

---

## Schritt 1 — Analysieren

Analysiere den E-Mail-Text. Es handelt sich um E-Mails zwischen Fabian und Iris (nextWAVE Digital / craftmaster.io).
Falls mehrere E-Mails (getrennt durch --- oder Leerzeilen): jede separat analysieren.

## Schritt 2 — master.json aktualisieren

Lies C:\Videocalls\output\master.json und füge neue Einträge HINZU (niemals löschen).

**Format:**
```json
{
  "todos": [
    {
      "id": "email-YYYYMMDD-001",
      "text": "Kurze prägnante Aufgabenbeschreibung",
      "kontext": "Ausführlicher Kontext — mind. 2-3 Sätze. Was genau ist zu tun, warum, was war der Hintergrund?",
      "deadline": null,
      "person": "fabian oder iris",
      "quelle": "E-Mail DD.MM.YYYY"
    }
  ],
  "offene_punkte": [
    {
      "id": "email-YYYYMMDD-001",
      "text": "Offener Punkt",
      "kontext": "Ausführlicher Kontext",
      "quelle": "E-Mail DD.MM.YYYY"
    }
  ],
  "themen": [
    {
      "id": "email-YYYYMMDD-001",
      "titel": "Thema — prägnant und klar",
      "details": "Was wurde erwähnt, welche Entscheidungen getroffen? Mind. 2-3 Sätze.",
      "quelle": "E-Mail DD.MM.YYYY"
    }
  ]
}
```

**Wichtige Regeln:**
- `quelle` Format: immer "E-Mail DD.MM.YYYY" — dieses Feld wird als Datum in der App angezeigt
- `todos.text`: kurz und aktionsorientiert (max. 1 Zeile)
- `todos.kontext`: ausführlich — Fabian muss am nächsten Tag noch verstehen worum es geht
- `themen.titel`: prägnant, klar, max. 1 Zeile
- `themen.details`: inhaltlich vollständig, mind. 2-3 Sätze
- Sprache: immer Deutsch
- IDs: email-YYYYMMDD-001, email-YYYYMMDD-002 usw.
- `zuletzt_aktualisiert` auf aktuelles Datum/Uhrzeit setzen

## Schritt 3 — Fertig melden
- Anzahl neuer To-dos, offene Punkte, Themen
- "To Do Liste im Browser neu laden"

---

## Wichtige Hinweise
- C:\Videocalls als freigegebener Ordner in Cowork
- Neue Einträge HINZUFÜGEN, bestehende NIEMALS löschen
- Sprache: Deutsch
