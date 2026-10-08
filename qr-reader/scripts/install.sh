#!/bin/bash
# Build QR Reader.app and place it in an applications directory.
#
#   scripts/install.sh                      # ~/Applications
#   scripts/install.sh /path/to/Applications
#
# The utilities manager calls this with its own staging directory and then
# takes ownership of the bundle, so this script only ever produces the app —
# it touches no user settings, no SwiftBar preference and nothing privileged.
set -euo pipefail
SCRIPT_VERSION="v1.0.1"
if [[ $# -gt 1 ]]; then echo "Usage: $0 [applications-directory]" >&2; exit 2; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications}"
BUNDLE_ID="com.macutilities.qr-reader"
APP_NAME="QR Reader.app"

if ! command -v /usr/bin/swift >/dev/null 2>&1; then
    echo "No Swift toolchain at /usr/bin/swift. Install the Xcode command line tools." >&2
    exit 1
fi

export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/qr-reader-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/qr-reader-swift-cache"
set --
if [[ "${QR_READER_DISABLE_SANDBOX:-0}" == 1 ]]; then set -- --disable-sandbox; fi

/usr/bin/swift build "$@" --package-path "$ROOT" -c release
BIN="$(/usr/bin/swift build "$@" --package-path "$ROOT" -c release --show-bin-path)"

mkdir -p "$DEST"
STAGE="$(mktemp -d "$DEST/.qr-reader-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/QRReader" "$APP/Contents/MacOS/QRReader"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signing gives the bundle a stable identifier but a fresh cdhash on
# every build, so macOS may ask for Screen Recording again after an update.
# README says so; the app detects the denial rather than failing silently.
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"

TARGET="$DEST/$APP_NAME"
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    if [[ -L "$TARGET" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)" != "$BUNDLE_ID" ]]; then
        echo "Refusing to replace a different app or symlink at $TARGET" >&2; exit 1
    fi
    mv "$TARGET" "$STAGE/Previous.app"
fi
if ! mv "$APP" "$TARGET"; then
    if [[ -d "$STAGE/Previous.app" ]]; then mv "$STAGE/Previous.app" "$TARGET"; fi
    exit 1
fi
echo "Installed $TARGET"
