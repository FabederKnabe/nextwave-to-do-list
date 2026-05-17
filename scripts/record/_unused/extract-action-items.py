"""
extract-action-items.py - Stufe 2 der Call-Pipeline

Liest Markdown-Summary (Output von summarize-call.py), schickt an
Gemini 2.5 Flash, gibt strukturiertes Patch-JSON nach stdout aus.

Schema:
    todos:         {id, text, kontext, deadline, person, quelle, type, module, complexity}
    offene_punkte: {id, text, kontext, quelle, module}
    themen:        {id, titel, details, quelle, module}
    zuletzt_aktualisiert: "DD.MM.YYYY HH:MM"

Aufruf:
    python extract-action-items.py <summary.md>

Output: JSON nach stdout.

Voraussetzung: GEMINI_API_KEY env var, modules.json im selben Ordner.
"""

import os
import sys
import io
import json
import re
from datetime import datetime
from google import genai

# Windows-Python-Default fuer stdout/stderr ist cp1252 - das verstuemmelt
# deutsche Umlaute, sobald JSON nach stdout gedruckt und vom Aufrufer
# als UTF-8 zurueckgelesen wird (process-recording.ps1). Hier erzwingen
# wir UTF-8 unabhaengig vom OS-Default.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace', line_buffering=True)
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace', line_buffering=True)

API_KEY = os.environ.get('GEMINI_API_KEY')
if not API_KEY:
    print(json.dumps({"error": "GEMINI_API_KEY env var not set"}), file=sys.stderr)
    sys.exit(1)

client = genai.Client(api_key=API_KEY)

summary_path = sys.argv[1]
with open(summary_path, 'r', encoding='utf-8') as f:
    summary = f.read()

# Modul-Liste laden
modules_json_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'modules.json')
with open(modules_json_path, 'r', encoding='utf-8') as f:
    modules = json.load(f)

modules_text = "\n".join([f"- {m['slug']}: {m['label']} - {m['description']}" for m in modules])

today = datetime.now().strftime('%Y%m%d')
today_human = datetime.now().strftime('%d.%m.%Y')

call_type_match = re.search(r'\*\*Call-Typ:\*\*\s*(\w+)', summary)
call_type = call_type_match.group(1) if call_type_match else "sonstiges"

PROMPT = f"""Du extrahierst strukturierte Action Items aus der folgenden Call-Zusammenfassung.

Der Call-Typ ist: {call_type}

Extrahiere drei Listen:
- todos: konkrete Aufgaben mit klarem Owner (nur fabian oder iris - bei Kundencall trotzdem fabian/iris als Owner, Kundenname im kontext)
- offene_punkte: ungeklaerte Themen, Fragen, Entscheidungen die noch ausstehen
- themen: besprochene Inhalte mit Ergebnis/Entscheidung

ID-Format: call-{today}-NNN (NNN = laufende Nummer ab 001, ueber alle 3 Listen gemeinsam).

KLASSIFIKATION fuer jedes todo:
- type: einer von ["bug", "feature", "chore", "task", "spec"]
- module: passender slug aus der unten stehenden Liste. Falls KEIN Modul passt: pragnanter neuer Slug (lowercase, bindestrich-getrennt)
- complexity: einer von ["XS", "S", "M", "L", "XL"]
  - XS = unter 1 Stunde Arbeit
  - S = 1-4 Stunden
  - M = halber bis ganzer Tag
  - L = 2-3 Tage
  - XL = 1+ Woche

Verfuegbare Module (slug: label - beschreibung):
{modules_text}

Schemas:
todos:           {{id, text (1 Zeile aktionsorientiert), kontext (detailliert, siehe unten - bei Kundencall mit Kundenname), deadline (null falls nicht genannt), person ("fabian" oder "iris"), quelle ("Call {today_human}"), type, module, complexity}}
offene_punkte:   {{id, text, kontext (detailliert, siehe unten), quelle ("Call {today_human}"), module}}
themen:          {{id, titel (1 Zeile praegnant), details (detailliert, siehe unten), quelle ("Call {today_human}"), module}}

Fuer das Feld "kontext" bei Todos und "details" bei Themen: schreibe DETAILLIERT.
Jeder Kontext-Eintrag soll enthalten:
- Was genau das Problem/die Aufgabe ist (konkret, nicht generisch)
- Warum es relevant ist oder was der Ausloeser war
- Welche Auswirkungen es hat (wer ist betroffen, was funktioniert nicht)
- Falls im Call erwaehnt: Loesungsansatz, Zeitrahmen, Abhaengigkeiten
- Falls eine Deadline genannt wurde: explizit erwaehnen

Beispiel SCHLECHT: "Fabian soll den Bug fixen."
Beispiel GUT: "Die Kalkulations-Uebersicht hat einen Performance-Bug: bei Angeboten mit mehr als 50 Positionen friert der Browser ein. Betrifft alle Nutzer die grosse Leistungsverzeichnisse bearbeiten. Fabian schaetzt 2-3 Tage Aufwand. Wurde im Call als dringend eingestuft weil mehrere Kunden davon betroffen sind."

Schreibe 2-4 Saetze pro Kontext-Eintrag. Lieber zu ausfuehrlich als zu knapp.

Sprache: IMMER Deutsch.

Antworte AUSSCHLIESSLICH mit JSON in diesem exakten Format (keine Markdown-Backticks, kein Fliesstext):
{{
  "todos": [...],
  "offene_punkte": [...],
  "themen": [...],
  "zuletzt_aktualisiert": "{datetime.now().strftime('%d.%m.%Y %H:%M')}"
}}

Falls keine Items in einer Kategorie: leere Liste [].

Zusammenfassung:
---
{summary}
---"""

response = client.models.generate_content(
    model='gemini-2.5-pro',
    contents=PROMPT,
)
text = response.text.strip()

# Defensive Parsing: falls Gemini doch Markdown-Backticks setzt
text = re.sub(r'^```(?:json)?\s*', '', text)
text = re.sub(r'\s*```$', '', text)

parsed = json.loads(text)
# Direkt als UTF-8-Bytes nach stdout, umgeht jegliche Encoding-Layer.
sys.stdout.buffer.write(json.dumps(parsed, ensure_ascii=False, indent=2).encode('utf-8'))
sys.stdout.buffer.write(b'\n')
