#!/bin/bash
# Selective Mac Utilities lifecycle. No arguments lists the catalog.
# Legacy: --all installs available utilities; --remove removes receipt-owned ones.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
backend="$repo/utilities-manager/backend/lifecycle.py"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat <<'EOF'
Usage:
  scripts/install.sh                         list catalog and installation status (JSON)
  scripts/install.sh install memory          install a selected utility
  scripts/install.sh update memory           update from this checkout
  scripts/install.sh uninstall memory        remove owned files, retain preferences
  scripts/install.sh menu memory hide        hide menu item, keep utility installed
  scripts/install.sh open gif-stickers       open an installed app
  scripts/install.sh --all                   install all available manifest utilities
  scripts/install.sh --remove                uninstall all owned nonprivileged utilities
  scripts/install.sh manager [destination]   build/install Mac Utilities.app
Options before the action:
  --home DIR --applications DIR --no-system-effects
Alternate homes require --no-system-effects. Privileged hooks are never run
by this installer. Existing unowned app/plugin files are never replaced.
The old no-argument 'link every worktree plugin' behavior is now an explicit --all.
EOF
  exit 0
fi
if [[ "${1:-}" == manager ]]; then
  shift
  exec "$repo/utilities-manager/scripts/install.sh" "$@"
fi
options=(--repo "$repo")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --home|--applications|--repo)
      [[ $# -gt 1 ]] || { echo "Missing value for $1" >&2; exit 2; }
      options+=("$1" "$2"); shift 2 ;;
    --no-system-effects) options+=("$1"); shift ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == --all || "${1:-}" == --remove ]]; then
  mode="$1"
  catalog=$(/usr/bin/python3 "$backend" "${options[@]}" list)
  ids=$(printf '%s' "$catalog" | /usr/bin/python3 -c 'import json,sys; mode=sys.argv[1]; print("\n".join(u["id"] for u in json.load(sys.stdin)["utilities"] if (u["available"] if mode == "--all" else u["installed"] and not u["privileged"])))' "$mode")
  action=install
  [[ "$mode" == --remove ]] && action=uninstall
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    /usr/bin/python3 "$backend" "${options[@]}" "$action" "$id"
  done <<< "$ids"
  if [[ "$mode" == --remove ]]; then
    echo 'Privileged utilities require their supplied Terminal uninstall commands.' >&2
  fi
  exit 0
fi
if [[ $# -eq 0 ]]; then set -- list; fi
exec /usr/bin/python3 "$backend" "${options[@]}" "$@"
