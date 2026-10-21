# Hoard — guide for contributors and coding agents

Hoard is a native macOS disk-space map (SwiftUI + AppKit) with a CLI and an MCP server for AI
agents. `CLAUDE.md` is a link to this file.

## Commands

```bash
swift build                                  # all targets
swift test                                   # ScanCore tests
(cd Packages/TreeCore && swift test)         # tree model, snapshots, history, diff (Foundation only)
(cd Packages/LayoutKit && swift test)        # treemap layout (Foundation only)
python3 scripts/i18n-check.py --strict       # every string translated in en, ja, ko
bash scripts/mcp-smoke.sh                    # MCP server, against .build/debug/hoard
bash scripts/protect-smoke.sh                # lock / guard behavior, in a temp dir
.build/debug/hoard doctor --json             # the macOS mechanisms Hoard relies on
scripts/make-app.sh                          # dist/Hoard.app
```

Inside a sandbox that forbids nested `sandbox-exec`, add `--disable-sandbox` and keep caches in the repo:

```bash
export CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
```

## Rules every change keeps

- **Nothing is deleted, moved or trashed except by a person**, through the app's Move to Trash
  confirmation, which refuses protected items. The CLI and MCP tools are read-only except for adding
  protection and putting back a guarded item that was deleted. Removing protection happens only in
  the app.
- **Never download iCloud files.** Scans, file icons and protection run with dataless-file
  materialization turned off (`Sources/ScanCore/Materialization.swift`).
- **Unknown is not zero.** `ScanStatus` is three-state; `partial` and `unavailable` sizes are never
  shown as exact or as zero.
- `TreeCore` and `LayoutKit` import Foundation only, so they build and test on Linux.
- No third-party dependencies.
- Tests build fixtures in a temporary directory and never read or assert on the real home folder.
  A build from a linked git worktree is a development copy: bundle id `com.operonlab.hoard.dev` and
  its own `Hoard Dev` data folders.

## Model

A `FileTree` is built on one thread and then confined to the main queue. Background work produces a
detached `FileTree` or `[ScanEntry]`; the main queue applies it (`graft`, `insert`, `updateFile`,
`removeSubtree`). `totalAlloc` is allocated bytes after hardlink and APFS-clone dedup (the number the
UI shows); `rawAlloc` is what the file system reported.

## Strings

The app's text lives in `Localization/Localizable.xcstrings`; keys are the Traditional Chinese source
text. After changing UI text run `scripts/i18n-sync.sh`, translate the new entries, then
`scripts/i18n-check.py --strict`.

## Releases

`scripts/release.sh <version>` builds the app with an ad-hoc signature and writes to `dist/` the app
zip, the CLI tarball the Homebrew formula installs, and `SHA256SUMS`. `scripts/release-check.sh` scans the tracked files before every push and fails on
patterns given in `RELEASE_CHECK_DENY` (kept out of the repository).
