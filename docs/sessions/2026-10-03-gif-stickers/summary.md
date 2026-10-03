# GIF Stickers: GIFs into WhatsApp stickers

- **Date:** 2026-10-02 to 2026-10-03
- **Worktree:** `.worktrees/gif-stickers` (removed at close-out)
- **Branch:** `gif-stickers`, worked by a Codex lane (`gpt-6.1-sol`) started from a brief
- **PR:** [#9](https://github.com/penard-monkey/mac-utilities/pull/9), squash-merged as `9e5ccf8`
- **Planning files:** `planning.tar.gz` here holds `task_plan.md`, `findings.md`, `progress.md` and the lane's `brief.md`

## What shipped

A native single-window SwiftUI app in `gif-stickers/` that turns a GIF into a
WhatsApp sticker file.

- `gif-stickers/Sources/GIFStickers/App.swift` is the editor. The GIF keeps
  its own aspect ratio and a square frame sits over it: drag to move, drag the
  corner to resize, scroll to zoom. A fit mode letterboxes the whole GIF with
  transparent padding. The right side plays the actual encoded 512×512 WebP on
  a checkerboard.
- `gif-stickers/Sources/GIFStickers/Engine.swift` decodes with ImageIO, renders
  each sampled frame with CoreGraphics, and encodes with Homebrew `img2webp`.
  It trims to 10 s and lowers quality, then frame rate, until the file fits
  the cap.
- Export saves the previewed file, copies it to the clipboard and reveals it
  in Finder.
- `gif-stickers/scripts/install.sh` builds, bundles with GIF document
  associations, ad-hoc signs, and installs to `~/Applications`.
- `gif-stickers/Tests/GIFStickersTests/EngineTests.swift` has four
  integration tests on generated GIFs.

## Decisions

- **Target spec** comes from WhatsApp's official sticker repo: WebP, exactly
  512×512, animated at most 500 KB and 10 s, static at most 100 KB, frame
  delay at least 8 ms. Limits are treated as decimal bytes to stay safe.
- **Encoder is `img2webp`, not ImageIO or ffmpeg.** ImageIO on this macOS
  decodes WebP but cannot encode it. The Homebrew ffmpeg build lacks
  `libwebp_anim`. So decoding and rendering stay native and only encoding
  shells out, with a clear in-app error if the tool is missing.
- **No Swift packages.** Nothing needed one.
- **Getting it into WhatsApp** is documented as the phone sticker-pack route.
  No messaging integration was built, per the brief.
- **A SwiftBar "Tools" launcher was added and then reverted** inside this
  branch. Managing and launching utilities belongs to the other lanes, so the
  merged scope is `gif-stickers/` only.

## Dead ends and gotchas

- **ImageIO cannot write WebP** on this Mac, even though it reads it. Do not
  plan on a dependency-free encoder.
- **ffmpeg here cannot make animated WebP** (no `libwebp_anim`). Use
  `img2webp` or `gif2webp` from the `webp` formula.
- **Sandboxed `swift build` failed** writing the module cache. Builds pointed
  the cache under `/tmp`.
- **Codex's automatic approval review refused to launch the locally built
  app** as unrecognized software. The lane did not work around it, so the UI
  was never driven interactively.
- Codex also stopped at its one-time "trust this folder" prompt on first
  launch; a new Codex lane needs that accepted once per repo.

## Verification

- Command-line spike before any UI: square crop, 512 scale, `img2webp` at
  quality 80 gave 45 frames, 3.015 s, 486,648 bytes. `webpmux` confirmed
  512×512, animated, infinite loop.
- Four tests pass. A noisy 24-frame fixture forced the frame-rate fallback and
  landed at 381.5 KB, 2.4 s, 15 frames, 6 fps sampling, quality 1. A long GIF
  summed to exactly 10,000 ms. Fit-mode transparency was checked on the alpha
  channel. A one-frame export stayed under 100 KB.
- Release build, installer staging and bundle signature verified.
- **Not verified:** the app was never launched and used by hand, and dropping
  a WebP into WhatsApp Desktop as a sticker was never tried.

## Follow-ups

See ROADMAP.md: hands-on UI check, WhatsApp Desktop import, and the frame-rate
fallback reaching quality 1 on noisy GIFs.
