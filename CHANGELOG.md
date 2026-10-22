# Changelog

Notable changes to Hoard. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **Cached scans take about a fifth of the space.** They are now compressed (LZFSE, in parallel
  chunks, each with a checksum): a whole-disk cache of 4.0 million items went from 560.6 MB to
  115.3 MB, and reading it takes about 0.05 s longer (0.13 s before, 0.17–0.20 s after). Caches
  written by 0.6.1 and earlier are still read; Hoard 0.6.1 and earlier scan again instead of reading
  a new cache.

### Fixed

- **Cached scans were never removed.** On one Mac `~/Library/Caches/Hoard` reached 1.1 GB, including
  caches for folders that no longer exist. Once per launch, after the first folder is opened, the app
  now removes caches whose folder is gone (a folder on a disk that is not connected is not gone),
  caches not used for 30 days, ones whose header it cannot read, and temporary files left by saves
  that never finished. These are Hoard's own files; the
  history behind Recent Changes is never removed, nothing of yours is touched, and the CLI never
  removes caches. (`SnapshotCacheTests`)

## [0.6.1] - 2026-10-22

### Added

- **What's New.** After an update, Hoard shows once what changed in that version (Help › What's New
  in Hoard opens it again). The notes ship inside the app; Hoard still makes no network connections.
  The Help menu also links to the What Is System Data? page in the app's language.
- **Check for Updates…** (Hoard menu) opens the Releases page; when the command-line tool came from
  Homebrew it can run `brew upgrade operonlab/tap/hoard` in Terminal. Hoard itself still makes no
  network connections.
- **Cleanup moves many items to the Trash in one go.** Check suggestions one by one or with Select
  All in This Category, then confirm once; Move All to Trash does it for every listed suggestion.
  Items that cannot go (protected, system folders, inside a package) are left out instead of
  blocking the batch; the confirmation says how many and why, naming the first three. ⌘Z puts the
  whole batch back.
- **Duplicate Files: pick copies across groups.** Keep One picks every copy but one in a group; Keep
  One of Each does it for every confirmed group, keeping the first copy in path order. A group can
  never lose its last copy.
- **Similar Photos: pick photos and move them together**, or use Keep the Suggested One in a group.
- **What is System Data?** A page in four languages (`docs/system-data*.md`) explains each line of
  the Unaccounted Space card and why Hoard's Used space differs from Storage settings.

### Changed

- **Duplicate Files can start at 1 MB or 10 MB**, not only at 50 MB and up.

### Fixed

- **When several items could not be moved to the Trash, only the last failure was shown**, because
  each failure replaced the one before. All of them are now listed in one alert.
- **The Move to Trash confirmation said almost every item shares disk space with other files.** It
  took any APFS clone ID as sharing, and every file on APFS has one. Sharing now means a hardlink or
  a full APFS clone, the same rule the Cleanup suggestions already used; both read it from
  `Node.sharesStorage` (`FileTreeTests.testSharesStorageIgnoresAPlainCloneID`).

- **Recent Changes overstated how much grew.** The Larger and Smaller totals added up every row,
  but the list shows a folder together with the items inside it, so one new file was counted once
  for itself and again for each listed folder above it: adding 2.9 GB showed "Larger +7.53 GB" next
  to a correct net change of +2.34 GB. Each row now adds only what is left after the listed rows
  inside it are taken out, in its own direction, so changes too small to list still count and Larger
  plus Smaller equals the net change. The rule lives in `TreeDiff.listedTotals` with tests
  (`DiffTotalsTests`).

- **`hoard scan /` counted the data volume twice.** `/` is the read-only system volume. Walked from
  there, the data volume is reached once under `/System/Volumes/Data` and again through the
  firmlinks (`/Users`, `/Applications`, …), so a disk using 340 GB was reported as 611 GB. Only
  `hidden` read `/` as the data volume. Every command that reads sizes (`scan`, `top`, `stale`,
  `types`, `history`, `diff`, `suggest`, `dupes`, `similar`) now does the same, in the CLI and in the
  MCP tools, and their output paths start with `/System/Volumes/Data`. Protection commands keep `/`
  as given. The app was not affected: its whole-disk scan already starts at the data volume.
  History is kept per root, so `history /` and `diff /` now list the data volume's versions;
  versions saved earlier by `hoard scan / --save` are not among them. `scripts/mcp-smoke.sh` checks
  the mapping.

## [0.6.0] - 2026-10-22

First public release.

[Unreleased]: https://github.com/operonlab/hoard/compare/v0.6.1...HEAD
[0.6.1]: https://github.com/operonlab/hoard/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/operonlab/hoard/releases/tag/v0.6.0
