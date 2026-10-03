#!/bin/bash
# Build Transcribe.app into a destination (default ~/Applications) and install
# or update the engine (launchd job + `transcribe` command). This is the
# manifest's install hook: the Mac Utilities manager passes a staging folder as
# the destination and moves the app itself.
#
#   transcribe/scripts/install.sh [applications-dir]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/transcribe-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/transcribe-swift-cache"
set --
if [[ "${TRANSCRIBE_DISABLE_SANDBOX:-${MAC_UTILITIES_DISABLE_SANDBOX:-0}}" == 1 ]]; then set -- --disable-sandbox; fi
/usr/bin/swift build "$@" --package-path "$ROOT" -c release
BIN="$(/usr/bin/swift build "$@" --package-path "$ROOT" -c release --show-bin-path)"
APP="$DEST/Transcribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/Transcribe" "$APP/Contents/MacOS/Transcribe"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
echo "Installed $APP"
"$ROOT/scripts/install-engine.sh"
