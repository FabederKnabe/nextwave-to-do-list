"""
extract-action-items.py - Stufe 2 der Call-Pipeline (Branch A2: Plane)

Liest Markdown-Summary (Output von summarize-call.py), schickt an
Gemini 2.5 Pro, gibt strukturiertes JSON nach stdout aus.

Schema (NEU - nur noch zwei Bloecke fuer Plane):
    todos: [{text, kontext, type, module, complexity, confidence}]
    zusammenfassung: {titel, teilnehmer, dauer_min, hauptthemen,
                      entscheidungen, inhalt_markdown}

Es gibt KEINE offene_punkte/themen mehr. Alles mit Handlungsbedarf wird ein
Todo (grosszuegig extrahieren - Triage macht der Mensch). Reine Information
ohne Handlungsbedarf landet in der zusammenfassung.

Aufruf:
    python extract-action-items.py <summary.md>

Output: JSON nach stdout.

Voraussetzung: GEMINI_API_KEY env var, modules.json im Parent-Ordner.
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

# Modul-Liste laden (liegt im Parent-Ordner, scripts/record/modules.json)
modules_json_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'modules.json')
with open(modules_json_path, 'r', encoding='utf-8') as f:
    modules = json.load(f)

modules_text = "\n".join([f"- {m['slug']}: {m['label']} - {m['description']}" for m in modules])

today_human = datetime.now().strftime('%d.%m.%Y')

call_type_match = re.search(r'\*\*Call-Typ:\*\*\s*(\w+)', summary)
call_type = call_type_match.group(1) if call_type_match else "sonstiges"

PROMPT = f"""Du extrahierst aus der folgenden Call-Zusammenfassung strukturierte Daten fuer das Plane-Aufgabentool.

Der Call-Typ ist: {call_type}
Datum des Calls: {today_human}

Es gibt NUR ZWEI Bloecke: "todos" und "zusammenfassung".

=== GRUNDREGEL ===
Alles was auch nur ansatzweise nach Handlungsbedarf klingt, wird ein TODO. Dazu zaehlen:
- konkrete Aufgaben
- Entscheidungen mit Handlungsbedarf
- offene Punkte die noch geklaert werden muessen
- konzeptionelle/strategische Themen die untersucht oder konzeptioniert werden muessen
Jedes davon ist ein EIGENSTAENDIGES Todo.

Lieber zu VIELE Todos als zu wenige - die Triage macht der Mensch. Extrahiere grosszuegig.

Wenn im Call etwas fuer die Zukunft besprochen wird (z.B. "in 4 Wochen sollten wir X machen"), ist das trotzdem ein Todo, kein blosses Thema.

Setze confidence: niedrig wenn du unsicher bist ob es wirklich eine Aufgabe ist. Der Mensch entscheidet bei der Triage.

=== GRANULARITAET (SEHR WICHTIG) ===
- Erstelle lieber 20 kleine, einzelne Tickets als 10 zusammengefasste. Jede eigenstaendige Aufgabe, Recherche, Evaluierung oder Entscheidung wird ein EIGENES Ticket.
- Fasse NIEMALS mehrere Aufgaben in einem Ticket zusammen. Wenn im Gespraech drei verschiedene Einschraenkungen fuer Test-Accounts besprochen werden, entstehen daraus drei separate Tickets - nicht eines.
- Wenn ein Thema aus mehreren Teilschritten besteht (z.B. "Recherche" und "Konzept erstellen" und "Implementierung"), erstelle fuer jeden Teilschritt ein eigenes Ticket.
- Auch beilaeufig erwaehnte Aufgaben, strategische Ideen, Recherche-Auftraege und "sollten wir mal machen"-Punkte werden eigene Tickets. Setze bei Unsicherheit confidence auf "niedrig" statt das Ticket wegzulassen.
- Ziel: Aus einem 30-Minuten-Call sollten typischerweise 15-25 Tickets entstehen. Wenn du weniger als 10 extrahierst, pruefe ob du Themen zusammengefasst oder uebersprungen hast.

Die "zusammenfassung" ist fuer ALLES was KEIN Todo ist: Statusupdates, Informationsaustausch, Kontextinfos, allgemeine Diskussion. Reine Information ohne Handlungsbedarf gehoert hier hin.

=== FORMULIERUNG (WICHTIG) ===
- Formuliere ALLE Texte und Kontexte neutral und professionell. Vermeide Personennamen in Aufgabenbeschreibungen. Statt "Fabian muss den Bug fixen" schreibe "Der Bug muss behoben werden". Statt "Iris hat vorgeschlagen" schreibe "Es wurde vorgeschlagen".
- Die Tickets werden in einem professionellen Kanban-Board angezeigt. Sie muessen fuer sich allein stehen - ohne Wissen ueber den Call verstaendlich sein. Sie sollen wie professionelle Tickets klingen, nicht wie Gespraechsnotizen.
- Vermeide Gespraechsreferenzen wie "wurde besprochen", "im Call erwaehnt", "laut Gespraech", "Iris hat gesagt", "Fabian meinte". Schreibe stattdessen die Fakten direkt auf, als waeren sie eigenstaendige Anforderungen.

=== KLASSIFIKATION pro Todo ===
type (genau einer):
- "bug"         - Fehler in bestehendem Code
- "feat"        - Neues Feature
- "improvement" - Verbesserung/Optimierung bestehender Funktionen
- "security"    - Sicherheitsrelevant
- "usability"   - UX/Bedienbarkeit
- "mobile"      - Mobile-App-spezifisch
- "ai"          - KI-bezogen

module (genau ein slug aus der Liste unten, oder null falls KEIN Modul passt):
{modules_text}

complexity (genau einer):
- "XS" = unter 1 Stunde
- "S"  = 1-4 Stunden
- "M"  = halber bis ganzer Tag
- "L"  = 2-3 Tage
- "XL" = 1+ Woche

confidence (genau einer):
- "hoch"   - klar formulierte Aufgabe
- "mittel" - implizit aber wahrscheinlich gemeint
- "niedrig"- vage, koennte auch nur Diskussionskontext sein

text:    1 Zeile, aktionsorientiert, neutral formuliert, kurze Beschreibung der Aufgabe (keine Personennamen).
kontext: Mindestens 4-5 ausfuehrliche Saetze. Erklaere den fachlichen/technischen Hintergrund, warum die Aufgabe wichtig ist, welche Randbedingungen bekannt sind, und welche konkreten Details genannt wurden (ohne Personenzuordnung, ohne Gespraechsreferenzen). Lieber zu viel Kontext als zu wenig. In 3 Wochen liest jemand dieses Ticket ohne sich an den Call zu erinnern - es muss trotzdem vollstaendig verstaendlich sein.

=== zusammenfassung ===
- titel:          "Call {today_human} - <Teilnehmer>"
- teilnehmer:     Liste der erkannten Personen, z.B. ["Iris", "Fabian"]
- dauer_min:      geschaetzte Dauer in Minuten (Zahl)
- hauptthemen:    Liste der wichtigsten Themen (Strings)
- entscheidungen: Liste konkreter Entscheidungen (Strings; leer falls keine)
- inhalt_markdown:ausfuehrliche Zusammenfassung als Markdown (Headings, Listen, Absaetze erlaubt)

Sprache: IMMER Deutsch.

Antworte AUSSCHLIESSLICH mit JSON in diesem exakten Format (keine Markdown-Backticks, kein Fliesstext):
{{
  "todos": [
    {{
      "text": "Mengenberechnung in der Kalkulation um Verschnittfaktor erweitern",
      "kontext": "Die Kalkulation berechnet aktuell die benoetigte Materialmenge ohne Verschnitt, wodurch bei Bestellungen regelmaessig zu wenig Material kalkuliert wird. Insbesondere bei Plattenmaterial und Rollenware faellt ein nicht unerheblicher Verschnitt an, der bislang manuell aufgeschlagen werden muss. Ein konfigurierbarer Verschnittfaktor pro Materialkategorie soll diesen Aufschlag automatisieren. Als Randbedingung muss der Faktor pro Position ueberschreibbar bleiben, da einzelne Materialien stark abweichende Verschnittwerte haben. Ohne diese Erweiterung bleiben Kalkulationen systematisch zu niedrig und fuehren zu Nachbestellungen.",
      "type": "feat",
      "module": "kalkulation",
      "complexity": "M",
      "confidence": "hoch"
    }}
  ],
  "zusammenfassung": {{
    "titel": "Call {today_human} - Iris, Fabian",
    "teilnehmer": ["Iris", "Fabian"],
    "dauer_min": 0,
    "hauptthemen": ["..."],
    "entscheidungen": ["..."],
    "inhalt_markdown": "..."
  }}
}}

Falls keine Todos: "todos": []. Die zusammenfassung ist immer vorhanden.

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
