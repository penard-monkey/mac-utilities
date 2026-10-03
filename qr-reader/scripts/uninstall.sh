#!/bin/bash
# Remove QR Reader.app. Scan history and settings are left alone; delete
# ~/.cache/mac-utilities/qr-reader-* and ~/.config/mac-utilities/qr-reader.json
# by hand if you want them gone.
set -euo pipefail
if [[ $# -gt 1 ]]; then echo "Usage: $0 [applications-directory]" >&2; exit 2; fi
DEST="${1:-$HOME/Applications}"
BUNDLE_ID="com.macutilities.qr-reader"
APP="$DEST/QR Reader.app"
if [[ ! -e "$APP" && ! -L "$APP" ]]; then echo "QR Reader is not installed at $DEST"; exit 0; fi
if [[ -L "$APP" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)" != "$BUNDLE_ID" ]]; then
    echo "Refusing to remove a different app or symlink at $APP" >&2; exit 1
fi
rm -rf "$APP"
echo "Removed $APP. Scan history and settings are preserved."
