<!-- doctype: contract -->
# Hoard JSON schema: `hoard/1`

Pass `--json` to any command. Each response is one JSON object with
`"schema": "hoard/1"`; additions may be made in a later schema version.
Paths are absolute, byte quantities are JSON integers, durations are seconds,
and dates are ISO 8601 UTC strings. `null` means the value is unavailable.

MCP tool results carry these same `hoard/1` objects as JSON in `content`
text and, for clients using the supported protocol, in `structuredContent`.

`scan_status` is one of `complete`, `partial`, or `unavailable`. A `partial`
size is a lower bound. An `unavailable` directory has an unknown size; it must
not be interpreted as zero. With `--strict`, a non-complete result exits 3.

## Common scan result

`scan`, `top`, `stale`, `types`, `suggest`, `dupes`, `similar`, and `snapshot` include this scan summary.

| Field | Type | Meaning |
| --- | --- | --- |
| `schema` | string | Schema identifier, always `hoard/1`. |
| `command` | string | Invoked command. |
| `path` | string | Absolute scanned root. For `snapshot`, the snapshot's saved root. |
| `source` | string | `scan` for a new scan, `snapshot+replay` for a current loaded snapshot (`snapshot` for the direct snapshot command). |
| `snapshot_age_seconds` | number or null | Age of a loaded snapshot; `null` for a new scan. |
| `scan_status` | string | Completeness of the scanned root. |
| `total_alloc` | integer or null | Counted allocated bytes after deduplication; `null` when the root is unavailable. |
| `total_logical` | integer or null | Logical bytes before filesystem allocation rounding; `null` when the root is unavailable. |
| `files` | integer | Number of files under the root. `diff` uses this name differently. |
| `dirs` | integer | Number of directories under the root. |

An entry in `scan`, `top`, or `stale` has these fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `path` | string | Absolute entry path. |
| `bytes` | integer or null | Allocated bytes counted for this file or directory; `null` when the entry is unavailable. |
| `files` | integer | Files in the entry's subtree; `1` for a file. |
| `is_dir` | boolean | Whether the entry is a directory. |
| `scan_status` | string | Completeness of this entry. |

## `scan`

Extra fields: `seconds` (number, scan duration), `mode` (string: `sequential`
or `parallel(N)`), `saved` (boolean, whether `--save` was requested), and
`entries` (array of common entries, limited by `--top`). `source` is `scan` and
`snapshot_age_seconds` is `null`.

```json
{
  "schema": "hoard/1",
  "command": "scan",
  "path": "/Users/example/workshop",
  "source": "scan",
  "snapshot_age_seconds": null,
  "scan_status": "complete",
  "total_alloc": 734003200,
  "total_logical": 712000000,
  "files": 1200,
  "dirs": 120,
  "seconds": 1.24,
  "mode": "parallel(8)",
  "saved": true,
  "entries": [{"path": "/Users/example/workshop/build", "bytes": 419430400, "files": 200, "is_dir": true, "scan_status": "complete"}]
}
```

## `top`

Extra fields: `kind` (string, `files` or `dirs`), `depth` (integer or null,
the directory depth limit), and `entries` (array of common entries, limited by
`--limit`). `source` and `snapshot_age_seconds` identify whether the result
came from a valid cached snapshot or a scan.

```json
{
  "schema": "hoard/1",
  "command": "top",
  "path": "/Users/example/workshop",
  "source": "snapshot",
  "snapshot_age_seconds": 42.5,
  "scan_status": "complete",
  "total_alloc": 734003200,
  "total_logical": 712000000,
  "files": 1200,
  "dirs": 120,
  "kind": "files",
  "depth": null,
  "entries": [{"path": "/Users/example/workshop/archive.tar", "bytes": 209715200, "files": 1, "is_dir": false, "scan_status": "complete"}]
}
```

## `stale`

Extra fields describe the applied query and Spotlight confirmation:

| Field | Type | Meaning |
| --- | --- | --- |
| `cutoff` | string | UTC cutoff date; files last accessed and modified before it qualify. |
| `min_size` | integer | Minimum counted allocated bytes. |
| `spotlight_checked` | boolean | Whether Finder last-opened metadata was consulted. |
| `excluded_recently_opened` | integer | Shortlisted files excluded because Spotlight says they were opened after the cutoff. |
| `spotlight_unknown` | integer | Returned files for which Spotlight had no last-opened date. |
| `entries` | array | Common entries plus `accessed_at` and `modified_at`. |

`accessed_at` and `modified_at` are UTC strings or `null`. APFS access time is
conservative, and a `null` Spotlight date means unknown rather than never used.

```json
{
  "schema": "hoard/1",
  "command": "stale",
  "path": "/Users/example/workshop",
  "source": "snapshot",
  "snapshot_age_seconds": 42.5,
  "scan_status": "partial",
  "total_alloc": 734003200,
  "total_logical": 712000000,
  "files": 1200,
  "dirs": 120,
  "cutoff": "2026-04-23T00:00:00Z",
  "min_size": 50000000,
  "spotlight_checked": true,
  "excluded_recently_opened": 1,
  "spotlight_unknown": 2,
  "entries": [{"path": "/Users/example/workshop/old.iso", "bytes": 104857600, "files": 1, "is_dir": false, "scan_status": "complete", "accessed_at": "2025-01-10T00:00:00Z", "modified_at": "2025-01-10T00:00:00Z"}]
}
```

## `types`

`entries` is an array limited by `--limit`. Each item has `extension` (string,
lowercase extension without the dot; empty string means no extension), `bytes`
(integer counted allocated bytes), and `files` (integer count).

```json
{
  "schema": "hoard/1",
  "command": "types",
  "path": "/Users/example/workshop",
  "source": "snapshot",
  "snapshot_age_seconds": 42.5,
  "scan_status": "complete",
  "total_alloc": 734003200,
  "total_logical": 712000000,
  "files": 1200,
  "dirs": 120,
  "entries": [{"extension": "zip", "bytes": 209715200, "files": 4}]
}
```

## `history`

`history` does not open a tree and returns `schema`, `command` (`history`),
`path` (absolute requested root), and `versions` (newest first). Each version
has `id` (sortable UTC identifier), `created_at` (UTC date), `total_alloc`
(integer or `null` when unavailable), `files` (integer), `dirs` (integer), `scan_status` (string), and
`stored_bytes` (integer size of the saved history file).

```json
{
  "schema": "hoard/1",
  "command": "history",
  "path": "/Users/example/workshop",
  "versions": [{"id": "20261020T040512Z", "created_at": "2026-10-20T04:05:12Z", "total_alloc": 734003200, "files": 1200, "dirs": 120, "scan_status": "complete", "stored_bytes": 8192}]
}
```

## `diff`

The response has `schema`, `command` (`diff`), `path`, `scan_status`, `source`,
and `snapshot_age_seconds`. `source` is `history` when `--to` names a saved
version; it is `snapshot` or `scan` when `--to now` obtains the current tree.

| Field | Type | Meaning |
| --- | --- | --- |
| `from_id` | string | Selected history version ID. |
| `to_id` | string | `now` or the selected saved version ID. |
| `from_date`, `to_date` | string | UTC dates represented by the compared summaries. |
| `total_before`, `total_after`, `total_delta` | integer or null | Counted allocated bytes before, after, and their difference; `null` when either compared root is unavailable. |
| `grown`, `shrunk` | array | Directory-change arrays, ordered by the diff engine. |
| `files` | array | Big-file change array. This replaces the root file count used by scan commands. |

Each directory change has `path` (absolute string), `kind` (`added`, `removed`,
or `changed`), `before`, `after`, `delta`, `files_before`, and `files_after`
(all integers except `path` and `kind`). Each file change has `path`, `kind`
(`added`, `removed`, `grown`, or `shrunk`), `before`, `after`, and `delta`.

```json
{
  "schema": "hoard/1",
  "command": "diff",
  "path": "/Users/example/workshop",
  "scan_status": "complete",
  "source": "snapshot",
  "snapshot_age_seconds": 42.5,
  "from_id": "20261020T040512Z",
  "to_id": "now",
  "from_date": "2026-10-20T04:05:12Z",
  "to_date": "2026-10-20T05:05:12Z",
  "total_before": 734003200,
  "total_after": 838860800,
  "total_delta": 104857600,
  "grown": [{"path": "/Users/example/workshop/build", "kind": "changed", "before": 419430400, "after": 524288000, "delta": 104857600, "files_before": 200, "files_after": 205}],
  "shrunk": [],
  "files": [{"path": "/Users/example/workshop/build/output.bin", "kind": "grown", "before": 0, "after": 104857600, "delta": 104857600}]
}
```

## `snapshot`

The common scan result describes the snapshot tree. Its extra fields are
`snapshot_file` (absolute input file), `created_at` (UTC date of the snapshot),
`scan_seconds` (number from the original scan), `last_event_id` (integer FSEvents
position), `nodes` (integer stored node count), `files_10mb_plus` (integer
counted files with at least 10 MiB allocated), and `read_seconds` (number spent
reading the snapshot).

```json
{
  "schema": "hoard/1",
  "command": "snapshot",
  "path": "/Users/example/workshop",
  "source": "snapshot",
  "snapshot_age_seconds": 42.5,
  "scan_status": "complete",
  "total_alloc": 734003200,
  "total_logical": 712000000,
  "files": 1200,
  "dirs": 120,
  "snapshot_file": "/Users/example/Library/Caches/Hoard/abc.dscan",
  "created_at": "2026-10-20T05:05:12Z",
  "scan_seconds": 1.24,
  "last_event_id": 12345,
  "nodes": 1320,
  "files_10mb_plus": 8,
  "read_seconds": 0.02
}
```

## Read-only insights

`suggest <path> [--min-size SIZE] [--limit N]` uses a current scan or a valid
snapshot with event replay. `suggestions` is ordered by counted allocated bytes.
Each entry has `path`, `bytes` (integer or `null`), `scan_status`, `category`
(`build_artifact`, `package_cache`, `app_cache`, `app_leftover`, `installer`, `old_log`), `safety`
(`regenerable`, `redownloadable`, `review`), `rule_id`, `reason`, `evidence`,
`newest_modified_at` (UTC or `null`), `shared_files`, `protected` (`lock`,
`guard`, or `null`: the entry itself or a folder above it), and
`contains_protected` (how many protected items are inside the entry). An entry
with `contains_protected > 0` is not safe to trash; the app refuses it.
`total_bytes` includes entries omitted by `--limit`; `total_status`, `omitted`,
and `skipped` explain its coverage. Human output prefixes lower bounds with `≥`
and ends with a reminder that Hoard does not delete files.
`app_leftover` is always `review` tier: it describes data whose app was not found,
not data safe to delete automatically. If installed apps cannot be listed reliably,
each scanned leftover location appears in `skipped` with reason
`installed_apps_unknown` and no leftover suggestion is made. A folder counts as
belonging to an installed app when its name matches a bundle id (or one is a
prefix of the other), an app or command-line tool or Homebrew formula name, a
launch agent label, an id LaunchServices knows, or, for a name without dots, the
vendor part of an installed bundle id (`Google` for `com.google.Chrome`).

The `installers` (`.pkg`, `.xip`), `disk_images` (`.dmg`, `.iso`), and
`downloaded_zip` (`.zip`) rules cover files at any depth under `~/Downloads`,
`~/Desktop`, `~/Documents`, `~/Library/Downloads`, and
`~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads`. They require
at least 30 days without recorded use. A pkg or xip is `redownloadable` only
when macOS download metadata supplies an HTTP(S) origin; otherwise it remains
`review`. Origin evidence is `downloaded from <scheme://host>` and omits URL
paths, queries, and tokens. Disk images remain `review` and include the same
origin evidence when known. A zip known to contain no installer is omitted; one
known to contain an installer has evidence `holds an installer (.app/.pkg/.dmg/.xip)`.
When the archive cannot be inspected, its review suggestion remains and has no
installer-content evidence. Files with no local data blocks are not opened to
check archive contents.

`dupes <path> [--min-size SIZE] [--limit N] [--timeout SECONDS]` reports
`status` (`complete`, `partial`, `cancelled`), `tree_status`, `candidate_files`,
`pending_files`, `bytes_read`, `omitted`, `skipped`, and `groups`. Each group has
`logical_size`, `reclaimable_bytes`, `reclaimable_alloc_lower_bound`, `stage`
(`size`, `edges`, `bytes`), and `members`. A member has `path`, `aliases`,
`alloc_bytes`, and `shares_storage`. Only `bytes` means checked to EOF; a
cancelled result can contain `edges` groups that still need confirmation, and
those have `reclaimable_bytes` and `reclaimable_alloc_lower_bound` `null`. A
skipped entry has `path`, `reason` (`unreadable`, `changed`, or `not_local`: no
data blocks on this Mac, such as an iCloud placeholder, so it was not read), and
`detail`. For the CLI, `--timeout` starts after the scan; the MCP deadline
includes the scan.

`similar <path> [--min-size SIZE] [--threshold X] [--limit N] [--timeout SECONDS]`
finds photos that look alike. This is a review aid: **similar does not mean
identical**. The default minimum is 100 KB; the threshold is Euclidean distance
between Vision feature prints, with smaller values being stricter. The default
0.45 comes from 131 real images. Re-encoded, half-size and PNG copies of the same
image were at most 0.66 apart, with a median of 0.04. Only a few pairs of
different images came within 0.45, and most of those were near-copies kept in two
folders. Above 0.55, unrelated images start to merge into large groups. Groups
are formed around a leader: images are visited best first (most pixels, then
largest file, then newest), and each image that is not yet in a group takes every
other ungrouped image within the threshold of itself. So every member is similar
to `suggested_keep`, which is that leader. The result
has `status` (`complete`, `partial`, `cancelled`), `tree_status`, `revision`,
`threshold`, `candidate_files`, `processed_files`, `pending_files`,
`images_per_second`, `reclaimable_bytes` (null when cancelled or partial),
`omitted`, `skipped` (at most 100; `skipped_omitted` counts the rest and
`skipped_by_reason` counts all skips by reason), and `groups`. A group has
`similar_not_identical: true`, `partial`, `suggested_keep` (node id),
`reclaimable_bytes` (null for partial groups), `members` (at most 50) and
`members_omitted`. Members have `path`, `node`, `aliases`, `width`,
`height`, `logical_bytes`, `allocated_bytes`, and `shared_storage`. Missing
dimensions are null. Skips have `path`, `reason` (`not_local`, `changed`, or
`unreadable`), and `detail`. `not_local` files are never opened. Shared storage
is counted once. No CLI or MCP call deletes or trashes images. The CLI timeout
also covers its scan; the MCP deadline is 60 seconds.

A result cancelled before its scan finished does not have the common scan fields
(`source`, `total_alloc`, `files`, `dirs`, ...). `suggest` then has `schema`,
`command`, `path`, `status: "cancelled"`, `scan_status: "unavailable"`, empty
`suggestions` and `skipped`, `total_bytes: null`, `total_status: "unavailable"`,
and `omitted: 0`. `dupes` has `schema`, `command`, `path`, `status`,
`scan_status` and `tree_status` (`unavailable`), empty `groups` and `skipped`,
and zero `candidate_files`, `pending_files`, `bytes_read`, and `omitted`.
`similar` likewise has empty groups and skips, unavailable scan status, the
requested revision, and null reclaimable bytes.

`hidden [<path>]` defaults to `/System/Volumes/Data`, the data volume (`/` is the
sealed system snapshot, which would count the system twice). It has `source`, `status` (`complete`,
`partial`, `unavailable`, or `cancelled`), `mount_point`
(string or `null`), `covers_volume`, and `lines`. Each line has `id`, `label`,
`bytes` (integer or `null`), `state` (`measured`, `estimated`, `unknown`),
`kind` (`volume`, `part`, `detail`), `count` (integer or `null`), and `how`.
An `unknown` line always has `bytes: null`. `unreadable_folders` lists up to 100
folders from the scan, each with `path`, `reason`, `errno` (number or `null`), and
`owner` (short user name or `null`). Reasons are `needs_full_disk_access`,
`system_protected`, `permission`, `file_permissions`, `not_downloaded`, `gone`,
`readable_now`, `error`, and `unknown`; checking stops after 3 seconds and the folders
not checked by then are `unknown`. `unreadable_total` counts all matching
folders, including those not listed; `unreadable_by_reason` counts the listed
entries. Without a tree these are `[]`, `null`, and `{}` respectively. When the scan does not finish in
time (`source: "scan_cancelled"`), the volume lines are still measured and the
scan-based lines (`scanned`, `unreadable`, `unexplained`) are `unknown`. If even
the volume probes miss the MCP deadline, the answer is `status: "cancelled"`,
`source: "deadline"`, `mount_point: null`, `covers_volume: false`, and no lines.

`apps [--limit N]` has `status` (`complete`, `partial`, or `cancelled`),
`apps`, `unreadable`, and `omitted`. Apps are
sorted by bundle plus exclusive data size. Each app has `path`, `link_target`,
`name`, `bundle_id`, `team_id`, `is_apple`, `app_size`, `app_sized_from`, `data`,
`shared_data`, `last_used`, and `locations`. A size object has `bytes` (integer
or `null`) and `status`. Each location has `path`, `kind`, `matched_by`,
`matched_id`, `size`, `sized_from`, `is_symlink`, and `shared_with`.

`uninstall-plan <app path | bundle id | app name> [--json]` returns `schema`,
`command`, `app_path`, `name`, `bundle_id`, `refusal`, `app_needs_admin` (boolean), `items`, `kept`, and
`total_default`. Each item has `path`, `role`, `kind`, `size`, `why`, and
`selected_by_default`; each kept entry has `path` and `why`. The MCP equivalent
is `disk_uninstall_plan` with input `app`. Both are read-only; nothing is removed.

The MCP equivalents are `disk_suggest`, `disk_duplicates`,
`disk_similar_images`, `disk_hidden_space`, and `disk_apps`. `min_size_mb` is
decimal MB. Their deadlines are 60, 60, 60, 20, and 60 seconds respectively;
duplicates accepts `timeout_seconds` up to 300.

## Doctor

`hoard doctor --json` and `disk_doctor` return `schema: "hoard/1"`,
`command: "doctor"`, `os_version`, `verified_on: "macOS 27"`, `untested`
(running major version differs from 27), `checks`, and `summary`. Each check
has `id`, Chinese `title` and `detail`, `status` (`ok`, `unknown`, or
`problem`), and `affects` (the Hoard feature at risk). `summary` counts
`ok`, `unknown`, and `problem`. A check that cannot finish is `unknown` with
its reason. CLI exit codes are 1 for any problem, 3 for unknown without a
problem, and 0 when all checks pass. The MCP tool has no input and a 30-second
child deadline.

## Cleanup log and completion

`hoard cleanup-log [--limit N] [--json]` lists recent items the app recorded
moving to the Trash, newest first, without those it put back with ⌘Z. The log
cannot know about an item put back from the Finder or deleted by emptying the
Trash, and the app keeps only its last 1,000 lines. It reads
`Application Support/<HoardStorage.folderName>/cleanup-log.jsonl` without
creating or trimming it. `HOARD_CLEANUP_LOG` can override the file only
inside the system temp directory for tests. The default limit is 20; the
maximum is 1000. `omitted` counts older entries beyond the limit;
`total_bytes` covers every entry in the kept log, listed or not.

The JSON result has `schema`, `command: "cleanup-log"`, `status` (`complete` or
`unavailable`), `log` (a `~`-shortened path, or `"none"` when missing),
`entries`, `total_bytes`, and `omitted`. Each entry has `date` (ISO 8601),
`path`, `bytes`, `source`, and `partial`. `total_bytes` is `null` if any live
entry has a partial size; human output marks that entry with `≥`. A missing
file returns `status: "complete"`, `log: "none"`, and empty entries. An unreadable
file returns `status: "unavailable"`, `reason`, and `total_bytes: null`.

`disk_cleanup_log` exposes the same result through MCP with optional `limit`
and a 10-second deadline. It is read-only and runs in a child process.

`hoard completion <zsh|bash|fish>` prints a shell completion script. It
does not emit JSON; an unknown shell is a usage error (exit 2). For zsh:

```sh
hoard completion zsh > ~/.zfunc/_hoard
```

## Protection

`protect`, `protected`, and `guardian` use the protection store named by
`HOARD_PROTECTION_DIR` when it is set (an empty value is a runtime error),
otherwise `~/Library/Application Support/Hoard/Protection`. No command or
MCP tool removes protection; a human does that in the Hoard app.

A protected item has these fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Full protection id as the engine produced it; never truncated. |
| `path` | string | Real path with symlinks resolved (for example `/private/var/...`). |
| `kind` | string | `lock` (cannot be deleted, moved or replaced) or `guard` (restored after deletion). |
| `is_dir` | boolean | Whether the protected item is a folder. |
| `created_at` | string | UTC date the protection was added. |
| `created_by` | string | `cli`, `mcp:<client name>` (control characters stripped, at most 64 characters), or the app's value. |
| `note` | string or null | Free-text note given when the protection was added. |

Health is reported next to an item:

| `health` | Meaning |
| --- | --- |
| `intact` | Lock ACLs are present, or the guard's vault copy is present and locked. |
| `acl_missing` | A lock ACL or a vault ACL was removed. Hoard does not re-apply it, since a human may have removed it on purpose. |
| `vault_missing` | The guard has no vault copy; a deletion cannot be restored. |
| `item_missing` | The protected path is gone. Only here, `restorable` (boolean) says whether a vault copy can bring it back. |

### `protect`

`hoard protect <path> (--lock | --guard) [--note <text>]`. The response
has `item` (a protected item), `health`, and `restorable` when `health` is
`item_missing`. Refusals from the engine (volume root, `/System`, home, already
covered, guard across volumes, oversized folders) exit 1 with the reason;
passing both or neither of `--lock` and `--guard` exits 2.

```json
{
  "schema": "hoard/1",
  "command": "protect",
  "health": "intact",
  "item": {"id": "0F8E6C3A-4B2D-4E1F-9A7C-5D3B2A1E0F9C", "path": "/Users/example/workshop/notes", "kind": "guard", "is_dir": true, "created_at": "2026-10-20T05:05:12Z", "created_by": "cli", "note": null}
}
```

### `protected`

`hoard protected [<path>]`. `items` lists every protected item with its
`health` (and `restorable`) merged in. `path` is the requested path or `null`.
With a path, `covering` is the item that protects it (same shape) or `null`;
without one, `covering` is absent. `registry_error` is `null`, or the reason the
registry could not be read; the answer then comes from the last good copy or is
empty. An unreadable registry with an empty list emits the JSON and exits 1:
protection is unknown, not absent. Through MCP (`disk_protected`) that case is
a tool error (`isError: true`) carrying the reason.

```json
{
  "schema": "hoard/1",
  "command": "protected",
  "path": "/Users/example/workshop/notes/todo.md",
  "registry_error": null,
  "items": [{"id": "0F8E6C3A-4B2D-4E1F-9A7C-5D3B2A1E0F9C", "path": "/Users/example/workshop/notes", "kind": "guard", "is_dir": true, "created_at": "2026-10-20T05:05:12Z", "created_by": "mcp:claude-code", "note": null, "health": "item_missing", "restorable": true}],
  "covering": {"id": "0F8E6C3A-4B2D-4E1F-9A7C-5D3B2A1E0F9C", "path": "/Users/example/workshop/notes", "kind": "guard", "is_dir": true, "created_at": "2026-10-20T05:05:12Z", "created_by": "mcp:claude-code", "note": null, "health": "item_missing", "restorable": true}
}
```

### `guardian`

`hoard guardian --once` runs one restore pass and returns `mode` (`once`)
and `restored` (array of paths recreated from the vault, possibly empty). A
pass that cannot restore every guarded item exits 1 with the reason.

```json
{"schema": "hoard/1", "command": "guardian", "mode": "once", "restored": ["/Users/example/workshop/notes/todo.md"]}
```

Without `--once`, `guardian` runs until SIGINT or SIGTERM. Each action writes
one line to standard error: `restored <path>`, `refreshed <path>` (the vault
copy was updated after an edit), or `error <path>: <message>`; control
characters in paths are shown as `\u{..}` escapes. With `--json`, each action is
also one JSON object per line on standard output. `path` is `registry` when the
protection list could not be read, and `startup` when the restore pass at start
failed without any guarded item missing.

```json
{"action": "restored", "command": "guardian", "message": null, "path": "/Users/example/workshop/notes/todo.md", "schema": "hoard/1"}
```

## Errors

JSON is emitted only for successful command execution, except `protected`
with an unreadable registry and no items, which emits its JSON and exits 1. A
usage error writes a message to standard error and exits 2. A runtime error
writes a message to standard error and exits 1; this includes `history not
available in this build` when history storage has not been implemented. A
strict partial result exits 3 after emitting its JSON result.
