#!/bin/bash
# Install or update the Transcribe engine: a mlx-whisper server under launchd on
# 127.0.0.1:8765, plus the `transcribe` command in ~/.local/bin. Idempotent.
#
#   transcribe/scripts/install-engine.sh
#
# Everything lives in ~/.cache/mac-utilities/transcribe/ (venv, a copy of the
# engine code, jobs, history, log), so the engine keeps working when the
# checkout or the manager's payload moves. Model weights stay in the Hugging
# Face cache (~/.cache/huggingface). Settings: ~/.config/mac-utilities/transcribe.json
# ({"port": 8765, "model": "mlx-community/whisper-large-v3-turbo"}).
#
# Replaces the audio-notes server: a loaded com.audionotes.transcription-server
# job is stopped and its plist moved to <engine home>/replaced/ so it cannot
# come back at login and fight over the port.
#
# Under a temporary HOME (the manager's --home/--no-system-effects test mode)
# it does nothing: launchd is per user, not per HOME.
set -euo pipefail
src=$(cd "$(dirname "$0")/.." && pwd)
real_home=$(/usr/bin/python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
if [ "${TRANSCRIBE_SKIP_ENGINE:-0}" = 1 ] || [ "$HOME" != "$real_home" ]; then
  echo "engine: skipped (temporary HOME or TRANSCRIBE_SKIP_ENGINE=1)"; exit 0
fi

label=com.mac-utilities.transcribe
old_label=com.audionotes.transcription-server
home_dir="$HOME/.cache/mac-utilities/transcribe"
agents="$HOME/Library/LaunchAgents"
plist="$agents/$label.plist"
uid=$(/usr/bin/id -u)
config="$HOME/.config/mac-utilities/transcribe.json"

setting() {  # setting <key> <default>
  /usr/bin/python3 -c 'import json,sys
try: v=json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception: v=None
print(v if v not in (None,"") else sys.argv[3])' "$config" "$1" "$2"
}
port=$(setting port 8765)
model=$(setting model mlx-community/whisper-large-v3-turbo)

uv=""
for c in /opt/homebrew/bin/uv /usr/local/bin/uv "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
  [ -x "$c" ] && { uv=$c; break; }
done
[ -n "$uv" ] || { echo "engine: uv not found (brew install uv)" >&2; exit 1; }
ff=""
for c in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do [ -x "$c" ] && { ff=$c; break; }; done
[ -n "$ff" ] || { echo "engine: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

mkdir -p "$home_dir/engine" "$home_dir/jobs" "$home_dir/history" "$agents"

# 1. venv — rebuilt only when the pinned requirements change.
stamp="$home_dir/venv/.requirements.sha256"
want=$( { cat "$src/engine/requirements.txt"; echo "mlx-whisper==0.4.3"; } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
if [ ! -x "$home_dir/venv/bin/python" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
  echo "engine: building venv (python 3.12, mlx-whisper without torch)"
  rm -rf "$home_dir/venv.new"
  "$uv" venv -q --python 3.12 "$home_dir/venv.new"
  "$uv" pip install -q --python "$home_dir/venv.new/bin/python" -r "$src/engine/requirements.txt"
  "$uv" pip install -q --python "$home_dir/venv.new/bin/python" --no-deps "mlx-whisper==0.4.3"
  "$home_dir/venv.new/bin/python" -c "import mlx_whisper"
  echo "$want" > "$home_dir/venv.new/.requirements.sha256"
  rm -rf "$home_dir/venv.old"; [ -d "$home_dir/venv" ] && mv "$home_dir/venv" "$home_dir/venv.old"
  mv "$home_dir/venv.new" "$home_dir/venv"; rm -rf "$home_dir/venv.old"
  # venv paths are absolute; rebuilding in place under a new name would break them.
  "$home_dir/venv/bin/python" -c "import mlx_whisper" 2>/dev/null || {
    echo "engine: venv moved badly, rebuilding in place"; rm -rf "$home_dir/venv"
    "$uv" venv -q --python 3.12 "$home_dir/venv"
    "$uv" pip install -q --python "$home_dir/venv/bin/python" -r "$src/engine/requirements.txt"
    "$uv" pip install -q --python "$home_dir/venv/bin/python" --no-deps "mlx-whisper==0.4.3"
    echo "$want" > "$stamp"; }
fi

# 2. engine code — a copy, so the job never points into a checkout or payload.
for f in server.py cli.py; do
  /usr/bin/install -m 0755 "$src/engine/$f" "$home_dir/engine/$f.new"
  mv "$home_dir/engine/$f.new" "$home_dir/engine/$f"
done

# 3. retire the audio-notes job (it serves the same port).
if [ -f "$agents/$old_label.plist" ]; then
  /bin/launchctl bootout "gui/$uid/$old_label" 2>/dev/null || true
  mkdir -p "$home_dir/replaced"
  mv "$agents/$old_label.plist" "$home_dir/replaced/$old_label.plist"
  echo "engine: retired $old_label (plist kept in $home_dir/replaced/)"
fi

# 4. launchd job.
/usr/bin/sed -e "s|__ENGINE_HOME__|$home_dir|g" -e "s|__PORT__|$port|g" -e "s|__MODEL__|$model|g" \
  "$src/launchd/$label.plist.tmpl" > "$plist.new"
/usr/bin/plutil -lint -s "$plist.new"
/bin/launchctl bootout "gui/$uid/$label" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.5
done
if /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "engine: port $port is held by something else:" >&2
  /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2; rm -f "$plist.new"; exit 1
fi
mv "$plist.new" "$plist"
/bin/launchctl bootstrap "gui/$uid" "$plist"

# 5. the `transcribe` command.
mkdir -p "$HOME/.local/bin"
link="$HOME/.local/bin/transcribe"
if [ -L "$link" ] || [ ! -e "$link" ]; then
  ln -sfn "$home_dir/engine/cli.py" "$link"; echo "engine: $link -> $home_dir/engine/cli.py"
else
  echo "engine: $link exists and is not a symlink; left alone" >&2
fi

for _ in $(seq 1 60); do
  if /usr/bin/curl -fs -m 2 "http://127.0.0.1:$port/health" >/dev/null; then
    echo "engine: running on 127.0.0.1:$port ($model); first start downloads the model"; exit 0
  fi
  sleep 0.5
done
echo "engine: did not answer on :$port within 30s; see $home_dir/engine.log" >&2
exit 1
