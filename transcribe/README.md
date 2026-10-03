# Transcribe

Drop an audio or video file, get a transcript saved next to it. Runs entirely
on this Mac with mlx-whisper (large-v3-turbo, language detected
automatically). Replaces `~/bin/transcribe` and the audio-notes server
(deprecated; its checkout is now `~/workspace/audio-notes-deprecated`).

Three front ends share one engine:

| Piece | What it is |
| --- | --- |
| **Transcribe.app** | Window with a drop zone, a queue and recent transcripts. Also takes files from Finder's Open With, the Dock icon and `open -a Transcribe <file>`. |
| **Menu bar item** | `swiftbar/transcribe.10s.py`: engine status and the last six transcripts, each with Copy text, Show transcript file and Open original. |
| **`transcribe`** | Command in `~/.local/bin`: `transcribe FILE…` prints and saves, `transcribe recent`, `transcribe status`, `transcribe server start|stop|restart|logs`. |

## Engine

`engine/server.py` keeps the model warm under launchd
(`com.mac-utilities.transcribe`) on `127.0.0.1:8765` and serves the same HTTP
contract the audio-notes server did, so saywhat needs no change:

```
GET  /health      {"status":"ok","models_loaded":{"whisper":true,"diarization":false},"model":…}
POST /jobs        {"file_path","mode":"basic","output_dir"?,"language"?} → 202 {"job_id","status"}
GET  /jobs/{id}   {"job_id","status":queued|running|done|error,"result":{"text","segments","language","duration","output_file"},"error"}
```

Only `basic` mode exists; speaker labels and the LM Studio "roles" mode were
dropped. Video goes through ffmpeg directly. A file without an audio track
fails with `no audio track in <name> — nothing to transcribe`. Without
`output_dir`, the job JSON goes to the engine's own `jobs/` folder, never next
to the input.

The engine runs one job at a time. A warm voice note takes under a second; the
first start after install downloads the model (about 1.6 GB, Hugging Face
cache).

## Files

| Path | Holds |
| --- | --- |
| `~/.cache/mac-utilities/transcribe/` | `venv/` (Python 3.12, mlx-whisper without torch), `engine/` (a copy of the server and CLI), `jobs/`, `history/` (one JSON per transcript), `engine.log`, `replaced/` (the retired audio-notes plist) |
| `~/.config/mac-utilities/transcribe.json` | `save_next_to_source` (default true), `copy_when_done`, `language` (`""` = detect, `es`, `en`), `port`, `model` |
| `~/Library/LaunchAgents/com.mac-utilities.transcribe.plist` | the engine job |

A transcript is saved as `<name>.txt` beside the original, one line per
segment. An existing file is never overwritten: the next names are
`<name> transcript.txt`, `<name> transcript 2.txt`, and so on.

## Install

From the Mac Utilities manager, or:

```sh
brew install ffmpeg uv
transcribe/scripts/install.sh            # app to ~/Applications + engine
transcribe/scripts/install-engine.sh     # engine and `transcribe` only
```

`install-engine.sh` is idempotent. It rebuilds the venv only when
`engine/requirements.txt` changes, copies the engine out of the checkout,
retires a loaded `com.audionotes.transcription-server` job (its plist moves to
`replaced/`), refuses to start if something else holds the port, and links
`~/.local/bin/transcribe`. Under a temporary HOME (the manager's
`--no-system-effects` test mode) it does nothing.

## Uninstall

The manager removes the app and the menu bar item but does not run hooks, so
the engine stays. Remove it with:

```sh
transcribe/scripts/uninstall-engine.sh   # keeps history, settings and the model cache
```

## Tests

```sh
swift test --package-path transcribe                          # app core: client, saving, history, settings
/usr/bin/python3 -m unittest discover -s transcribe/engine    # engine contract with a fake model
```
