#!/bin/bash
# Builds a release: dist/Hoard-<version>.zip (ad-hoc signed app, CLI inside) and its SHA-256.
# Run from the main checkout, not a linked worktree (that would build the development bundle id).
set -u
version="${1:-}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo" || exit 1
if [ -z "$version" ]; then
    echo "usage: scripts/release.sh <version>" >&2
    exit 2
fi
# The version lives in two places; refuse to ship a build that disagrees with itself.
plist_version="$(sed -n 's|.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*|\1|p' scripts/make-app.sh)"
server_version="$(sed -n 's|.*"serverInfo": \["name": "hoard", "version": "\([^"]*\)"\].*|\1|p' Sources/hoard/main.swift)"
if [ "$plist_version" != "$version" ] || [ "$server_version" != "$version" ]; then
    echo "version mismatch: asked ${version}, Info.plist ${plist_version:-none}, MCP server ${server_version:-none}" >&2
    exit 1
fi
# Untracked files count too: an untracked source file would be compiled into the release.
if [ -n "$(git status --porcelain)" ]; then
    echo "uncommitted or untracked files; a release is built from a clean checkout" >&2
    exit 1
fi
HOARD_SIGN_IDENTITY=- scripts/make-app.sh || exit 1
app="$repo/dist/Hoard.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
if [ "$bundle_id" != "com.operonlab.hoard" ]; then
    echo "built ${bundle_id}, not com.operonlab.hoard (run from the main checkout)" >&2
    exit 1
fi
signature="$(codesign -dvv "$app" 2>&1)" || { echo "cannot read the app's signature" >&2; exit 1; }
if ! printf '%s\n' "$signature" | grep -q '^Signature=adhoc$'; then
    echo "the app is not ad-hoc signed; a release must not carry a personal certificate" >&2
    exit 1
fi
zip_name="Hoard-${version}.zip"
# The Homebrew formula installs this CLI tarball (operonlab/homebrew-tap, Formula/hoard.rb).
cli_name="hoard-v${version}-aarch64-apple-darwin.tar.gz"
stage="$(mktemp -d)" || exit 1
trap 'rm -rf "$stage"' EXIT
cp "$repo/.build/release/hoard" "$stage/hoard" || { echo "no release CLI at .build/release/hoard" >&2; exit 1; }
if [ "$(lipo -archs "$stage/hoard")" != "arm64" ]; then
    echo "the CLI is not an arm64 binary: $(lipo -archs "$stage/hoard")" >&2
    exit 1
fi
codesign --force -s - "$stage/hoard" || { echo "cannot sign the CLI" >&2; exit 1; }
rm -f "$repo/dist/$zip_name" "$repo/dist/$cli_name" "$repo/dist/SHA256SUMS"
ditto -c -k --keepParent "$app" "$repo/dist/$zip_name" || { echo "cannot write $zip_name" >&2; exit 1; }
tar -czf "$repo/dist/$cli_name" -C "$stage" hoard || { echo "cannot write $cli_name" >&2; exit 1; }
(cd "$repo/dist" && shasum -a 256 "$zip_name" "$cli_name" > SHA256SUMS) || exit 1
echo "built dist/$zip_name and dist/$cli_name"
cat "$repo/dist/SHA256SUMS"
