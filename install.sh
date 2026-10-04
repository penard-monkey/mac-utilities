#!/bin/bash
# curl -fsSL https://raw.githubusercontent.com/penard-monkey/mac-utilities/main/install.sh | bash
# Pin: MAC_UTILITIES_INSTALL_VERSION=v1.0.0 bash install.sh
# Offline proof: bash install.sh --artifacts DIR --home DIR --no-system-effects
set -euo pipefail
REPO="penard-monkey/mac-utilities"
SCRIPT_VERSION="v1.1.1"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
fail() { echo "ERROR: $*" >&2; exit 1; }
ARTIFACTS=""
# Bash 3.2 needs guarded expansions of empty arrays when nounset is enabled.
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts) [[ $# -ge 2 ]] || fail 'Missing artifacts directory'; ARTIFACTS="$2"; shift 2 ;;
    --help|-h)
      cat <<'HELP'
Install: install.sh [--home DIR --no-system-effects] [--artifacts DIR]
         MAC_UTILITIES_INSTALL=gif-stickers,memory bash install.sh
Update:  install.sh [options] update [id|--all]
Remove:  install.sh [options] uninstall [id|manager]
Options: --strip-quarantine (explicit opt-in for unsigned apps)
         --no-system-effects (required with an alternate home)
Pin:     MAC_UTILITIES_INSTALL_VERSION=v1.0.0
Local artifacts must include release.json, release-runtime.py, checksums.txt,
a catalog zip, and app zips. Default installs the manager and Tools; a terminal
allows optional comma-separated utility selection. Settings and keys are kept.
HELP
      exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || fail 'macOS 14 or newer is required'
[[ -x /usr/bin/python3 ]] || fail 'System Python 3 is required'
# Existing installed runtime handles offline removal and external folder updates.
# Local-artifacts proofs still bootstrap the runtime from their checksummed feed.
RUNTIME_HOME="$HOME"
for ((INDEX=0; INDEX<${#ARGS[@]}; INDEX++)); do
  if [[ "${ARGS[$INDEX]}" == --home ]]; then
    [[ $((INDEX+1)) -lt ${#ARGS[@]} ]] || fail 'Missing home directory'
    RUNTIME_HOME="${ARGS[$((INDEX+1))]}"
  fi
done
LOCAL_RUNTIME="$RUNTIME_HOME/Applications/Mac Utilities.app/Contents/Resources/Backend/release.py"
if [[ -z "$ARTIFACTS" && -f "$LOCAL_RUNTIME" ]]; then
  for ARG in ${ARGS[@]+"${ARGS[@]}"}; do
    if [[ "$ARG" == update || "$ARG" == uninstall || "$ARG" == --check ]]; then
      PIN=()
      [[ -z "${MAC_UTILITIES_INSTALL_VERSION:-}" ]] || PIN=(--tag "$MAC_UTILITIES_INSTALL_VERSION")
      exec /usr/bin/python3 -B "$LOCAL_RUNTIME" --repo "$REPO" ${PIN[@]+"${PIN[@]}"} ${ARGS[@]+"${ARGS[@]}"}
    fi
  done
fi
VERSION="${MAC_UTILITIES_INSTALL_VERSION:-}"
UPDATING=0
for ARG in ${ARGS[@]+"${ARGS[@]}"}; do [[ "$ARG" != update && "$ARG" != --check ]] || UPDATING=1; done
if [[ -n "$ARTIFACTS" ]]; then
  [[ -d "$ARTIFACTS" ]] || fail 'Artifacts directory does not exist'
  ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"
  if [[ -z "$VERSION" ]]; then
    VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$ARTIFACTS/release.json")"
  fi
else
  if [[ -z "$VERSION" && "$UPDATING" == 0 ]] && curl --connect-timeout 15 --max-time 60 -fsSLI -o /dev/null "https://github.com/$REPO/releases/tag/$SCRIPT_VERSION" 2>/dev/null; then
    VERSION="$SCRIPT_VERSION"
  fi
  if [[ -z "$VERSION" ]]; then
    URL="$(curl --connect-timeout 15 --max-time 60 -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")"
    VERSION="${URL##*/tag/}"
    [[ "$URL" == "https://github.com/$REPO/releases/tag/$VERSION" ]] || fail 'Could not resolve latest release'
  fi
fi
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Expected a stable vX.Y.Z release tag'
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fetch() {
  if [[ -n "$ARTIFACTS" ]]; then cp "$ARTIFACTS/$1" "$TMP_DIR/$1";
  else curl --connect-timeout 15 --max-time 180 -fsSL "https://github.com/$REPO/releases/download/$VERSION/$1" -o "$TMP_DIR/$1"; fi
}
fetch checksums.txt
fetch release-runtime.py
# Require exactly one entry. Missing/duplicate/malformed hashes must fail closed.
/usr/bin/python3 - "$TMP_DIR" <<'PY'
import hashlib, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
lines = [line for line in (root/'checksums.txt').read_text().splitlines() if line.endswith('  release-runtime.py')]
if len(lines) != 1 or not re.fullmatch(r'[0-9a-f]{64}  release-runtime.py', lines[0]):
    sys.exit('ERROR: Missing or invalid runtime checksum')
if hashlib.sha256((root/'release-runtime.py').read_bytes()).hexdigest() != lines[0].split()[0]:
    sys.exit('ERROR: Runtime checksum verification failed')
PY
if [[ -n "$ARTIFACTS" ]]; then ARGS=(--artifacts "$ARTIFACTS" ${ARGS[@]+"${ARGS[@]}"}); fi
/usr/bin/python3 "$TMP_DIR/release-runtime.py" --repo "$REPO" --tag "$VERSION" ${ARGS[@]+"${ARGS[@]}"}
