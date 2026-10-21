#!/bin/bash
# Fails before a push when the tracked files carry something that must not be published.
# RELEASE_CHECK_DENY is an extended regex of private strings (names, emails, home paths); it is kept
# out of the repository on purpose, so an unset value is an error, not a pass.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo" || exit 2
if [ -z "${RELEASE_CHECK_DENY:-}" ]; then
    echo "release-check: RELEASE_CHECK_DENY is not set; nothing was checked" >&2
    exit 2
fi
# An invalid pattern makes grep exit 2 with no output, which would read as "clean". Probe it first.
printf '' | grep -E -e "$RELEASE_CHECK_DENY" >/dev/null 2>&1
if [ $? -eq 2 ]; then
    echo "release-check: RELEASE_CHECK_DENY is not a valid extended regex; nothing was checked" >&2
    exit 2
fi
failed=0
hits="$(git ls-files -z | xargs -0 grep -n -I -E -e "$RELEASE_CHECK_DENY" -- 2>/dev/null)"
if [ -n "$hits" ]; then
    echo "release-check: private strings in tracked files:" >&2
    printf '%s\n' "$hits" | cut -c1-200 >&2
    failed=1
fi
names="$(git ls-files | grep -E -e "$RELEASE_CHECK_DENY")"
if [ -n "$names" ]; then
    echo "release-check: private strings in file names:" >&2
    printf '%s\n' "$names" >&2
    failed=1
fi
large="$(git ls-files -z | xargs -0 stat -f '%z %N' | awk '$1 > 5242880 {print}')"
if [ -n "$large" ]; then
    echo "release-check: files over 5 MB:" >&2
    printf '%s\n' "$large" >&2
    failed=1
fi
if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "release-check: $(git ls-files | wc -l | tr -d ' ') tracked files clean"
