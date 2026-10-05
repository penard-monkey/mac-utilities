# GIF Stickers 1.3.0: stickers from still images, with subject cut-out

- **Date:** 2026-10-04
- **Worktree:** `.worktrees/gif-stickers-images` (removed at close-out)
- **PR:** #12
- **Release:** v1.3.0
- **Planning files:** `planning.tar.gz`, sanitized

## What shipped

- **Still images in:** PNG, JPEG, HEIC/HEIF, TIFF and static WebP through File >
  Open, the empty frame, drag and drop, the Dock and Open With. EXIF orientation
  is applied, decoding is capped for memory, and a still image is a one-frame
  asset, so framing, preview, Add to Library, rename and Send work unchanged.
- **Static output:** exactly 512x512 WebP, at most 100 KB, alpha preserved.
- **Cut out subject:** a toggle for still images using Vision's
  `VNGenerateForegroundInstanceMaskRequest`, on-device, cached per image.

## Decisions

- **Static stickers use `cwebp`**, animations keep `img2webp`; both come from
  the Homebrew `webp` package and both are declared in the manifest.
- **No visual UI check by an agent.** The user declined Computer Use for the
  lane; the UI is checked by hand after release.
- When Vision cannot run, the app disables the cut-out for the session with a
  clear message and keeps the original image.

## Dead ends and gotchas

- `img2webp` wraps a single transparent frame in an animation container
  (ANMF), which is not a valid static sticker. Use `cwebp` for stills.
- **Vision cannot run on GitHub's macos-14 runner**: "Could not create inference
  context" (error 9), as the virtual machine has no Neural Engine or GPU. The
  real Vision test skips only for that error or when no subject is found; a
  Vision-independent mask test always runs.
- The prompt for Computer Use named only "GIF Stickers", which is also the
  installed app's name, so it could not prove it was limited to the test build.

## Verification

38 GIF Stickers tests locally, including the real Vision cut-out on a physical
Mac; CI green with the Vision test skipped there. A v1.3.0 release build
produced a signed universal app with its icon and seven new image document
types.

## Follow-ups

See ROADMAP.md: check the image and cut-out UI by hand.
