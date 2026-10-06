#!/bin/bash
# Checkout install hook: build Video Preview.app into a destination (default
# ~/Applications). VLCKit and build products stay in temporary folders so the
# installed payload is just the source. The manager registers the Quick Look
# extension after it moves the app into place.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/video-preview-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
/bin/bash "$ROOT/scripts/build.sh" --output "$DEST" --vendor "$WORK/Vendor" --scratch "$WORK/build"
echo "Installed $DEST/Video Preview.app"
