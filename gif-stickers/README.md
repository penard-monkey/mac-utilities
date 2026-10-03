# GIF Stickers

A native, single-window Mac app that turns GIFs into WhatsApp-compatible WebP
sticker files. Requires macOS 14+, Xcode command-line tools to build, and the
Homebrew WebP encoder at `/opt/homebrew/bin/img2webp` (Apple Silicon) or
`/usr/local/bin/img2webp` (Intel). No third-party Swift packages.

## Install

```sh
brew install webp
./gif-stickers/scripts/install.sh
open "$HOME/Applications/GIF Stickers.app"
```

The installer builds the release executable, bundles GIF document associations,
and signs it locally. An optional destination directory is its first argument.
It does not change your default GIF application or install a background job.

## Use

1. Choose **File → Open GIF…** (⌘O), or drop a GIF onto the window or Dock icon.
2. In **Crop**, drag the square to choose its position. Drag the bottom-right
   corner to resize it, or scroll over the GIF to zoom around the square's center.
   The source GIF retains its aspect ratio. **Reset** centers the largest square.
3. Choose **Fit with transparent padding** to include the entire GIF.
4. Wait for the looping **512 × 512** preview. It plays the actual encoded WebP,
   with checkerboard behind transparent pixels. Changing the frame clears the old
   preview and prepares a new one after a short pause.
5. **Export Sticker…** (⌘S) saves exactly that preview, copies the WebP data and
   file URL to the clipboard, and reveals the file in Finder.

The status line reports encoded size, actual duration and frame count, sampling
rate, quality, and whether the input was trimmed. Export stays disabled until
there is a current, successful preview. GIFs over 8192 pixels per side or 10,000
frames are rejected; corrupt GIFs and missing encoder tools produce a clear error.

## Conversion

ImageIO decodes GIFs and CoreGraphics crops/scales each sampled frame to 512×512.
Fit uses a transparent canvas. ImageIO on the development Mac can read WebP but
cannot write it, so `img2webp` encodes PNG frames in a private temporary directory
which is removed after each conversion. There is no ffmpeg runtime dependency,
network upload, or persistent copy of your GIF.

The exporter samples the first 10 seconds, starting at 20 fps. It tries lossy
quality 90, 75, 55, 35, 15, then 1 before reducing the sampling rate to 15, 10, 6,
3, then 1 fps. Short GIFs have at least two samples when animated. Millisecond
frame durations sum to the duration cap; no frame lasts less than 8 ms. Identical
frames may be merged by the encoder. The resulting container is checked for
canvas dimensions and animation timing, and its actual byte count must meet the
applicable cap. If none of the attempts fits, export fails instead of saving an
oversized sticker. A one-frame GIF, or an animation that collapses to one image,
uses the static cap. GIFs slower than 20 fps may be resampled; these rates describe
sampling rather than distinct source frames. Changing the framing cancels obsolete
work between frames/encoding attempts; an in-progress encoder invocation finishes.

The [official WhatsApp sticker specification](https://github.com/WhatsApp/stickers/blob/main/Android/README.md)
requires WebP, exactly 512×512 pixels, animated files ≤500 KB, animation ≤10 seconds,
frame durations ≥8 ms, and static files ≤100 KB. This app uses conservative decimal
limits of 500,000 and 100,000 bytes. It loops animated output indefinitely. Pick a
strong first frame: WhatsApp rests on that frame after playback.

## Getting the sticker into WhatsApp

The export is a compatible image file, not an installed sticker pack. Copying or
dropping a `.webp` into a Desktop chat is **not a verified sticker-import path**;
it may attach it as a file or image. The app does not send messages.

The documented route is to transfer the WebP to your phone (for example with
AirDrop), import it using a sticker maker that explicitly accepts **animated WebP**,
and add its pack to WhatsApp. Then use the installed sticker from WhatsApp's sticker
picker on your phone or linked Mac. Check that the import retains animation; some
makers only accept static images or GIFs. The [official iOS guidance](https://github.com/WhatsApp/stickers/blob/main/iOS/README.md)
describes sticker-maker apps as an alternative to building a pack app, and
[WhatsApp's pack help](https://faq.whatsapp.com/1056840314992666) documents custom
packs on Android/iOS. Packs contain 3–30 stickers and must not mix static and
animated stickers. This utility exports individual files and does not build packs.

Research checked on 2026-10-02. Direct animated-WebP import on WhatsApp Desktop
for macOS remains unverified; no messaging integration or chat-send testing is
included.

## Development and verification

```sh
cd gif-stickers
swift build
swift test
```

Tests generate GIFs locally and independently inspect output using Homebrew
`webpmux`, covering square canvas, animation, transparent fit padding, static size,
10-second trimming, minimum frame duration, crop bounds, and invalid input.

In an environment that cannot run SwiftPM's nested sandbox, use
`swift test --disable-sandbox`. For the installer in that environment, set
`GIF_STICKERS_DISABLE_SANDBOX=1`. This only controls SwiftPM's build subprocess
sandbox; the app is a normal locally signed Mac app.
