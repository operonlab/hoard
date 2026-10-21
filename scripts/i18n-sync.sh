#!/bin/bash
# Collects every localizable string the app's code uses into Localization/Localizable.xcstrings:
# new keys are added, keys no longer in the code are marked stale, translations are kept.
# The compiler lists the keys (-emit-localized-strings), so nothing is parsed by hand. Arguments go to
# `swift build` (inside a sandbox: --disable-sandbox, as in CLAUDE.md).
set -u
set -o pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)" || { echo '無法定位專案根目錄' >&2; exit 1; }
cd "$repo" || { echo '無法進入專案根目錄' >&2; exit 1; }
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
catalog="$repo/Localization/Localizable.xcstrings"
# Its own build folder, always built with the key-list flags: a source the build skips as up to date
# then always has the list its last compile wrote, and an edited one is compiled again.
build="$repo/.build/i18n"
out="$build/stringsdata"
mkdir -p "$out" || { echo "無法建立 $out" >&2; exit 1; }

log="$build/build.log"
if ! swift build --build-path "$build" --product HoardApp -Xswiftc -emit-localized-strings \
    -Xswiftc -emit-localized-strings-path -Xswiftc "$out" "$@" >"$log" 2>&1; then
    tail -30 "$log" >&2
    echo "HoardApp 建置失敗，沒有更新語言目錄（完整輸出：$log）" >&2
    exit 1
fi

# Every app source must have a list at least as new as the source. A missing or older one would make
# sync mark that file's strings stale, which reads like "the code no longer uses them".
args=()
for source in Sources/HoardApp/*.swift; do
    list="$out/$(basename "$source" .swift).stringsdata"
    if [ ! -f "$list" ] || [ "$list" -ot "$source" ] || ! grep -qF "\"source\": \"$repo/$source\"" "$list"; then
        echo "缺少、過期或不是這份原始碼的字串清單：$list（來源 $source）。刪掉 $build 再跑一次" >&2
        exit 1
    fi
    args+=(--stringsdata "$list")
done

if ! xcrun xcstringstool sync "$catalog" "${args[@]}"; then
    echo "xcstringstool sync 失敗：$catalog" >&2
    exit 1
fi
echo "已同步 $((${#args[@]} / 2)) 個檔案的字串到 $catalog"
