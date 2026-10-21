"""Checks Localization/Localizable.xcstrings.

usage: i18n-check.py [--strict] [--files A.swift,B.swift] [catalog]

Always an error (exit 1):
  - a translation whose format specifiers differ from its key's (count, type or order): the app would
    show the wrong value or crash;
  - a stale key (the code no longer uses it).
With --strict, a key missing a translation in en, ja or ko is an error too; without it, missing
translations are counted and listed, so the catalog can be filled slice by slice.
--files limits the check to the keys those app sources use, read from the key lists the last
scripts/i18n-sync.sh wrote (.build/i18n/stringsdata); a listed file without a list is an error.
"""
import json
import pathlib
import re
import sys

LANGUAGES = ("en", "ja", "ko")
SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(lld|llu|ld|lu|lf|d|i|u|@|f|e|g|x|X|c|s)")


PLURAL_FORMS = {"zero", "one", "two", "few", "many", "other"}


def arguments(text):
    """{argument number: type} for the format specifiers in `text`, or (None, why) when they are malformed.
    A numbered specifier (%2$@) names its argument; plain ones take the next in order. Using one
    argument twice is fine; using it as two types, or mixing numbered and plain ones, is not."""
    found = [(m.group(1), m.group(2).replace("lf", "f")) for m in SPEC.finditer(text.replace("%%", ""))]
    if any(position for position, _ in found) and not all(position for position, _ in found):
        return None, "mixes numbered and plain specifiers"
    args = {}
    for index, (position, kind) in enumerate(found, start=1):
        slot = int(position) if position else index
        if args.get(slot, kind) != kind:
            return None, f"argument {slot} used as both {args[slot]} and {kind}"
        args[slot] = kind
    return args, None


def values(localization):
    """[(state, value)] for one language, or None when the entry's shape is broken."""
    if "stringUnit" in localization:
        unit = localization["stringUnit"]
        return [(unit.get("state"), unit.get("value", ""))]
    plural = localization.get("variations", {}).get("plural")
    if not plural or "other" not in plural or not set(plural) <= PLURAL_FORMS:
        return None
    return [(form.get("stringUnit", {}).get("state"), form.get("stringUnit", {}).get("value", "")) for form in plural.values()]


def main():
    argv = sys.argv[1:]
    strict = "--strict" in argv
    files = None
    if "--files" in argv:
        index = argv.index("--files")
        files = [name for name in argv[index + 1].split(",") if name]
        del argv[index:index + 2]
    args = [a for a in argv if a != "--strict"]
    repo = pathlib.Path(__file__).resolve().parent.parent
    path = pathlib.Path(args[0]) if args else repo / "Localization" / "Localizable.xcstrings"
    strings = json.loads(path.read_text(encoding="utf-8"))["strings"]
    errors, missing = [], {language: [] for language in LANGUAGES}
    if files is not None:
        wanted = set()
        for name in files:
            listing = repo / ".build" / "i18n" / "stringsdata" / (pathlib.Path(name).stem + ".stringsdata")
            if not listing.is_file():
                sys.exit(f"no key list for {name} at {listing}: run scripts/i18n-sync.sh first")
            tables = json.loads(listing.read_text(encoding="utf-8")).get("tables", {})
            wanted |= {item["key"] for item in tables.get("Localizable", [])}
        absent = sorted(wanted - set(strings))
        errors += [f"key used in {','.join(files)} but not in the catalog (run i18n-sync.sh): {key!r}" for key in absent]
        strings = {key: entry for key, entry in strings.items() if key in wanted}
    errors += [f"stale key (no longer in the code): {key!r}" for key, entry in strings.items()
               if entry.get("extractionState") == "stale"]
    keys = [key for key, entry in strings.items() if entry.get("shouldTranslate", True)]
    for key in keys:
        entry = strings[key]
        expected, why = arguments(key)
        if why:
            errors.append(f"key {key!r}: {why}")
            continue
        for language in LANGUAGES:
            localization = entry.get("localizations", {}).get(language)
            found = values(localization) if localization else []
            if found is None:
                errors.append(f"{language}: plural variants need 'other' and only {sorted(PLURAL_FORMS)} (key {key!r})")
                continue
            if not found or any(state != "translated" or not value for state, value in found):
                missing[language].append(key)
                continue
            for _, value in found:
                got, why = arguments(value)
                if got != expected:
                    errors.append(f"{language}: format {why or got} != {expected} in {value!r} (key {key!r})")
    for language in LANGUAGES:
        print(f"{language}: {len(keys) - len(missing[language])}/{len(keys)} translated")
    if strict:
        for language in LANGUAGES:
            errors += [f"{language}: missing {key!r}" for key in missing[language]]
    for error in errors:
        print("ERROR", error)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
