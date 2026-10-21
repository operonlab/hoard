#!/usr/bin/env bash
# Real lock / guard behavior of the hoard CLI, in a temp dir with its own protection registry.
set -u

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
binary="${repo_root}/.build/debug/hoard"
python="${HOME}/.local/bin/python3"
hint="解除保護：在 Hoard app 的「受保護」裡確認。"
if [[ ! -x "${binary}" ]]; then
  echo "PROTECT smoke: missing ${binary}; build hoard first" >&2
  exit 1
fi
# pwd -P: the engine stores real paths (/private/var/...), so compare against those.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
if [[ -z "${tmp}" || ! -d "${tmp}" ]]; then
  echo "PROTECT smoke: could not create a temp dir" >&2
  exit 1
fi
cleanup() {
  # Locked files and the vault carry deny-delete ACLs; strip them inside this temp dir only.
  chmod -R -N "${tmp}" 2> /dev/null
  rm -rf "${tmp}"
}
trap cleanup EXIT
export HOARD_PROTECTION_DIR="${tmp}/store"
mkdir -p "${tmp}/work"

failures=0
pass() { echo "ok   ${1}"; }
fail() { echo "FAIL ${1}" >&2; failures=$((failures + 1)); }

# lock: cannot be deleted or moved; in-place writes still work.
locked="${tmp}/work/locked.txt"
printf 'locked bytes\n' > "${locked}"
"${binary}" protect "${locked}" --lock --note "smoke lock" --json > "${tmp}/lock.json" 2> "${tmp}/lock.err"
rc=$?
if [[ ${rc} -eq 0 ]]; then pass "protect --lock exits 0"; else fail "protect --lock exited ${rc}: $(cat "${tmp}/lock.err")"; fi

if rm -f "${locked}" 2> /dev/null; then
  fail "rm on a locked file succeeded"
elif [[ -e "${locked}" ]]; then
  pass "rm on a locked file fails and the file stays"
else
  fail "rm reported failure but the locked file is gone"
fi
if mv "${locked}" "${tmp}/work/moved.txt" 2> /dev/null; then
  fail "mv of a locked file succeeded"
  mv "${tmp}/work/moved.txt" "${locked}" 2> /dev/null
else
  pass "mv of a locked file fails"
fi
if printf 'appended\n' >> "${locked}" 2> /dev/null; then
  pass "in-place write to a locked file works"
else
  fail "in-place write to a locked file was refused"
fi

"${binary}" protected "${locked}" --json > "${tmp}/protected.json" 2> "${tmp}/protected.err"
rc=$?
if [[ ${rc} -eq 0 ]] && SMOKE_PATH="${locked}" "${python}" -c '
import json, os, sys
d = json.load(open(sys.argv[1]))
p = os.environ["SMOKE_PATH"]
row = next(r for r in d["items"] if r["path"] == p)
assert d["schema"] == "hoard/1" and d["command"] == "protected", d
assert row["kind"] == "lock" and row["health"] == "intact", row
assert row["created_by"] == "cli" and row["note"] == "smoke lock", row
assert len(row["id"]) >= 32, row["id"]
assert d["covering"]["id"] == row["id"] and d["registry_error"] is None, d
' "${tmp}/protected.json"; then
  pass "protected --json shows the lock intact and covering the path"
else
  fail "protected --json (exit ${rc}): $(cat "${tmp}/protected.json" "${tmp}/protected.err")"
fi
last="$("${binary}" protected 2> /dev/null | tail -n 1)"
if [[ "${last}" == "${hint}" ]]; then pass "protected ends with the unprotect hint"; else fail "protected last line: ${last}"; fi

# guard: deletable; guardian --once brings back identical bytes.
guarded="${tmp}/work/guarded.bin"
"${python}" -c 'import os, sys; open(sys.argv[1], "wb").write(os.urandom(70000))' "${guarded}"
cp "${guarded}" "${tmp}/expected.bin"
"${binary}" protect "${guarded}" --guard --json > "${tmp}/guard.json" 2> "${tmp}/guard.err"
rc=$?
if [[ ${rc} -eq 0 ]]; then pass "protect --guard exits 0"; else fail "protect --guard exited ${rc}: $(cat "${tmp}/guard.err")"; fi
rm -f "${guarded}"
if [[ ! -e "${guarded}" ]]; then pass "a guarded file can be deleted"; else fail "a guarded file could not be deleted"; fi
"${binary}" guardian --once > "${tmp}/once.out" 2> "${tmp}/once.err"
rc=$?
if [[ ${rc} -eq 0 ]] && grep -qxF "${guarded}" "${tmp}/once.out"; then
  pass "guardian --once reports the restore"
else
  fail "guardian --once (exit ${rc}): $(cat "${tmp}/once.out" "${tmp}/once.err")"
fi
if cmp -s "${guarded}" "${tmp}/expected.bin"; then pass "restored bytes are identical"; else fail "restored file differs or is missing"; fi

# Refusals and usage.
"${binary}" protect / --lock > /dev/null 2> "${tmp}/root.err"
rc=$?
if [[ ${rc} -eq 1 ]]; then pass "protect / exits 1: $(cat "${tmp}/root.err")"; else fail "protect / exited ${rc}"; fi
"${binary}" protect "${guarded}" --lock --guard > /dev/null 2>&1
rc=$?
if [[ ${rc} -eq 2 ]]; then pass "protect with both flags exits 2"; else fail "protect with both flags exited ${rc}"; fi

# An unreadable registry is unknown, never "nothing is protected".
mkdir -p "${tmp}/broken-store"
printf '{not json' > "${tmp}/broken-store/registry.json"
HOARD_PROTECTION_DIR="${tmp}/broken-store" "${binary}" protected --json > "${tmp}/broken.json" 2> /dev/null
rc=$?
if [[ ${rc} -eq 1 ]] && "${python}" -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["registry_error"] and d["items"] == [], d
' "${tmp}/broken.json"; then
  pass "unreadable registry exits 1 with registry_error"
else
  fail "unreadable registry (exit ${rc}): $(cat "${tmp}/broken.json")"
fi

# HOARD_PROTECTION_DIR is honored only inside the temp dir. These targets cannot be created
# (outside temp, or a dangling link out of it), so even a binary without the check changes nothing.
# Never add $HOME or $TMPDIR itself here: if the check regressed, the run would ACL the real folder.
victim="${tmp}/work/victim.txt"
printf 'victim\n' > "${victim}"
ln -s "/nonexistent-hoard-smoke-$$" "${tmp}/escape"
for store in "/nonexistent-hoard-smoke-$$/store" "${tmp}/escape" "${tmp}/escape/store"; do
  HOARD_PROTECTION_DIR="${store}" "${binary}" protect "${victim}" --lock > /dev/null 2> "${tmp}/escape.err"
  rc=$?
  if [[ ${rc} -eq 2 ]] && grep -q "HOARD_PROTECTION_DIR" "${tmp}/escape.err"; then
    pass "store outside temp exits 2: ${store}"
  else
    fail "store outside temp (${store}) exited ${rc}: $(cat "${tmp}/escape.err")"
  fi
done

if [[ ${failures} -eq 0 ]]; then
  echo "PROTECT smoke: PASS"
else
  echo "PROTECT smoke: FAIL (${failures} checks)" >&2
  exit 1
fi
