# Transcribe: local audio and video transcription

- **Date:** 2026-09-11 to 2026-10-03
- **Worktree:** `.worktrees/audio-transcription` (removed at close-out)
- **PR:** #17 in the private archive repository, carried into the public history
- **Planning files:** `planning.tar.gz`, sanitized for the public repository

## What shipped

- `transcribe/`: a local engine (mlx-whisper behind the same HTTP contract the
  older audio-notes server had, on 127.0.0.1:8765 under the launchd job
  `com.mac-utilities.transcribe`), a SwiftUI app (drop, queue, recent
  transcripts, Open With), a SwiftBar item, and a `transcribe` command in
  `~/.local/bin`.
- One manifest declares both the app and the plugin, with ffmpeg and uv as
  dependencies. Manifests may now use `~/` dependency paths, expanded against
  the manager's own home.

## Decisions

- **Own the engine** instead of calling an external checkout's virtualenv, and
  keep its HTTP contract so saywhat only had to stop installing the old job.
- **mlx-whisper, basic mode only.** No torch, a much smaller environment; no
  speaker labels in v1.
- **Transcripts save next to the source file.**
- It is a general file transcriber, separate from WhatsApp; saywhat calls the
  same engine.

## Dead ends and gotchas

- Without `output_dir` the engine writes `<stem>.json` next to the input.
- Dependency paths were absolute-only, which forced a username into the first
  manifest; fixed with `~/` expansion before the public cut-over.
- The engine installer reloaded the launchd job before launchd released it
  ("Bootstrap failed: 5"); fixed in v1.0.1 (see the releases session).

## Verification

Engine, app and manager test suites passed; an isolated install and uninstall
ran in a temporary home; saywhat was checked against the new engine.

## Follow-ups

See ROADMAP.md: speaker labels. The MLX engine needs Apple Silicon, though the app is universal.
