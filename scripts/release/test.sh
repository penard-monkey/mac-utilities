#!/bin/bash
# The same gates locally, on PRs, and before release packaging.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${MAC_UTILITIES_TEST_CACHE:-$HOME/.cache/worktrees/mac-utilities/release-path/tests}"
mkdir -p "$CACHE"
cd "$ROOT"
/usr/bin/python3 -B -m unittest discover -s scripts/tests -v
/usr/bin/python3 -B -m unittest discover -s utilities-manager/tests -v
/usr/bin/python3 -B -m unittest discover -s swiftbar/tools/tests -v
for source in */Package.swift; do
  package="${source%/Package.swift}"
  set --
  [[ "${MAC_UTILITIES_DISABLE_SANDBOX:-0}" != 1 ]] || set -- --disable-sandbox
  if /usr/bin/python3 -B -c 'from pathlib import Path; import sys; raise SystemExit(not any(Path(sys.argv[1]).glob("**/*Tests.swift")))' "$package"; then
    /usr/bin/swift test "$@" --package-path "$package" --scratch-path "$CACHE/$package"
  else
    /usr/bin/swift build "$@" --package-path "$package" --scratch-path "$CACHE/$package"
  fi
done
# Source-only engine suites do not live in tests/.
for suite in */engine; do
  [[ -d "$suite" ]] || continue
  rg --files "$suite" -g 'test_*.py' | rg -q . || continue
  /usr/bin/python3 -B -m unittest discover -s "$suite" -v
done
# Test suites that land with source-only engines are discovered independently.
for suite in */tests; do
  [[ "$suite" == utilities-manager/tests || "$suite" == scripts/tests ]] && continue
  [[ -d "$suite" ]] || continue
  rg --files "$suite" -g 'test_*.py' | rg -q . || continue
  /usr/bin/python3 -B -m unittest discover -s "$suite" -v
done
for script in install.sh scripts/*.sh scripts/release/*.sh */scripts/*.sh; do /bin/bash -n "$script"; done
# Compile without leaving pycache in source or installed payloads.
/usr/bin/python3 - <<'PY'
from pathlib import Path
for base in ('scripts', 'utilities-manager/backend', 'swiftbar'):
    for path in Path(base).rglob('*.py'):
        compile(path.read_bytes(), str(path), 'exec')
PY
