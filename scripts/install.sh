#!/bin/bash
# Link every SwiftBar plugin in this repo into SwiftBar's plugin folder.
#
#   scripts/install.sh            link all plugins (idempotent) and refresh SwiftBar
#   scripts/install.sh --remove   remove the links this repo created
#
# Plugins live in swiftbar/<utility>/<name>.<interval>.<ext>; the repo is the
# source of truth and SwiftBar sees symlinks, so edits here are live.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
plugin_dir=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
plugin_dir=${plugin_dir/#\~/$HOME}
if [ -z "$plugin_dir" ]; then
  echo "SwiftBar has no plugin folder configured yet. Open SwiftBar once, pick a folder, re-run." >&2
  exit 1
fi
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

# Ask SwiftBar to rescan; harmless if it is not running.
open -g "swiftbar://refreshallplugins" 2>/dev/null || true
echo "plugin folder: $plugin_dir"
