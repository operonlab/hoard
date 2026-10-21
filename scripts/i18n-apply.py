"""Merges translations into Localization/Localizable.xcstrings.

usage: i18n-apply.py <translations.json>

The file maps a catalog key (the zh-Hant source text) to its translations:
  {"自動更新・待命": {"en": "Auto-refresh · Idle", "ja": "...", "ko": "..."},
   "自動更新中⋯ %lld 個資料夾": {"en": {"one": "... %lld folder", "other": "... %lld folders"}, ...}}
A plain string is one value; an object is plural variants. A key the catalog does not have is an
error, not a new entry: a typo would otherwise add a translation nothing ever shows.
"""
import json
import pathlib
import subprocess
import sys
import tempfile

CATALOG = pathlib.Path(__file__).resolve().parent.parent / "Localization" / "Localizable.xcstrings"
LANGUAGES = ("en", "ja", "ko")
PLURAL_FORMS = {"zero", "one", "two", "few", "many", "other"}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def translation(key, language, value):
    """The catalog form of one translation; exits on input the catalog cannot hold."""
    if isinstance(value, str) and value:
        return unit(value)
    if isinstance(value, dict) and value and "other" in value and set(value) <= PLURAL_FORMS \
            and all(isinstance(text, str) and text for text in value.values()):
        return {"variations": {"plural": {form: unit(text) for form, text in value.items()}}}
    sys.exit(f"{language} for {key!r}: give a non-empty string, or plural forms from {sorted(PLURAL_FORMS)} "
             f"including 'other', got {value!r}")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    translations = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings = catalog["strings"]
    unknown = [key for key in translations if key not in strings]
    if unknown:
        sys.exit("catalog has no such key (run scripts/i18n-sync.sh first, or fix the key):\n  "
                 + "\n  ".join(unknown))
    for key, by_language in translations.items():
        extra = set(by_language) - set(LANGUAGES)
        if extra:
            sys.exit(f"unknown language {sorted(extra)} for {key!r}")
        localizations = strings[key].setdefault("localizations", {})
        for language, value in by_language.items():
            # Replacing a translation is the point; replacing a shape this script does not write
            # (device variations, substitutions) would drop what someone made in Xcode.
            existing = localizations.get(language, {})
            if set(existing) - {"stringUnit", "variations"} or set(existing.get("variations", {})) - {"plural"}:
                sys.exit(f"{language} for {key!r} has a form this script does not write: {sorted(existing)}; edit it in Xcode")
            localizations[language] = translation(key, language, value)
    # Same layout as Xcode writes, so the file diffs cleanly. The catalog is replaced only if it compiles.
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"
    with tempfile.TemporaryDirectory() as scratch:
        candidate = pathlib.Path(scratch) / "Localizable.xcstrings"
        candidate.write_text(text, encoding="utf-8")
        compiled = subprocess.run(["xcrun", "xcstringstool", "compile", str(candidate), "--output-directory", scratch],
                                  capture_output=True, text=True)
        if compiled.returncode != 0:
            sys.exit(f"the merged catalog does not compile; nothing written:\n{compiled.stderr}")
    CATALOG.write_text(text, encoding="utf-8")
    print(f"applied {len(translations)} keys to {CATALOG}")


if __name__ == "__main__":
    main()
