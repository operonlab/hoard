# Changelog

Notable changes to Hoard. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

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

[Unreleased]: https://github.com/operonlab/hoard/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/operonlab/hoard/releases/tag/v0.6.0
