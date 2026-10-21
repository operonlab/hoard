---
name: hoard
description: >-
  Inspect macOS disk space from the shell with the hoard CLI: largest files and
  folders, long-unused large files, dominant file types, what grew since the last
  saved scan, cleanup candidates (never deletes); protect files and folders from
  accidental deletion (lock / guard) and check protection before bulk deletes.
  Use for 硬碟空間、磁碟用量、哪些檔案最大、很久沒用的大檔、上次掃描後多了哪些空間、
  清理建議、保護、鎖定、防誤刪.
---

<!-- doctype: contract -->
# Hoard agent guide

Use `hoard` to inspect a directory without opening the app. It reports
allocated bytes after hard-link and APFS-clone deduplication. Prefer `--json`
when another program or agent will consume the result.

The CLI reads, scans, saves Hoard snapshots, and adds protection. It never
deletes, moves, or trashes files. Present cleanup candidates to the human; they
choose what to trash in Hoard or Finder.

`hoard uninstall-plan <app path | bundle id | app name> --json` (MCP:
`disk_uninstall_plan` with `app`) lists an app bundle, matching user data,
LaunchAgents, and kept items. It is read-only; nothing is removed. Removal is
available only in the app after a person's confirmation.

## Protection

Threat model: protection guards against accidents, and against an agent whose
only access is Hoard (MCP or CLI). It is not a security boundary against a
program with a shell, which can change ACLs itself. So Hoard refuses every
way its own commands could be steered into harm, and does not try to win races
against a concurrent attacker swapping symlinks.

Before a bulk delete (`rm -r`, a cleanup script, `git clean`), check the target:
`hoard protected <path> --json` (MCP: `disk_protected`). A non-null
`covering` means the path is protected; stop and ask the human. A non-null
`registry_error` means protection is unknown, not absent.

- **lock (鎖定)**: cannot be deleted, moved or replaced; in-place writes still work.
- **guard (守護)**: freely editable; if deleted, Hoard restores its latest copy.

When a delete fails with EPERM or EACCES ("Operation not permitted") on a path
Hoard protects, stop and tell the human which path and what you were doing.
**Never remove ACLs (`chmod -a`, `chmod -N`) or touch the vault
(`~/Library/Application Support/Hoard/Protection`) to get around a
protection.** Removing protection is a human decision made in the Hoard
app's 受保護 list; no command or MCP tool removes it.

After an accidental delete of a guarded file, run `hoard guardian --once`
(MCP: `disk_restore`). It only recreates missing guarded files and never
deletes or overwrites existing ones.

```sh
hoard protect ~/workshop/data/ledger.db --lock --note "live ledger" --json
hoard protect ~/workshop/notes --guard --json
hoard protected ~/workshop/notes/todo.md --json
hoard guardian --once --json
```

Engine refusals (volume root, `/System`, home, launch and login items, already
covered, guard across volumes, oversized folders, guard over 5 GB, a new guard
version with less than 10 GB or 5% of the volume free) exit 1 with the reason.
Some targets only the owner can protect, in the app (「只能在 Hoard app 裡由你本人保護」):
anything under `~/.ssh`, shell startup files in home (`.zshrc`, `.bashrc`,
`.profile`, …) and `~/.config/fish`, including where linked dotfiles really
live, and anything inside an `.app` bundle. Do not retry those another way;
tell the human. Restore never writes through a symlink that replaced a guarded
file or folder; it reports it instead. `hoard guardian` without `--once`
keeps restoring deleted guarded items until SIGINT or SIGTERM.

## Commands

Scan a root and show its largest immediate entries. `--save` also writes the
cached snapshot and a history version for later comparisons.

```sh
hoard scan ~/workshop --top 10 --save --json
```

Show the largest files, or use `--dirs` for folders. The command reads a valid
snapshot when one is available and otherwise scans the root.

```sh
hoard top ~/workshop --files --limit 20 --json
hoard top ~/workshop --dirs --depth 2 --limit 20 --json
```

Find large files whose recorded access and modification times predate the
cutoff. Spotlight removes shortlisted files that Finder records as opened more
recently. Add `--no-spotlight` only when that confirmation is unsuitable.

```sh
hoard stale ~/workshop --days 180 --min-size 50MB --limit 30 --json
```

Summarize file types by counted allocated bytes.

```sh
hoard types ~/workshop --limit 20 --json
```

Find cleanup candidates with evidence and safety labels. `protected` reports a
covering lock or guard; `contains_protected > 0` means protected items are inside
the entry, so do not call it safe to trash. Hoard never removes a suggestion;
inspect it in the app or Finder before choosing what to trash.

```sh
hoard suggest ~/workshop --min-size 50MB --limit 20 --json
```

`app_leftover` candidates are review-tier only; confirm the data is no longer
needed before acting. `skipped` reason `installed_apps_unknown` means installed
apps could not be listed reliably, so no leftover determination was made.

Installer suggestions cover `.pkg`, `.xip`, `.dmg`, `.iso`, and `.zip` below
`~/Downloads`, `~/Desktop`, `~/Documents`, `~/Library/Downloads`, and
`~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads`. They require
30 days without recorded use. A pkg or xip is `redownloadable` only when its
download origin is known; otherwise it is `review`. The evidence shows only
`downloaded from <scheme://host>`, never a URL path or query. Disk images stay
`review`, even with an origin. An inspected zip with no installer is omitted;
an inspected zip with one says `holds an installer (.app/.pkg/.dmg/.xip)`.
Unreadable zips remain review suggestions without that content evidence.

Find byte-identical files. Only `stage: "bytes"` groups were checked to EOF;
`edges` groups in a cancelled run need confirmation. Reading candidates can
update their access time, so a later `stale` result may differ.

```sh
hoard dupes ~/workshop/outputs --min-size 50MB --limit 20 --timeout 120 --json
```

Find visually similar photos for human review. Similar photos are not identical;
quick look at each one before deciding whether to trash it. Files with no local
data blocks are skipped to avoid downloading cloud placeholders. Results are
read-only and include the Vision revision and threshold used.

```sh
hoard similar ~/Pictures --min-size 100KB --threshold 0.45 --limit 20 --timeout 120 --json
```

Explain measured, estimated, and unknown space, or list application bundles
with matched user data. Unknown bytes are `null`.

```sh
hoard hidden / --json
hoard apps --limit 10 --json
```

List saved versions, then compare one version to another state. Without IDs,
`diff` compares the latest saved version with the current valid snapshot or a
new scan.

```sh
hoard history ~/workshop --json
hoard diff ~/workshop --from 20261020T040512Z --to now --json
```

Inspect a snapshot file directly.

```sh
hoard snapshot ~/Library/Caches/Hoard/example.dscan --json
```

Review what the app recorded moving to the Trash. Items put back with ⌘Z are excluded;
items put back from the Finder or emptied from the Trash cannot be known and stay listed;
`partial: true` means its size is a lower bound. This command only reads the
log, including when the file is missing or unavailable. MCP: `disk_cleanup_log`
with optional `limit` (10-second deadline).

```sh
hoard cleanup-log --limit 20 --json
```

After a macOS upgrade, run `hoard doctor --json` (MCP: `disk_doctor`, no
input). It checks nine macOS assumptions and writes only inside a fresh system
temp folder, which it removes before returning. It does not modify user files
or the protection registry. Each check is `ok`, `unknown` with a reason, or
`problem` with the affected feature. Exit 1 means a problem, 3 means only
unknown checks, and 0 means all checks passed. The MCP child has a 30-second
deadline.

Install shell completion; `completion` supports zsh, bash, and fish:

```sh
hoard completion zsh > ~/.zfunc/_hoard
```

## JSON contract

Every JSON document begins with `"schema": "hoard/1"`. Paths are absolute,
sizes are integer bytes, and dates are ISO 8601 UTC strings. The full field
reference and examples are in [`json-schema.md`](json-schema.md).

Check `scan_status` before acting on sizes. `complete` means the walker read
every entry. `partial` means reported sizes are lower bounds, and `unavailable`
means a directory could not be read and its size is unknown. By default partial
results still exit 0; add `--strict` when a partial result must exit 3. Usage
errors exit 2 and runtime failures exit 1.

For `stale`, an APFS access time is conservative: APFS updates it on a read only
when it is not newer than the modification time. A missing Spotlight date means
the file's last-opened time is unknown, never that the file was never used.

## MCP

Register the stdio server with Claude Code:

```sh
claude mcp add hoard -- hoard mcp
```

For Codex, add this to `~/.codex/config.toml`:

```toml
[mcp_servers.hoard]
command = "hoard"
args = ["mcp"]
```

Use MCP when an agent can call tools directly and needs structured results.
Use the CLI for shell scripts, terminal inspection, and pipelines. Both expose
the same `hoard/1` JSON objects. The MCP tools never delete, move, or trash
files; `disk_scan` with `save: true` records a snapshot and history version,
`disk_protect` adds a lock or guard (recorded as `mcp:<client name>`), and
`disk_restore` recreates deleted guarded files. A request line over 1 MB gets
JSON-RPC error -32600 without being parsed; a `note` over 500 characters gets
-32602.

Read-only tools: `disk_suggest` (`path`, `min_size_mb`, `limit`),
`disk_duplicates` (`path`, `min_size_mb`, `limit`, `timeout_seconds`, at most
300), `disk_similar_images` (`path`, `min_size_mb`, `threshold`, `limit`,
60-second deadline), `disk_hidden_space` (optional `path`, default `/`), and `disk_apps`
(`limit`), and `disk_cleanup_log` (optional `limit`, at most 1000). Duplicate
results may be `complete`, `partial`, or `cancelled`.
