# Video Preview: Quick Look playback for MKV and WebM, built on VLCKit

- **Date:** 2026-10-06
- **Worktree:** `.worktrees/video-preview-spike` (removed at close-out)
- **Branches:** `video-preview-spike` (signing spike, kept for reference),
  `video-preview` (the utility)
- **PR:** #14
- **Release:** v1.4.0
- **Planning files:** `planning.tar.gz`, sanitized, with the spike notes

## What shipped

- `video-preview/`: a host app plus a Quick Look preview extension that plays
  MKV, WebM, AVI, FLV and WMV with sound, looping, click to pause. Built from an
  Xcode project, since Swift packages cannot build app extensions.
- VLCKit 3.7.3 from VideoLAN, fetched by `scripts/fetch-vlckit.sh` pinned to
  the exact URL and SHA-256, never committed.
- The release builder gained a utility build hook and bundle verification;
  workflows pin Xcode 15.4 and cache VLCKit.
- Manifests can declare `app.extensions`; the manager registers them after
  install and unregisters them before removal.

## Decisions

- **Our own extension, not a fork of QLCodec.** QLCodec's custom license grants
  no right to modify or redistribute its code, and it is only a thin wrapper
  around VLCKit anyway. Supply-chain trust is VideoLAN plus our own reviewed
  code.
- **Spike first.** A throwaway build answered whether an ad-hoc-signed,
  sandboxed extension with VLCKit loads when installed like our installer does.
  It did, so no certificate was needed.
- Formats are added only when verified with a generated sample; `.ogv` was left
  out because no Theora encoder was available.

## Dead ends and gotchas

- **VLCKit.framework contains symlinks**, which our release archives and
  installer refuse on purpose. Ship it as one flat `VLCKit.dylib` with its
  install names rewritten.
- **Quarantined downloads do not register the extension**: Gatekeeper prompts,
  App Translocation kicks in, and pluginkit never sees it. The curl installer
  does not set quarantine; browser downloads need Open Anyway.
- VLCKit quirks: `VLCMediaListPlayer` never leaves Stopped and `:input-repeat`
  pauses at the end; use `VLCMediaPlayer` and restart from its delegate.
- The sandbox blocks reading the video's folder, so sidecar subtitles do not
  load.
- `scripts/release/test.sh` used `rg`, which the GitHub runner lacks, so several
  Python suites were silently skipped in CI until this PR switched to `find`.

## Verification

The user confirmed in Finder that all five formats play with sound, loop and
pause on click, using a separately named dev build that was removed afterwards.
CI built and verified the universal app on macos-14 with Xcode 15.4; a local
release build and isolated install and update passed.

## Follow-ups

See ROADMAP.md: check the host app window, and `.ogv`.
