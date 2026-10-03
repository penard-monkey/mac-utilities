#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/gif-stickers-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/gif-stickers-swift-cache"
set --
if [[ "${GIF_STICKERS_DISABLE_SANDBOX:-0}" == 1 ]]; then set -- --disable-sandbox; fi
/usr/bin/swift build "$@" --package-path "$ROOT" -c release
BIN="$(/usr/bin/swift build "$@" --package-path "$ROOT" -c release --show-bin-path)"
APP="$DEST/GIF Stickers.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/GIFStickers" "$APP/Contents/MacOS/GIFStickers"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Installed $APP"
