#!/bin/bash
set -u
set -o pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)" || { echo '無法定位專案根目錄' >&2; exit 1; }
cd "$repo" || { echo '無法進入專案根目錄' >&2; exit 1; }
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"

if ! swift build -c release --product HoardApp "$@"; then
    echo 'HoardApp release 建置失敗' >&2
    exit 1
fi
if ! swift build -c release --product hoard "$@"; then
    echo 'hoard release 建置失敗' >&2
    exit 1
fi

# A build from a linked worktree is a development copy. It gets its own bundle id so macOS never opens
# it in place of the owner's app (LaunchServices picks the highest version among apps sharing an id),
# and the app and its bundled CLI (with the background guardian) keep their own settings, caches,
# history and protection store (HoardApp.swift init, and the top of Sources/hoard/main.swift).
bundle_id="com.operonlab.hoard"
bundle_name="Hoard"
if [ "$(git -C "$repo" rev-parse --git-dir 2>/dev/null)" != "$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" ]; then
    bundle_id="com.operonlab.hoard.dev"
    bundle_name="Hoard Dev"
fi

app="$repo/dist/Hoard.app"
# The CLI cannot be Contents/MacOS/hoard: on a case-insensitive volume (the macOS default) that
# name is the same file as the app's own Contents/MacOS/Hoard.
cli="$app/Contents/MacOS/hoard-cli"
agents="$app/Contents/Library/LaunchAgents"
if ! mkdir -p "$app/Contents/MacOS" "$agents"; then
    echo '無法建立 Hoard.app 目錄' >&2
    exit 1
fi
if ! cp "$repo/.build/release/HoardApp" "$app/Contents/MacOS/Hoard"; then
    echo '無法複製 Hoard 執行檔' >&2
    exit 1
fi
if ! cp "$repo/.build/release/hoard" "$cli"; then
    echo '無法複製 hoard 命令列工具' >&2
    exit 1
fi
# One .lproj per language from the String Catalog (docs/plans/v0.6-i18n.md). AppKit's own menus pick
# their language from the same folders. English is the development region, so a language the app does
# not have falls back to English; zh-Hant therefore needs its own table, or it would fall back too.
resources="$app/Contents/Resources"
rm -rf "$resources"
if ! mkdir -p "$resources" || ! xcrun xcstringstool compile "$repo/Localization/Localizable.xcstrings" \
    --output-directory "$resources" >/dev/null \
    || ! "${HOARD_PYTHON:-$HOME/.local/bin/python3}" -I "$repo/scripts/i18n-source-table.py" "$repo/Localization/Localizable.xcstrings" \
    "$resources" >/dev/null; then
    echo '無法編譯語言檔（Localization/Localizable.xcstrings）' >&2
    exit 1
fi
for language in zh-Hant en ja ko; do
    mkdir -p "$resources/$language.lproj" || { echo "無法建立 $language.lproj" >&2; exit 1; }
done
cp "$repo/Resources/Brand/Hoard.icns" "$resources/Hoard.icns" || { echo '無法複製 App 圖示' >&2; exit 1; }
# Background guardian (Settings › App 關閉時也守護). The app registers it with SMAppService only
# when the user turns that on.
rm -f "$agents"/*.guardian.plist
if ! cat > "$agents/${bundle_id}.guardian.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${bundle_id}.guardian</string>
<key>BundleProgram</key><string>Contents/MacOS/hoard-cli</string>
<key>ProgramArguments</key><array><string>hoard</string><string>guardian</string></array>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
then
    echo '無法寫入背景守護的 LaunchAgent plist' >&2
    exit 1
fi
if ! cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>zh-Hant</string><string>en</string><string>ja</string><string>ko</string></array>
<key>CFBundleExecutable</key><string>Hoard</string>
<key>CFBundleIconFile</key><string>Hoard</string>
<key>CFBundleIdentifier</key><string>${bundle_id}</string>
<key>CFBundleName</key><string>${bundle_name}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
then
    echo '無法寫入 Info.plist' >&2
    exit 1
fi
# Sign with a stable identity when one exists. macOS ties Full Disk Access to the app's designated
# requirement: an ad-hoc signature pins it to the cdhash, so every rebuild silently drops the grant;
# a certificate pins it to identifier + certificate, which survives rebuilds.
# HOARD_SIGN_IDENTITY=- forces an ad-hoc signature (release builds: a personal certificate would
# ship its owner's name and email inside every download).
identity="${HOARD_SIGN_IDENTITY:-}"
if [ "$identity" = "-" ]; then
    identity=""
elif [ -z "$identity" ]; then
    candidates="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | sort -u)"
    count="$(printf '%s' "$candidates" | grep -c . || true)"
    if [ "$count" -gt 1 ]; then
        # Picking one silently would change the signing identity between builds and drop the grant.
        echo "找到 ${count} 張 Apple Development 憑證，請用 HOARD_SIGN_IDENTITY 指定一張：" >&2
        printf '%s\n' "$candidates" >&2
        exit 1
    fi
    identity="$candidates"
fi
# The inner CLI is signed first, with the same identity, so the app's seal covers a valid signature.
if [ -n "$identity" ]; then
    if ! codesign --force --options runtime -s "$identity" "$cli"; then
        echo "hoard-cli 簽署失敗（${identity}）" >&2
        exit 1
    fi
    if ! codesign --force --options runtime -s "$identity" "$app"; then
        echo "Hoard.app 簽署失敗（${identity}）" >&2
        exit 1
    fi
    for signed in "$cli" "$app"; do
        signed_as="$(codesign -dvv "$signed" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | head -1)"
        if [ "$signed_as" != "$identity" ]; then
            echo "簽章身分核對失敗（${signed}）：預期「${identity}」，實際「${signed_as}」" >&2
            exit 1
        fi
    done
    echo "已用 ${identity} 簽署：重新打包不會讓完整磁碟取用權限失效"
else
    if ! codesign --force -s - "$cli" || ! codesign --force -s - "$app"; then
        echo 'Hoard.app 簽署失敗' >&2
        exit 1
    fi
    if [ "${HOARD_SIGN_IDENTITY:-}" = "-" ]; then
        echo '已用 ad-hoc 簽章（HOARD_SIGN_IDENTITY=-）；每次重新打包後都要重新授權完整磁碟取用權限'
    else
        echo '警告：沒有找到開發者憑證，改用 ad-hoc 簽章；每次重新打包後都要重新授權完整磁碟取用權限' >&2
    fi
fi
if ! codesign --verify --deep --strict "$app"; then
    echo 'Hoard.app 簽章驗證失敗' >&2
    exit 1
fi
echo "已建立 ${app}（${bundle_id}）"
