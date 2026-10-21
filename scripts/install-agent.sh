#!/bin/bash
# Installs the hoard CLI to ~/.local/bin (staged: build → .new → sign → smoke → atomic mv) and
# links docs/agent as the Claude Code skill `hoard`, so agents can call it from any directory.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
target="$HOME/.local/bin/hoard"
staging="$target.new"
skill="$HOME/.claude/skills/hoard"

cd "$repo" || { echo "cannot enter $repo" >&2; exit 1; }
swift build -c release --product hoard || { echo "build failed" >&2; exit 1; }
mkdir -p "$(dirname "$target")"
cp .build/release/hoard "$staging" || { echo "cannot stage $staging" >&2; exit 1; }
codesign --force --sign - "$staging" 2>/dev/null || { echo "cannot sign $staging" >&2; exit 1; }
# Smoke: a usage error must exit 2 and print usage, proving the binary loads and runs.
"$staging" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 2 ]; then
    echo "smoke failed (exit ${rc}, expected 2); staging kept at $staging, live untouched" >&2
    exit 1
fi
mv "$staging" "$target" || { echo "cannot move into $target" >&2; exit 1; }
echo "installed $target"

if [ -L "$skill" ] || [ ! -e "$skill" ]; then
    ln -sfn "$repo/docs/agent" "$skill" && echo "skill linked: $skill -> $repo/docs/agent"
else
    echo "skip skill: $skill exists and is not a symlink (left untouched)" >&2
fi
