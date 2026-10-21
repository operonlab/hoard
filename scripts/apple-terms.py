"""Prints the terms Apple already ships for a concept, in zh_TW, en, ja and ko.

usage: apple-terms.py <bundle,bundle,...> <term,term,...>
A term matches an entry whose zh_TW value equals it; a leading ~ matches any value containing it.
Use these instead of translating a system concept from memory (docs/plans/v0.6-i18n.md, Terms).
"""
import glob, os, plistlib, sys
bundles = sys.argv[1].split(",")
terms = sys.argv[2].split(",")
def load(path):
    try:
        with open(path, "rb") as f: data = plistlib.load(f)
    except Exception:
        return {}
    if path.endswith(".loctable"):
        return data
    return {os.path.basename(path): data}
for b in bundles:
    res = os.path.join(b, "Contents/Resources")
    tables = {}
    for lang in ["zh_TW", "en", "ja", "ko"]:
        for p in glob.glob(os.path.join(res, lang + ".lproj", "*.strings")):
            tables.setdefault(lang, {}).update({(os.path.basename(p), k): v for k, v in (load(p).get(os.path.basename(p)) or {}).items() if isinstance(v, str)})
    for p in glob.glob(os.path.join(res, "*.loctable")):
        for lang, table in load(p).items():
            if lang in ("zh_TW", "en", "ja", "ko") and isinstance(table, dict):
                tables.setdefault(lang, {}).update({(os.path.basename(p), k): v for k, v in table.items() if isinstance(v, str)})
    zh = tables.get("zh_TW", {})
    seen = set()
    for key, value in zh.items():
        for t in terms:
            if value == t or (t.startswith("~") and t[1:] in value):
                row = (value, tables.get("en", {}).get(key), tables.get("ja", {}).get(key), tables.get("ko", {}).get(key))
                if row not in seen and len(value) < 40:
                    seen.add(row); print(os.path.basename(b), "|", " | ".join(str(x) for x in row))
