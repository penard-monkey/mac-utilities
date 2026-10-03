#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 ]]; then echo "Usage: $0 [applications-directory]" >&2; exit 2; fi
DEST="${1:-$HOME/Applications}"
APP="$DEST/Git & SSH.app"
if [[ ! -e "$APP" && ! -L "$APP" ]]; then echo "Git & SSH is not installed at $DEST"; exit 0; fi
if [[ -L "$APP" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)" != "com.macutilities.git-settings" ]]; then
    echo "Refusing to remove a different app or symlink at $APP" >&2; exit 1
fi
rm -rf "$APP"
echo "Removed $APP. Git settings, SSH files, and backups are preserved."
