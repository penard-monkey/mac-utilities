#!/bin/bash
# Remove only the receipt-owned manager bundle, retain managed tools/preferences.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications}"
exec /usr/bin/python3 "$ROOT/backend/package_app.py" --home "${MAC_UTILITIES_HOME:-$HOME}" uninstall "$DEST/Mac Utilities.app"
