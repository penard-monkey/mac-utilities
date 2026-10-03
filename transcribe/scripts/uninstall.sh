#!/bin/bash
# Remove Transcribe.app from a destination (default ~/Applications) and the
# engine. The Mac Utilities manager removes the app and plugin it owns by
# itself and does not run this; after uninstalling there, run
# transcribe/scripts/uninstall-engine.sh to stop and remove the engine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications}"
rm -rf "$DEST/Transcribe.app"
"$ROOT/scripts/uninstall-engine.sh"
