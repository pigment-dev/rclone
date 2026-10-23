#!/usr/bin/env python3
"""Regenerates Resources/Localizable.xcstrings from UI string literals in Sources/.
Keeps existing translations (e.g. Persian) and marks vanished keys as stale."""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAT = os.path.join(ROOT, "Resources", "Localizable.xcstrings")
CALL = re.compile(r'(?:\b(?:Text|L|Button|Toggle|Label|SectionLabel|Picker|TextField|SecureField|Pill|LocalizedStringKey|Stepper|Menu|LabeledField|EmptyState|PageHeader|ChoiceCard|FeatureTile|PermissionRow|ToggleRow|InfoTile|StatTile|Metric|SettingsGroup|TokenList|LimitRow|SearchField)\s*\(\s*(?:\w+:\s*)?|\b(?:title|subtitle|message|text|label|help|prompt|placeholder|actionTitle|footer):\s*)"((?:[^"\\]|\\.)*)"')

def keys():
    found = set()
    for d, _, files in os.walk(os.path.join(ROOT, "Sources")):
        for f in files:
            if not f.endswith(".swift"):
                continue
            src = open(os.path.join(d, f), encoding="utf-8").read()
            for m in CALL.finditer(src):
                k = m.group(1)
                if not re.search(r"[A-Za-z]", k) or "\\(" in k or k.startswith(("http", "x-apple", "pdrclone")):
                    continue
                found.add(k.replace('\\"', '"').replace("\\n", "\n"))
    return found

cat = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
if os.path.exists(CAT):
    cat = json.load(open(CAT, encoding="utf-8"))
current = keys()
strings = cat.setdefault("strings", {})
for k in current:
    strings.setdefault(k, {})
    strings[k].pop("extractionState", None)
for k in list(strings):
    if k not in current:
        strings[k]["extractionState"] = "stale"
cat["strings"] = dict(sorted(strings.items()))
json.dump(cat, open(CAT, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"{len(current)} keys → {CAT}")
