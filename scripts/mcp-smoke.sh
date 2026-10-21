#!/usr/bin/env bash
set -eu

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
binary="$repo_root/.build/debug/hoard"
python="$HOME/.local/bin/python3"
if [[ ! -x "$binary" ]]; then
  echo "MCP smoke: missing $binary; build hoard first" >&2
  exit 1
fi
# pwd -P: protection records real paths (/private/var/...), so compare against those.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
# The guard vault carries deny-delete ACLs; strip them inside this temp dir only.
trap 'chmod -R -N "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
export HOARD_MCP_TEST_DIR="$tmp"
export HOARD_PROTECTION_DIR="$tmp/store"
export HOARD_CLEANUP_LOG="$tmp/cleanup-log.jsonl"
"$python" -c 'import os; from pathlib import Path; p=Path(os.environ["HOARD_MCP_TEST_DIR"]); (p/"small.bin").write_bytes(b"a"*4096); (p/"large.bin").write_bytes(b"b"*65536)'
"$python" -c 'import json, os; from pathlib import Path; p=Path(os.environ["HOARD_MCP_TEST_DIR"]); rows=[{"date":"2026-10-20T01:00:00Z","path":str(p/"restored.bin"),"bytes":123,"source":"app","partial":False},{"date":"2026-10-20T02:00:00Z","path":str(p/"kept.bin"),"bytes":456,"source":"app","partial":False},{"date":"2026-10-20T03:00:00Z","path":str(p/"restored.bin"),"bytes":123,"source":"app","partial":False,"restored":True}]; Path(os.environ["HOARD_CLEANUP_LOG"]).write_text("".join(json.dumps(x)+"\n" for x in rows))'

"$python" -c 'import json, os; p=os.environ["HOARD_MCP_TEST_DIR"]; messages=[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}, {"jsonrpc":"2.0","method":"notifications/initialized"}, {"jsonrpc":"2.0","id":2,"method":"tools/list"}, {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"disk_top","arguments":{"path":p,"kind":"files","limit":2}}}, {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"disk_cleanup_log","arguments":{"limit":20}}}, {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"disk_doctor","arguments":{}}}]; [print(json.dumps(m)) for m in messages]; print("{malformed"); print(json.dumps({"jsonrpc":"2.0","id":4,"method":"ping"}))' \
  | "$binary" mcp > "$tmp/responses.jsonl"

"$python" -c 'import json, os; from pathlib import Path; p=Path(os.environ["HOARD_MCP_TEST_DIR"]); rows=[json.loads(line) for line in (p/"responses.jsonl").read_text().splitlines()]; by_id={row.get("id"):row for row in rows}; assert len(rows)==7, f"expected 7 replies, got {len(rows)}"; assert by_id[1]["result"]["serverInfo"]["name"]=="hoard"; names={t["name"] for t in by_id[2]["result"]["tools"]}; assert names=={"disk_top","disk_stale","disk_types","disk_history","disk_diff","disk_scan","disk_protect","disk_protected","disk_restore","disk_suggest","disk_duplicates","disk_similar_images","disk_hidden_space","disk_apps","disk_uninstall_plan","disk_cleanup_log","disk_doctor"}, names; result=by_id[3]["result"]; data=json.loads(result["content"][0]["text"]); assert os.path.realpath(data["entries"][0]["path"])==os.path.realpath(p/"large.bin"), data["entries"]; assert result["structuredContent"]["schema"]=="hoard/1"; log=by_id[5]["result"]["structuredContent"]; assert log["status"]=="complete" and len(log["entries"])==1 and log["entries"][0]["path"]==str(p/"kept.bin") and log["entries"][0]["bytes"]==456 and log["total_bytes"]==456, log; doctor=by_id[6]["result"]["structuredContent"]; assert doctor["command"]=="doctor" and len(doctor["checks"])==9 and sum(doctor["summary"].values())==9, doctor; assert any(row.get("error",{}).get("code")==-32700 for row in rows); assert by_id[4]["result"]=={}; print("MCP smoke: initialize, seventeen tools, largest file, cleanup log, doctor, parse error, recovery: PASS")'

"$python" - "$binary" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

root = Path(os.environ["HOARD_MCP_TEST_DIR"])
project = root / "project"
(project / "node_modules").mkdir(parents=True)
(project / "package.json").write_text('{"name":"smoke"}')
(project / "node_modules" / "cache.bin").write_bytes(b"c" * 2_000_000)
dupes = root / "dupes"
dupes.mkdir()
(dupes / "a.bin").write_bytes(b"a" * 2_000_000)
(dupes / "b.bin").write_bytes(b"a" * 2_000_000)
(dupes / "c.bin").write_bytes(b"b" * 2_000_000)
messages = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}]
messages += [{"jsonrpc": "2.0", "id": n, "method": "tools/call", "params": {"name": name, "arguments": args}}
            for n, (name, args) in enumerate([
                ("disk_suggest", {"path": str(project), "min_size_mb": 1}),
                ("disk_duplicates", {"path": str(dupes), "min_size_mb": 1}),
                ("disk_hidden_space", {"path": str(project)}),
                ("disk_apps", {"limit": 1}),
                ("disk_duplicates", {"path": str(dupes), "min_size_mb": 1, "timeout_seconds": 0}),
                ("disk_similar_images", {"path": str(project), "min_size_mb": 0, "limit": 5}),
            ], 1)]
server = subprocess.run([sys.argv[1], "mcp"], input="".join(json.dumps(x) + "\n" for x in messages),
                        text=True, capture_output=True, timeout=150)
assert server.returncode == 0, server.stderr
rows = {row["id"]: row["result"]["structuredContent"] for row in map(json.loads, server.stdout.splitlines()) if row["id"] != 0}
suggest = rows[1]
assert any(os.path.realpath(x["path"]) == os.path.realpath(project / "node_modules") and x["category"] == "build_artifact" and x["protected"] is None
           for x in suggest["suggestions"]), suggest
groups = rows[2]["groups"]
assert len(groups) == 1 and len(groups[0]["members"]) == 2 and groups[0]["reclaimable_bytes"] == 2_000_000, rows[2]
hidden = rows[3]
assert hidden["lines"] and all("state" in line and (line["bytes"] is None) == (line["state"] == "unknown")
                               for line in hidden["lines"]), hidden
assert isinstance(rows[4]["apps"], list) and rows[4]["schema"] == "hoard/1", rows[4]
assert rows[5]["status"] == "cancelled" and all(k in rows[5] for k in
       ("tree_status", "candidate_files", "pending_files", "bytes_read", "omitted", "skipped", "groups")), rows[5]
similar = rows[6]
assert similar["status"] == "complete" and similar["groups"] == [] and similar["candidate_files"] == 0 and all(k in similar for k in
       ("revision", "threshold", "processed_files", "images_per_second", "skipped", "reclaimable_bytes")), similar
empty_store = root / "empty-store"
empty_store.mkdir()
env = os.environ.copy()
env["HOARD_PROTECTION_DIR"] = str(empty_store)
read_only = subprocess.run([sys.argv[1], "suggest", str(project), "--min-size", "1MB", "--json"],
                           env=env, text=True, capture_output=True, timeout=10)
assert read_only.returncode == 1 and not (empty_store / "registry.lock").exists(), read_only
print("MCP smoke: suggest, duplicates, similar images, hidden space, apps: PASS")
PY

# Stream a 64 MiB line, then check recovery and peak RSS. macOS time -l is unavailable
# inside some sandboxes (kern.clockrate sysctl); resource.getrusage gives the same child RSS there.
if /usr/bin/time -l true >/dev/null 2> "$tmp/time-probe.txt"; then
  "$python" -c 'import sys; out=sys.stdout.buffer; block=b"x"*65536; [out.write(block) for _ in range(1024)]; out.write(b"\n{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"ping\"}\n"); out.flush()' \
    | /usr/bin/time -l "$binary" mcp > "$tmp/large-responses.jsonl" 2> "$tmp/mcp-time.txt"
  "$python" -c 'import json, os, re; from pathlib import Path; p=Path(os.environ["HOARD_MCP_TEST_DIR"]); rows=[json.loads(x) for x in (p/"large-responses.jsonl").read_text().splitlines()]; assert len(rows)==2, rows; assert rows[0].get("error",{}).get("code")==-32600 and rows[0].get("id") is None, rows[0]; assert rows[1].get("id")==99 and rows[1].get("result")=={}, rows[1]; m=re.search(r"(\d+)\s+maximum resident set size", (p/"mcp-time.txt").read_text()); assert m, (p/"mcp-time.txt").read_text(); rss=int(m.group(1)); assert rss<100*1024*1024, f"peak RSS {rss} bytes exceeds 100 MiB"; print(f"MCP smoke: 64 MiB rejection, next request, peak RSS {rss/1048576:.1f} MiB (time -l): PASS")'
else
  "$python" - "$binary" <<'PY'
import json, resource, subprocess, sys
server = subprocess.Popen([sys.argv[1], "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
block = b"x" * 65536
for _ in range(1024):
    server.stdin.write(block)
server.stdin.write(b'\n{"jsonrpc":"2.0","id":99,"method":"ping"}\n')
server.stdin.close()
rows = [json.loads(line) for line in server.stdout]
assert server.wait(timeout=10) == 0
assert len(rows) == 2, rows
assert rows[0].get("error", {}).get("code") == -32600 and rows[0].get("id") is None, rows[0]
assert rows[1].get("id") == 99 and rows[1].get("result") == {}, rows[1]
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
assert rss < 100 * 1024 * 1024, f"peak RSS {rss} bytes exceeds 100 MiB"
print(f"MCP smoke: 64 MiB rejection, next request, peak RSS {rss/1048576:.1f} MiB (rusage fallback): PASS")
PY
fi

# The delete has to land between disk_protect and disk_restore, so drive the server one request at a time.
"$python" - "$binary" <<'PY'
import json, os, subprocess, sys

binary = sys.argv[1]
target = os.path.join(os.environ["HOARD_MCP_TEST_DIR"], "guarded.txt")
with open(target, "wb") as f:
    f.write(b"guarded by the MCP smoke\n")
original = open(target, "rb").read()
server = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

def call(i, method, params=None):
    message = {"jsonrpc": "2.0", "id": i, "method": method}
    if params is not None:
        message["params"] = params
    server.stdin.write(json.dumps(message) + "\n")
    server.stdin.flush()
    line = server.stdout.readline()
    assert line, f"no reply to {method}"
    reply = json.loads(line)
    assert reply.get("id") == i, reply
    return reply

def tool(i, name, arguments):
    result = call(i, "tools/call", {"name": name, "arguments": arguments})["result"]
    assert not result.get("isError"), result
    return result["structuredContent"]

try:
    # The BEL must be stripped from the recorded creator.
    call(1, "initialize", {"protocolVersion": "2025-06-18", "clientInfo": {"name": "mcp-smoke\u0007", "version": "1"}})
    added = tool(2, "disk_protect", {"path": target, "kind": "guard", "note": "smoke"})
    item = added["item"]
    assert item["kind"] == "guard" and item["path"] == target and item["created_by"] == "mcp:mcp-smoke", item
    assert added["health"] == "intact" and len(item["id"]) >= 32, added
    os.remove(target)
    restored = tool(3, "disk_restore", {})
    assert target in restored["restored"], restored
    assert open(target, "rb").read() == original, "restored bytes differ"
    listing = tool(4, "disk_protected", {"path": target})
    assert listing["registry_error"] is None, listing
    assert listing["covering"]["id"] == item["id"] and listing["covering"]["health"] == "intact", listing
    bad = call(5, "tools/call", {"name": "disk_protect", "arguments": {"path": target, "kind": "none"}})
    assert bad["error"]["code"] == -32602, bad
    # A request line over 1 MB is refused without parsing (so the id is unknown) and the server keeps serving.
    big = json.dumps({"jsonrpc": "2.0", "id": 6, "method": "ping", "params": {"pad": "x" * (1 << 20)}})
    server.stdin.write(big + "\n")
    server.stdin.flush()
    reply = json.loads(server.stdout.readline())
    assert reply.get("error", {}).get("code") == -32600 and reply.get("id") is None, reply
    assert call(7, "ping")["result"] == {}
    long_note = call(8, "tools/call", {"name": "disk_protect", "arguments": {"path": target, "kind": "guard", "note": "n" * 501}})
    assert long_note.get("error", {}).get("code") == -32602, long_note
    # One visible character carrying 600 combining marks still counts as 601.
    stacked = call(10, "tools/call", {"name": "disk_protect", "arguments": {"path": target, "kind": "guard", "note": "n" + "́" * 600}})
    assert stacked.get("error", {}).get("code") == -32602, stacked
    second = os.path.join(os.environ["HOARD_MCP_TEST_DIR"], "noted.txt")
    open(second, "wb").write(b"noted\n")
    assert tool(9, "disk_protect", {"path": second, "kind": "guard", "note": "n" * 500})["item"]["note"] == "n" * 500
finally:
    server.stdin.close()
    server.wait(timeout=10)
print("MCP smoke: disk_protect guard, delete, disk_restore, disk_protected, size limits: PASS")
PY

# Read through "/", the data volume is counted twice: under /System/Volumes/Data and again through
# the firmlinks (/Users, /Applications, ...). History is the scan-shaped command that answers without scanning.
"$python" - "$binary" <<'PY'
import json, subprocess, sys

binary = sys.argv[1]
cli = json.loads(subprocess.run([binary, "history", "/", "--json"], text=True, capture_output=True, timeout=10, check=True).stdout)
assert cli["path"] == "/System/Volumes/Data", cli
messages = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "disk_history", "arguments": {"path": "/"}}}]
server = subprocess.run([binary, "mcp"], input="".join(json.dumps(m) + "\n" for m in messages),
                        text=True, capture_output=True, timeout=10)
assert server.returncode == 0, server.stderr
reply = next(r for r in map(json.loads, server.stdout.splitlines()) if r["id"] == 1)["result"]
assert not reply.get("isError") and reply["structuredContent"]["path"] == "/System/Volumes/Data", reply
print("MCP smoke: / reads the data volume (history, disk_history): PASS")
PY
