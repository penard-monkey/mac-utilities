#!/bin/bash
# Remove the Transcribe engine: launchd job, `transcribe` link, venv and engine
# copy. Keeps history (~/.cache/mac-utilities/transcribe/history), settings and
# the Hugging Face model cache. The Mac Utilities manager does not run this;
# run it by hand after uninstalling the app there.
set -euo pipefail
label=com.mac-utilities.transcribe
home_dir="$HOME/.cache/mac-utilities/transcribe"
/bin/launchctl bootout "gui/$(/usr/bin/id -u)/$label" 2>/dev/null || true
# bootout returns before launchd has finished tearing the job down.
for _ in $(seq 1 20); do
  /bin/launchctl print "gui/$(/usr/bin/id -u)/$label" >/dev/null 2>&1 || break
  sleep 0.25
done
if /bin/launchctl print "gui/$(/usr/bin/id -u)/$label" >/dev/null 2>&1; then
  echo "engine: $label is still loaded; not removing its files" >&2; exit 1
fi
rm -f "$HOME/Library/LaunchAgents/$label.plist"
link="$HOME/.local/bin/transcribe"
if [ -L "$link" ] && [ "$(readlink "$link")" = "$home_dir/engine/cli.py" ]; then rm "$link"; fi
rm -rf "$home_dir/venv" "$home_dir/engine" "$home_dir/jobs"
echo "removed the engine; kept $home_dir/history and the model cache"
