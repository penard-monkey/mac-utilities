#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 ]]; then echo "Usage: $0 [applications-directory]" >&2; exit 2; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/git-settings-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/git-settings-swift-cache"
set --
if [[ "${GIT_SETTINGS_DISABLE_SANDBOX:-0}" == 1 ]]; then set -- --disable-sandbox; fi
/usr/bin/swift build "$@" --package-path "$ROOT" -c release
BIN="$(/usr/bin/swift build "$@" --package-path "$ROOT" -c release --show-bin-path)"
mkdir -p "$DEST"
STAGE="$(mktemp -d "$DEST/.git-settings-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Git & SSH.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GitSettings" "$APP/Contents/MacOS/GitSettings"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/swift "$ROOT/scripts/make-icon.swift" "$STAGE/AppIcon.iconset"
/usr/bin/iconutil -c icns "$STAGE/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
TARGET="$DEST/Git & SSH.app"
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    if [[ -L "$TARGET" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)" != "com.macutilities.git-settings" ]]; then
        echo "Refusing to replace a different app or symlink at $TARGET" >&2; exit 1
    fi
    mv "$TARGET" "$STAGE/Previous.app"
fi
if ! mv "$APP" "$TARGET"; then
    if [[ -d "$STAGE/Previous.app" ]]; then mv "$STAGE/Previous.app" "$TARGET"; fi
    exit 1
fi
echo "Installed $TARGET"
