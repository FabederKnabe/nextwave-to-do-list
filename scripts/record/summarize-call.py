"""
summarize-call.py - Stufe 1 der Call-Pipeline

Liest TXT-Transkript, schickt an Gemini 2.5 Flash, schreibt
strukturierte Markdown-Zusammenfassung mit Call-Typ-Erkennung.

Aufruf:
    python summarize-call.py <transcript.txt>

Output:
    <basename>_summary.md (neben Input)
    Pfad der Summary-Datei nach stdout

Voraussetzung: GEMINI_API_KEY env var.
"""

import os
import sys
from datetime import datetime
from google import genai

API_KEY = os.environ.get('GEMINI_API_KEY')
if not API_KEY:
    print("ERROR: GEMINI_API_KEY env var not set", file=sys.stderr)
    sys.exit(1)

client = genai.Client(api_key=API_KEY)

transcript_path = sys.argv[1]
with open(transcript_path, 'r', encoding='utf-8') as f:
    transcript = f.read()

today = datetime.now().strftime('%d.%m.%Y')

PROMPT = f"""Du erstellst eine strukturierte Zusammenfassung eines Geschaefts-Calls fuer Fabian (CTO der nextWAVE Digital).

Erkenne ZUERST automatisch den Call-Typ:
- "geschaeftspartner" - Iris (CEO) oder andere interne/Partner-Calls
- "kunde" - externe Kundengespraeche, Akquise, Beratung
- "sonstiges" - alles andere (z.B. privater Call, Verkaeufer, etc.)

Erstelle dann eine Markdown-Zusammenfassung mit dieser Struktur:

# Call-Zusammenfassung vom {today}

**Call-Typ:** <geschaeftspartner|kunde|sonstiges>
**Teilnehmer:** <erkannte Personen>
**Dauer (geschaetzt):** <Minuten>

## Hauptthemen
<2-5 Bullet Points der wichtigsten besprochenen Themen>

## Entscheidungen
<Was wurde konkret entschieden? Wenn nichts entschieden: "Keine konkreten Entscheidungen.">

## Aufgaben
<Wer uebernimmt was bis wann? Format: "**[Person]:** Aufgabe (Deadline falls genannt)">

## Offene Punkte
<Was bleibt unklar, was muss noch geklaert werden?>

## Sonstige Notizen
<Interessante Hintergruende, Stimmung, Kontext>

Sprache: IMMER Deutsch. Sei praezise und business-fokussiert. Keine Spekulationen - nur was wirklich gesagt wurde.

Transkript:
---
{transcript}
---"""

response = client.models.generate_content(
    model='gemini-2.5-flash',
    contents=PROMPT,
)
summary = response.text.strip()

summary_path = os.path.splitext(transcript_path)[0] + "_summary.md"
with open(summary_path, 'w', encoding='utf-8') as f:
    f.write(summary)

print(summary_path)
