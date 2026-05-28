"""
push-to-plane.py - Stufe 3 der Call-Pipeline (Branch A2)

Ersetzt push-patches.ps1 (Supabase). Liest das von extract-action-items.py
erzeugte Patch-JSON und pusht es in die self-hosted Plane-Instanz:
  - pro Todo ein Issue (+ optionale Modul-Zuordnung)
  - die Call-Zusammenfassung als Plane-Page

Aufruf:
    python push-to-plane.py <patch.json>

Konfiguration:
    - PLANE_API_TOKEN env var (Header X-API-Key)
    - plane-mapping.json im selben Ordner (alle UUIDs)

Fehlerbehandlung:
    - 3 Versuche pro Request, Backoff 5s/15s/30s (bei 5xx/429/Netzwerk)
    - 401/403: harter Abbruch mit klarer Meldung
    - Netzwerk-/Restfehler: nicht gepushte Items -> <patch>.failed.json
    - Exit 0 NUR wenn alle Items (Todos + Page) erfolgreich.

Dependencies: stdlib + requests. Laeuft auf Windows / Python 3.14. UTF-8 durchgaengig.
"""

import os
import sys
import io
import json
import re
import time
import html

import requests

# Windows-Default cp1252 -> UTF-8 erzwingen (deutsche Umlaute).
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace', line_buffering=True)
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace', line_buffering=True)

MAPPING_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'plane-mapping.json')

BACKOFF = [5, 15, 30]  # Sekunden je Versuch (3 Versuche)


def log(level, msg):
    print(f"[{level}] {msg}")


class AuthError(Exception):
    """401/403 - Token ungueltig oder keine Berechtigung. Harter Abbruch."""
    pass


def is_placeholder(value):
    return (not value) or (isinstance(value, str) and value.startswith('UUID_HIER'))


def md_to_html(md):
    """Simpler Markdown->HTML-Converter (Headings, Listen, Absaetze, Bold/Italic).

    Kein externes Package - reicht fuer Gemini-Markdown in Plane-Pages.
    """
    if not md:
        return ""

    lines = md.replace('\r\n', '\n').split('\n')
    out = []
    in_ul = False
    in_ol = False

    def close_lists():
        nonlocal in_ul, in_ol
        if in_ul:
            out.append('</ul>')
            in_ul = False
        if in_ol:
            out.append('</ol>')
            in_ol = False

    def inline(text):
        # Erst escapen, dann Bold/Italic-Marker durch Tags ersetzen.
        t = html.escape(text)
        t = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', t)
        t = re.sub(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)', r'<em>\1</em>', t)
        t = re.sub(r'__(.+?)__', r'<strong>\1</strong>', t)
        t = re.sub(r'(?<!_)_(?!_)(.+?)(?<!_)_(?!_)', r'<em>\1</em>', t)
        return t

    for raw in lines:
        line = raw.rstrip()
        stripped = line.strip()

        if not stripped:
            close_lists()
            continue

        # Headings
        m = re.match(r'^(#{1,6})\s+(.*)$', stripped)
        if m:
            close_lists()
            level = len(m.group(1))
            out.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
            continue

        # Unordered list
        m = re.match(r'^[-*+]\s+(.*)$', stripped)
        if m:
            if in_ol:
                out.append('</ol>')
                in_ol = False
            if not in_ul:
                out.append('<ul>')
                in_ul = True
            out.append(f"<li>{inline(m.group(1))}</li>")
            continue

        # Ordered list
        m = re.match(r'^\d+[.)]\s+(.*)$', stripped)
        if m:
            if in_ul:
                out.append('</ul>')
                in_ul = False
            if not in_ol:
                out.append('<ol>')
                in_ol = True
            out.append(f"<li>{inline(m.group(1))}</li>")
            continue

        # Paragraph
        close_lists()
        out.append(f"<p>{inline(stripped)}</p>")

    close_lists()
    return '\n'.join(out)


def request_with_retry(method, url, headers, payload):
    """HTTP-Request mit Retry. Gibt requests.Response zurueck.

    Retry bei 5xx/429/Netzwerkfehler. Bei 401/403 -> AuthError (kein Retry).
    Bei 4xx (ausser 429) -> letzte Response wird zurueckgegeben (Caller wertet aus).
    """
    last_exc = None
    for attempt in range(3):
        try:
            resp = requests.request(method, url, headers=headers,
                                    data=json.dumps(payload).encode('utf-8'),
                                    timeout=30)
        except requests.RequestException as e:
            last_exc = e
            if attempt < 2:
                wait = BACKOFF[attempt]
                log('WARN', f"Netzwerkfehler ({e}) - Versuch {attempt + 1}, retry in {wait}s")
                time.sleep(wait)
                continue
            raise

        if resp.status_code in (401, 403):
            raise AuthError("PLANE_API_TOKEN ungueltig oder keine Berechtigung "
                            f"(HTTP {resp.status_code})")

        if resp.status_code == 429 or 500 <= resp.status_code < 600:
            if attempt < 2:
                wait = BACKOFF[attempt]
                log('WARN', f"HTTP {resp.status_code} bei {url} - Versuch {attempt + 1}, retry in {wait}s")
                time.sleep(wait)
                continue

        return resp

    if last_exc:
        raise last_exc


def post_issue(cfg, headers, todo, datum):
    base = cfg['base_url'].rstrip('/')
    url = f"{base}/api/v1/workspaces/{cfg['workspace_slug']}/projects/{cfg['project_id']}/issues/"

    kontext = html.escape(todo.get('kontext') or '')
    confidence = html.escape(str(todo.get('confidence') or ''))
    description_html = (
        f"<p>{kontext}</p>"
        f"<p><strong>Confidence:</strong> {confidence}</p>"
        f"<p><strong>Quelle:</strong> Call {html.escape(datum)}</p>"
    )

    # Label-UUID
    labels = []
    ttype = todo.get('type')
    label_uuid = cfg['labels'].get(ttype) if ttype else None
    if label_uuid and not is_placeholder(label_uuid):
        labels.append(label_uuid)
    elif ttype:
        log('WARN', f"Kein Label-UUID fuer type '{ttype}' - Issue ohne Label.")

    # Assignees (person -> ein/e oder beide Member)
    assignees = []
    person = todo.get('person')
    if person == 'beide':
        for key in ('fabian', 'iris'):
            uid = cfg['members'].get(key)
            if uid and not is_placeholder(uid):
                assignees.append(uid)
    elif person:
        uid = cfg['members'].get(person)
        if uid and not is_placeholder(uid):
            assignees.append(uid)
        else:
            log('WARN', f"Kein Member-UUID fuer person '{person}' - Issue ohne Assignee.")

    # Estimate (complexity -> int aus Skala)
    estimate_point = None
    complexity = todo.get('complexity')
    if complexity and complexity in cfg.get('estimates', {}):
        estimate_point = cfg['estimates'][complexity]

    state_uuid = cfg['states'].get('ai_inbox')

    payload = {
        "name": todo.get('text') or '(ohne Titel)',
        "description_html": description_html,
        "priority": "none",
    }
    if state_uuid and not is_placeholder(state_uuid):
        payload["state"] = state_uuid
    if labels:
        payload["labels"] = labels
    if assignees:
        payload["assignees"] = assignees
    if estimate_point is not None:
        payload["estimate_point"] = estimate_point

    resp = request_with_retry('POST', url, headers, payload)
    if resp.status_code not in (200, 201):
        raise RuntimeError(f"Issue-POST fehlgeschlagen (HTTP {resp.status_code}): {resp.text[:300]}")

    data = resp.json()
    return data.get('id')


def post_module_issue(cfg, headers, module_uuid, issue_id):
    base = cfg['base_url'].rstrip('/')
    url = (f"{base}/api/v1/workspaces/{cfg['workspace_slug']}/projects/"
           f"{cfg['project_id']}/modules/{module_uuid}/module-issues/")
    payload = {"issues": [issue_id]}
    resp = request_with_retry('POST', url, headers, payload)
    if resp.status_code not in (200, 201):
        raise RuntimeError(f"Module-Issue-POST fehlgeschlagen (HTTP {resp.status_code}): {resp.text[:300]}")


def post_page(cfg, headers, zusammenfassung):
    base = cfg['base_url'].rstrip('/')
    url = f"{base}/api/v1/workspaces/{cfg['workspace_slug']}/projects/{cfg['project_id']}/pages/"
    payload = {
        "name": zusammenfassung.get('titel') or 'Call-Zusammenfassung',
        "description_html": md_to_html(zusammenfassung.get('inhalt_markdown') or ''),
    }
    resp = request_with_retry('POST', url, headers, payload)
    if resp.status_code not in (200, 201):
        raise RuntimeError(f"Page-POST fehlgeschlagen (HTTP {resp.status_code}): {resp.text[:300]}")
    data = resp.json()
    return data.get('id')


def extract_datum(zusammenfassung):
    """Datum aus dem Titel ziehen (DD.MM.YYYY), sonst leer."""
    titel = (zusammenfassung or {}).get('titel') or ''
    m = re.search(r'(\d{2}\.\d{2}\.\d{4})', titel)
    return m.group(1) if m else ''


def main():
    if len(sys.argv) < 2:
        log('ERROR', "Kein Patch-JSON-Pfad uebergeben. Aufruf: python push-to-plane.py <patch.json>")
        sys.exit(1)

    patch_path = sys.argv[1]
    if not os.path.isfile(patch_path):
        log('ERROR', f"Patch-Datei nicht gefunden: {patch_path}")
        sys.exit(1)

    token = os.environ.get('PLANE_API_TOKEN')
    if not token:
        log('ERROR', "PLANE_API_TOKEN env var nicht gesetzt.")
        sys.exit(1)

    with open(MAPPING_PATH, 'r', encoding='utf-8') as f:
        cfg = json.load(f)

    with open(patch_path, 'r', encoding='utf-8') as f:
        patch = json.load(f)

    headers = {
        'X-API-Key': token,
        'Content-Type': 'application/json',
    }

    todos = patch.get('todos') or []
    zusammenfassung = patch.get('zusammenfassung') or {}
    datum = extract_datum(zusammenfassung)

    failed_todos = []
    created = 0

    try:
        # --- Todos -> Issues ---
        for idx, todo in enumerate(todos, 1):
            try:
                issue_id = post_issue(cfg, headers, todo, datum)
                created += 1
                log('OK', f"Issue {issue_id} angelegt: {todo.get('text')}")

                module = todo.get('module')
                if module:
                    module_uuid = cfg['modules'].get(module)
                    if module_uuid and not is_placeholder(module_uuid):
                        try:
                            post_module_issue(cfg, headers, module_uuid, issue_id)
                            log('OK', f"  -> Modul '{module}' zugeordnet.")
                        except Exception as e:
                            log('WARN', f"  -> Modul-Zuordnung '{module}' fehlgeschlagen: {e}")
                    else:
                        log('WARN', f"  -> Kein Modul-UUID fuer '{module}' - Zuordnung uebersprungen.")
            except Exception as e:
                log('FAIL', f"Todo {idx} fehlgeschlagen: {e}")
                failed_todos.append(todo)

        # --- Zusammenfassung -> Page ---
        page_ok = True
        if zusammenfassung:
            try:
                page_id = post_page(cfg, headers, zusammenfassung)
                log('OK', f"Page {page_id} angelegt: {zusammenfassung.get('titel')}")
            except Exception as e:
                page_ok = False
                log('FAIL', f"Page fehlgeschlagen: {e}")

    except AuthError as e:
        log('ERROR', str(e))
        # Alles Nicht-Gepushte sichern (verbleibende Todos ab Abbruch unbekannt -
        # konservativ: alle noch nicht erfolgreich gepushten + Rest).
        _write_failed(patch_path, {"todos": failed_todos or todos, "zusammenfassung": zusammenfassung})
        sys.exit(1)
    except requests.RequestException as e:
        log('ERROR', f"Netzwerkfehler nach Retries: {e}")
        _write_failed(patch_path, {"todos": failed_todos or todos, "zusammenfassung": zusammenfassung})
        sys.exit(1)

    log('INFO', f"{created}/{len(todos)} Todos erfolgreich, Page {'ok' if page_ok else 'FEHLER'}.")

    if failed_todos or not page_ok:
        payload = {}
        if failed_todos:
            payload["todos"] = failed_todos
        if not page_ok:
            payload["zusammenfassung"] = zusammenfassung
        _write_failed(patch_path, payload)
        sys.exit(1)

    sys.exit(0)


def _write_failed(patch_path, payload):
    failed_path = os.path.splitext(patch_path)[0] + '.failed.json'
    try:
        with open(failed_path, 'w', encoding='utf-8') as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        log('INFO', f"Nicht gepushte Items gesichert -> {failed_path}")
    except Exception as e:
        log('ERROR', f"Konnte Fehlerdatei nicht schreiben: {e}")


if __name__ == '__main__':
    main()
