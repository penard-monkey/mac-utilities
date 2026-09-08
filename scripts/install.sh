#!/bin/bash
# Link every SwiftBar plugin in this repo into the shared plugin folder,
# ~/.swiftbar, and make sure SwiftBar is pointed at it.
#
#   scripts/install.sh            link all plugins (idempotent), refresh SwiftBar
#   scripts/install.sh --remove   remove the links this repo created
#
# ~/.swiftbar is a plain folder of symlinks; any repo can drop plugins in it.
# Plugins live here in swiftbar/<utility>/<name>.<interval>.<ext>; the repo is
# the source of truth, so edits are live on the next refresh.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
plugin_dir="$HOME/.swiftbar"
mkdir -p "$plugin_dir"

mode=${1:-install}
shopt -s nullglob
for src in "$repo"/swiftbar/*/*.*.*; do
  case "$src" in *.md|*.json|*.txt) continue;; esac
  [ -x "$src" ] || { echo "skip (not executable): $src" >&2; continue; }
  dst="$plugin_dir/$(basename "$src")"
  if [ "$mode" = "--remove" ]; then
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then rm "$dst"; echo "removed  $dst"; fi
    continue
  fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    echo "exists and is not a symlink, leaving alone: $dst" >&2; continue
  fi
  ln -sfn "$src" "$dst"
  echo "linked   $dst -> $src"
done

# Point SwiftBar at the shared folder if it is looking elsewhere. SwiftBar only
# reads this preference at launch, so relaunch it when it changes.
current=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
if [ "$mode" != "--remove" ] && [ "${current/#\~/$HOME}" != "$plugin_dir" ]; then
  defaults write com.ameba.SwiftBar PluginDirectory "$plugin_dir"
  if pgrep -xq SwiftBar; then
    osascript -e 'quit app "SwiftBar"' 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq SwiftBar || break; sleep 0.5; done
    sleep 1   # LaunchServices needs a beat after the quit or open fails with -600
  fi
  open -a SwiftBar || { sleep 2; open -a SwiftBar; }
  echo "SwiftBar plugin folder set to $plugin_dir (was: ${current:-unset}); SwiftBar relaunched"
else
  open -g "swiftbar://refreshallplugins" 2>/dev/null || true
fi
echo "plugin folder: $plugin_dir"
