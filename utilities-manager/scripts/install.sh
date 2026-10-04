#!/bin/bash
# Build an ad hoc signed Mac Utilities app and embed an independent source catalog.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications}"
REPO="$(cd "$ROOT/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/mac-utilities-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/mac-utilities-swift-cache"
set --
if [[ "${MAC_UTILITIES_DISABLE_SANDBOX:-0}" == 1 ]]; then set -- --disable-sandbox; fi
swift build "$@" --package-path "$ROOT" -c release
BIN="$(swift build "$@" --package-path "$ROOT" -c release --show-bin-path)"
mkdir -p "$DEST"
STAGE=$(mktemp -d "$DEST/.mac-utilities.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Mac Utilities.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Backend" "$APP/Contents/Resources/Catalog"
cp "$BIN/MacUtilities" "$APP/Contents/MacOS/MacUtilities"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/backend/lifecycle.py" "$ROOT/backend/package_app.py" "$APP/Contents/Resources/Backend/"
cp "$REPO/scripts/release/install.py" "$APP/Contents/Resources/Backend/release.py"
/usr/bin/python3 -B - "$REPO" "$APP/Contents/Resources/release-config.json" <<'PYCONFIG'
import json, pathlib, sys
repo = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(repo/'scripts/release'))
from version_gate import check, repo_slug
pathlib.Path(sys.argv[2]).write_text(json.dumps({'repo':repo_slug(repo), 'version':check(repo)})+'\n')
PYCONFIG
/usr/bin/python3 - "$REPO" "$APP/Contents/Resources/Catalog" <<'PY'
import importlib.util, json, pathlib, shutil, subprocess, sys
repo, dest = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('lifecycle', repo/'utilities-manager/backend/lifecycle.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
for manifest, source in module.Manager(repo, pathlib.Path.home(), system_effects=False).manifests(roots=[repo]).values():
    target = dest / source.relative_to(repo)
    shutil.copytree(source, target, symlinks=True, ignore=module.IGNORE)
try:
    common = subprocess.check_output(['/usr/bin/git', '-C', str(repo), 'rev-parse', '--git-common-dir'], text=True).strip()
    (dest / 'catalog-origin.json').write_text(json.dumps({'git_common_dir': str((repo / common).resolve())}))
except subprocess.CalledProcessError:
    pass
PY
codesign --force --sign - "$APP"
FINAL="$DEST/Mac Utilities.app"
/usr/bin/python3 "$ROOT/backend/package_app.py" --home "${MAC_UTILITIES_HOME:-$HOME}" install "$FINAL" "$APP"
echo "Installed $FINAL"
# Bootstrap Tools from the bundled, stable snapshot when it is available.
if [[ "${MAC_UTILITIES_SKIP_TOOLS:-0}" != 1 ]]; then
  OPTIONS=(--repo "$FINAL/Contents/Resources/Catalog")
  if [[ -n "${MAC_UTILITIES_HOME:-}" ]]; then OPTIONS+=(--home "$MAC_UTILITIES_HOME" --no-system-effects); fi
  if [[ -f "$FINAL/Contents/Resources/Catalog/swiftbar/tools/mac-utility.json" ]]; then
    /usr/bin/python3 "$FINAL/Contents/Resources/Backend/lifecycle.py" "${OPTIONS[@]}" install tools
  else
    echo "Tools source is absent; choose a complete checkout in Mac Utilities to install it." >&2
  fi
fi
