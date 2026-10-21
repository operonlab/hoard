#!/bin/bash
# Launch Hoard with arguments, wait, and capture only its window (never the whole screen).
# usage: scripts/shoot.sh <out.png> <wait-seconds> [app args...]
#   scripts/shoot.sh docs/progress/shots/F-disk.png 90 --scan /System/Volumes/Data
# The app is quit afterwards (so it saves its snapshot). Needs Screen Recording permission for the terminal.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?usage: shoot.sh <out.png> <wait-seconds> [app args...]}"
wait_s="${2:?usage: shoot.sh <out.png> <wait-seconds> [app args...]}"
shift 2
app="$repo/dist/Hoard.app"
winid="$repo/.build/winid"
[ -x "$app/Contents/MacOS/Hoard" ] || { echo "missing $app — run scripts/make-app.sh first" >&2; exit 1; }
# The id of this build (a worktree build is com.operonlab.hoard.dev): quit only what this script opened.
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") || { echo "cannot read $app bundle id" >&2; exit 1; }
# Windows are owned by the bundle name: "Hoard Dev" for a worktree build.
bundle_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist") || { echo "cannot read $app bundle name" >&2; exit 1; }
if [ ! -x "$winid" ] || [ "$repo/scripts/winid.swift" -nt "$winid" ]; then
    mkdir -p "$repo/.build" && swiftc -O -o "$winid" "$repo/scripts/winid.swift" || { echo "cannot build winid" >&2; exit 1; }
fi
# A second instance makes "the Hoard window" ambiguous (a 12:10 capture caught an empty window).
if pgrep -f "$app/Contents/MacOS/Hoard" >/dev/null; then
    echo "Hoard is already running; quit it first so the capture shows this launch" >&2
    exit 1
fi
open -n "$app" --args "$@" || { echo "cannot open $app" >&2; exit 1; }
# From here on, a failure still quits the instance this script opened. Quitting saves the snapshot
# first (the app allows itself 20 s); an instance still running after that did not take the quit.
quit() {
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1
    for _ in $(seq 1 50); do
        pgrep -f "$app/Contents/MacOS/Hoard" >/dev/null || return 0
        sleep 0.5
    done
    echo "$bundle_name did not quit; quit it yourself" >&2
    return 1
}
sleep "$wait_s"
id=$("$winid" "$bundle_name") || { echo "$bundle_name has no window to capture" >&2; quit; exit 1; }
screencapture -x -o -l "$id" "$out" || { echo "screencapture failed (Screen Recording permission?)" >&2; quit; exit 1; }
echo "captured $out at $(date +%H:%M:%S)"
quit || exit 1
