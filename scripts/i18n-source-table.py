"""Writes the zh-Hant strings table: every catalog key mapped to itself.

usage: i18n-source-table.py <catalog> <Resources folder>

xcstringstool writes no table for the source language. With English as the development region (so a
language the app does not have falls back to English), a lookup that finds no zh-Hant table falls
back to English too, and the Chinese UI would show English. This table keeps zh-Hant in Chinese.
"""
import json
import pathlib
import sys


def quoted(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    strings = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["strings"]
    keys = sorted(key for key, entry in strings.items() if entry.get("extractionState") != "stale" and key)
    folder = pathlib.Path(sys.argv[2]) / "zh-Hant.lproj"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Localizable.strings").write_text("".join(f"{quoted(k)} = {quoted(k)};\n" for k in keys), encoding="utf-8")
    print(f"zh-Hant: {len(keys)} keys")


if __name__ == "__main__":
    main()
