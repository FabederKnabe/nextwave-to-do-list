# nextWAVE Digital — Call Pipeline

## Kontext
Fabian nimmt Calls mit OBS auf. MP4 landet in C:\Videocalls.
Alle extrahierten Daten werden in C:\Videocalls\output\master.json gespeichert.

---

## Geplante Aufgabe — Montag + Mittwoch ab 17:00 Uhr

### Schritt 1 — Neue MP4 erkennen
Prüfe ob in C:\Videocalls eine MP4 liegt die heute erstellt wurde und noch nicht verarbeitet ist.
Falls keine: jede Minute erneut prüfen bis 18:00 Uhr, dann beenden.

### Schritt 2 — MP4 zu MP3
```
ffmpeg -y -i "C:\Videocalls\[DATEINAME].mp4" -vn -acodec libmp3lame -q:a 2 "C:\Videocalls\output\[DATEINAME].mp3"
```

### Schritt 3 — Transkribieren
```
C:\Python314\python.exe C:\Videocalls\transcribe.py "C:\Videocalls\output\[DATEINAME].mp3"
```

### Schritt 4 — Analysieren und master.json aktualisieren

Lies das Transkript und extrahiere Daten im folgenden Format.
Lies dann C:\Videocalls\output\master.json und füge die neuen Einträge HINZU (niemals löschen).

**Format master.json:**
```json
{
  "zuletzt_aktualisiert": "DD.MM.YYYY HH:MM",
  "todos": [
    {
      "id": "call-YYYYMMDD-001",
      "text": "Kurze prägnante Aufgabenbeschreibung",
      "kontext": "Ausführlicher Kontext — mind. 2-3 Sätze. Was genau ist zu tun, warum, was war der Hintergrund?",
      "deadline": null,
      "person": "fabian oder iris",
      "quelle": "Call DD.MM.YYYY"
    }
  ],
  "offene_punkte": [
    {
      "id": "call-YYYYMMDD-001",
      "text": "Offener Punkt",
      "kontext": "Ausführlicher Kontext — warum offen, was fehlt noch?",
      "quelle": "Call DD.MM.YYYY"
    }
  ],
  "themen": [
    {
      "id": "call-YYYYMMDD-001",
      "titel": "Thema — prägnant und klar",
      "details": "Was wurde besprochen, welche Entscheidungen getroffen? Mind. 2-3 Sätze.",
      "quelle": "Call DD.MM.YYYY"
    }
  ]
}
```

**Wichtige Regeln:**
- `quelle` Format: immer "Call DD.MM.YYYY" — dieses Feld wird als Datum in der App angezeigt
- `todos.text`: kurz und aktionsorientiert (max. 1 Zeile)
- `todos.kontext`: ausführlich — Fabian muss am nächsten Tag noch verstehen worum es geht
- `themen.titel`: prägnant, klar, max. 1 Zeile
- `themen.details`: inhaltlich vollständig, mind. 2-3 Sätze
- Sprache: immer Deutsch
- IDs: call-YYYYMMDD-001, call-YYYYMMDD-002 usw.

### Schritt 5 — Fertig melden
- Anzahl neuer To-dos, offene Punkte, Themen
- "To Do Liste im Browser neu laden"

---

## Wichtige Hinweise
- C:\Videocalls und C:\Users\user\.cache\huggingface\hub als freigegebene Ordner in Cowork
- C:\Python314\python.exe für alle Python-Aufrufe
- Neue Einträge HINZUFÜGEN, bestehende NIEMALS löschen oder ändern
