"""
fetch-plane-ids.py - Hilfsscript Branch A2 (Plane-Migration)

Holt die UUIDs (States, Labels, Modules, Members) aus der Plane API und
schreibt sie in plane-mapping.json. Matching per Name (case-insensitive;
Module per partial match, weil Plane-Modulnamen ausgeschrieben sind und das
Mapping kurze Slugs nutzt).

Aufruf:
    python fetch-plane-ids.py

Voraussetzung:
    - PLANE_API_TOKEN env var
    - plane-mapping.json im selben Ordner (liefert base_url, workspace_slug,
      project_id und die erwarteten Namen).

Dependencies: stdlib + requests. Laeuft auf Windows / Python 3.14.
"""

import os
import sys
import io
import json

import requests

# Windows-Default fuer stdout ist cp1252 - deutsche Umlaute (Aufmaß) sonst
# Mojibake. UTF-8 erzwingen.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace', line_buffering=True)
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace', line_buffering=True)

MAPPING_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'plane-mapping.json')

# Erwartete Namen je Slug. Die Plane-Modulnamen sind ausgeschrieben - hier
# der menschenlesbare Name den wir per partial match suchen.
EXPECTED_MODULES = {
    "aufmass": "Aufmaß",
    "craftmaster-mobile": "Craftmaster Mobile",
    "fuhrpark": "Fuhrpark",
    "kalkulation": "Kalkulation",
    "material": "Material",
    "personal": "Personal",
    "plantafel": "Plantafel",
    "planung": "Planung",
    "projekte": "Projekte",
    "zeiten": "Zeiten",
}

# State-Name in Plane fuer den AI-Inbox-Status.
EXPECTED_STATES = {
    "ai_inbox": "AI Inbox",
}

# Label-Name in Plane je Slug.
EXPECTED_LABELS = {
    "bug": "bug",
    "feat": "feat",
    "security": "security",
    "improvement": "improvement",
    "usability": "usability",
    "mobile": "mobile",
    "ai": "ai",
}

# Member-Match per Anzeigename / E-Mail-Prefix (partial, case-insensitive).
EXPECTED_MEMBERS = {
    "fabian": "fabian",
    "iris": "iris",
}


def fail(msg):
    print(f"FEHLER: {msg}", file=sys.stderr)
    sys.exit(1)


def warn(msg):
    print(f"WARNUNG: {msg}", file=sys.stderr)


def load_mapping():
    with open(MAPPING_PATH, 'r', encoding='utf-8') as f:
        return json.load(f)


def save_mapping(mapping):
    with open(MAPPING_PATH, 'w', encoding='utf-8') as f:
        json.dump(mapping, f, ensure_ascii=False, indent=2)
        f.write('\n')


def api_get(url, headers):
    resp = requests.get(url, headers=headers, timeout=30)
    if resp.status_code in (401, 403):
        fail("PLANE_API_TOKEN ungueltig oder keine Berechtigung "
             f"(HTTP {resp.status_code}) bei {url}")
    resp.raise_for_status()
    return resp.json()


def extract_results(payload):
    """Plane antwortet teils paginiert ({results: [...]}), teils als Liste."""
    if isinstance(payload, dict) and 'results' in payload:
        return payload['results']
    if isinstance(payload, list):
        return payload
    return []


def match_exact(items, name, name_key='name'):
    """Case-insensitive exakter Match auf name_key."""
    target = name.strip().lower()
    for it in items:
        val = (it.get(name_key) or '').strip().lower()
        if val == target:
            return it
    return None


def match_partial(items, name, name_key='name'):
    """Case-insensitive partial match (target in val oder val in target)."""
    target = name.strip().lower()
    for it in items:
        val = (it.get(name_key) or '').strip().lower()
        if target in val or (val and val in target):
            return it
    return None


def member_display(member):
    """Plane-Member-Objekt -> durchsuchbarer Anzeige-String."""
    # Membership-Endpoint schachtelt das User-Objekt teils unter 'member'.
    user = member.get('member') if isinstance(member.get('member'), dict) else member
    parts = [
        user.get('display_name'),
        user.get('first_name'),
        user.get('last_name'),
        user.get('email'),
    ]
    return ' '.join([p for p in parts if p]).lower()


def member_id(member):
    user = member.get('member') if isinstance(member.get('member'), dict) else member
    return user.get('id') or member.get('id')


def main():
    token = os.environ.get('PLANE_API_TOKEN')
    if not token:
        fail("PLANE_API_TOKEN env var nicht gesetzt.")

    mapping = load_mapping()
    base = mapping['base_url'].rstrip('/')
    ws = mapping['workspace_slug']
    project = mapping['project_id']

    headers = {
        'X-API-Key': token,
        'Content-Type': 'application/json',
    }

    proj_base = f"{base}/api/v1/workspaces/{ws}/projects/{project}"

    # --- States ---
    print("Hole States...")
    states = extract_results(api_get(f"{proj_base}/states/", headers))
    for slug, expected in EXPECTED_STATES.items():
        hit = match_exact(states, expected) or match_partial(states, expected)
        if hit:
            mapping['states'][slug] = hit['id']
            print(f"  state {slug} -> {hit.get('name')} ({hit['id']})")
        else:
            warn(f"State '{expected}' (slug {slug}) nicht gefunden.")

    # --- Labels ---
    print("Hole Labels...")
    labels = extract_results(api_get(f"{proj_base}/labels/", headers))
    for slug, expected in EXPECTED_LABELS.items():
        hit = match_exact(labels, expected) or match_partial(labels, expected)
        if hit:
            mapping['labels'][slug] = hit['id']
            print(f"  label {slug} -> {hit.get('name')} ({hit['id']})")
        else:
            warn(f"Label '{expected}' (slug {slug}) nicht gefunden.")

    # --- Modules ---
    print("Hole Modules...")
    modules = extract_results(api_get(f"{proj_base}/modules/", headers))
    for slug, expected in EXPECTED_MODULES.items():
        hit = match_exact(modules, expected) or match_partial(modules, expected)
        if hit:
            mapping['modules'][slug] = hit['id']
            print(f"  module {slug} -> {hit.get('name')} ({hit['id']})")
        else:
            warn(f"Module '{expected}' (slug {slug}) nicht gefunden.")

    # --- Members (Workspace-Ebene) ---
    print("Hole Members...")
    members = extract_results(api_get(f"{base}/api/v1/workspaces/{ws}/members/", headers))
    for slug, expected in EXPECTED_MEMBERS.items():
        target = expected.strip().lower()
        hit = None
        for m in members:
            if target in member_display(m):
                hit = m
                break
        if hit:
            mid = member_id(hit)
            mapping['members'][slug] = mid
            print(f"  member {slug} -> {member_display(hit).strip()} ({mid})")
        else:
            warn(f"Member '{expected}' (slug {slug}) nicht gefunden.")

    save_mapping(mapping)
    print(f"\nplane-mapping.json aktualisiert: {MAPPING_PATH}")


if __name__ == '__main__':
    main()
