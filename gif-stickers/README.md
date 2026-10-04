# GIF Stickers

A native, single-window Mac app that turns GIFs, videos and still images into
WhatsApp-compatible WebP sticker files. Requires macOS 14+, Xcode command-line
tools to build, and the
Homebrew WebP encoders (`img2webp` for animations and `cwebp` for stills) in
`/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel). No third-party
Swift packages.

## Install

```sh
brew install webp
./gif-stickers/scripts/install.sh
open "$HOME/Applications/GIF Stickers.app"
```

The installer builds the release executable, bundles GIF, video and image
document associations, and signs it locally. An optional destination directory is its first argument.
It does not change your default media application or install a background job.

## Use

1. Click the empty **Frame your sticker** box (or activate it with Return),
   choose **File → Open GIF, Video or Image…** (⌘O), or drop a file onto the window or
   Dock icon. With a file loaded, use **Choose another file…** to replace it;
   clicking the canvas keeps working for cropping. Besides GIFs, it takes the
   short looping videos many sites serve as "GIFs" (MP4, M4V or MOV), and
   PNG, JPEG, HEIC/HEIF, TIFF and static WebP images. Finder’s **Open With**
   also supports these formats. Animated WebP input is rejected with a clear message.
2. In **Crop**, drag the square to choose its position. Drag the bottom-right
   corner to resize it, or scroll over the animation to zoom around the square's center.
   The source keeps its aspect ratio. **Reset** centers the largest square.
3. Choose **Fit with transparent padding** to include the whole frame.
4. For a still image, optionally turn on **Cut out subject** (off by default).
   Vision removes the background on this Mac and keeps all detected subjects.
   The first attempt takes a moment; its result is cached while the image is
   loaded, so toggling and re-framing reuse it. If no subject is found or
   processing fails, the app explains the problem and keeps the original. If
   Vision cannot run on this Mac, the toggle is disabled for the session with
   “Subject cut-out isn’t available on this Mac.”
5. Wait for the **512 × 512** preview. It plays the actual encoded WebP,
   with checkerboard behind transparent pixels. Changing the frame clears the old
   preview and prepares a new one after a short pause.
6. **Add to Library** (⌘S) saves exactly that preview directly to the library,
   using the source filename without its extension. Unsafe filename characters
   are replaced; duplicate names get ` 2`, ` 3`, and so on. The status line
   confirms the name, and Library scrolls to and highlights the added sticker.
   **Send to my WhatsApp** sends the preview through SayWhat after confirmation.

The status line reports encoded size, actual duration and frame count, sampling
rate, quality, and whether the input was trimmed. Add to Library stays disabled
until there is a current, successful preview. GIFs over 8192 pixels per side or 10,000
frames are rejected; corrupt files and missing encoder tools produce a clear error.

## Conversion

ImageIO decodes GIFs. Videos are decoded with AVFoundation when the file is opened:
the first 10 seconds at the video's own frame rate, capped at 30 fps, upright as
recorded and scaled to at most 1024 pixels on the long side. Audio is ignored. A
video longer than 10 seconds is cut at 10 seconds and the status line says so.
Still images are decoded by ImageIO with EXIF orientation applied and capped
at 2048 pixels on the long side. PNG and other supported source transparency
is preserved. Optional subject lifting uses macOS 14+ Vision locally, before
framing, with no upload. All inputs then use the same framing and encoder.

CoreGraphics crops/scales each sampled frame to 512×512.
Fit uses a transparent canvas. ImageIO on the development Mac can read WebP but
cannot write it, so `img2webp` (animations) or `cwebp` (static stickers) encodes
PNG frames in a private temporary directory which is removed after each
conversion. Conversion requires no ffmpeg and performs no upload. Added stickers
persist as WebP files in the library;
source GIFs, videos and images are not copied into the library.

The exporter samples the first 10 seconds, starting at 20 fps. It tries lossy
quality 90, 75, 55, 35, 15, then 1 before reducing the sampling rate to 15, 10, 6,
3, then 1 fps. Short GIFs have at least two samples when animated. Millisecond
frame durations sum to the duration cap; no frame lasts less than 8 ms. Identical
frames may be merged by the encoder. The resulting container is checked for
canvas dimensions and animation timing, and its actual byte count must meet the
applicable cap. If none of the attempts fits, export fails instead of saving an
oversized sticker. A still image, a one-frame GIF, or an animation that collapses
to one image uses the static cap. Still images try only the quality settings, with no frame-rate
reduction. GIFs slower than 20 fps may be resampled; these rates describe
sampling rather than distinct source frames. Changing the framing cancels obsolete
work between frames/encoding attempts; an in-progress encoder invocation finishes.

The [official WhatsApp sticker specification](https://github.com/WhatsApp/stickers/blob/main/Android/README.md)
requires WebP, exactly 512×512 pixels, animated files ≤500 KB, animation ≤10 seconds,
frame durations ≥8 ms, and static files ≤100 KB. This app uses conservative decimal
limits of 500,000 and 100,000 bytes. It loops animated output indefinitely. Pick a
strong first frame: WhatsApp rests on that frame after playback.

## Sticker library

Choose **Library** at the top of the window for a grid of saved stickers. The
previews play the actual WebP, including animation and transparency. The grid
sorts by name. **Add to Library** saves without a dialog, clipboard copy or
Finder reveal.
The default folder is `~/Pictures/GIF Stickers`. **Choose Folder…** changes it;
the absolute path is stored as `library_folder` in
`~/.config/mac-utilities/gif-stickers.json`. Changing folders shows the new
folder and leaves existing stickers in their original location.

Drop existing **512 × 512 WebP** files into the library to import copies.
Dimensions, container integrity, frame timing, duration and the static/animated
size caps are validated. Originals stay in place. Invalid files are refused;
invalid WebPs already in the folder are skipped. **Refresh** picks up changes
made outside the app.

Each sticker offers **Send to my WhatsApp**, **Copy**, and a **More** menu with
**Reveal in Finder** and **Delete…**. Deletion asks for confirmation and moves
only that library file to Trash, where Finder can restore it. It leaves any
original import intact.

Use **Rename…** on a sticker or in its context menu to edit the name; the
`.webp` extension is kept. Return commits and Escape cancels. Names cannot be
empty, start with a dot, contain path separators (`/`, `\`, `:`) or control
characters, or exceed 200 characters (and must fit the filesystem byte limit).
Existing names are refused, ignoring case, so rename never overwrites a file.

## Send through SayWhat

Sending is optional. Run [SayWhat](https://github.com/penard-monkey/saywhat) with
its signed-send daemon at `http://127.0.0.1:3220` and WhatsApp paired. GIF
Stickers uses its self-only `POST /send` endpoint; SayWhat owns the WhatsApp
session and recipient selection. GIF Stickers never contacts GOWA directly.

The app reads `~/.local/share/saywhat/send.secret` only when a confirmed send
starts. It signs the timestamp and exact multipart bytes with HMAC-SHA256;
the key is never copied into app settings, logs or the library. No recipient
field is sent. The button is disabled with an explanation if the secret is
missing, the daemon is unavailable or WhatsApp is disconnected. Use
**Refresh SayWhat** after starting or reconnecting it.

Choose **Send to my WhatsApp** beside the preview or on a library sticker,
then confirm. The exact WebP is sent as a sticker to your own WhatsApp chat.
Open that chat **on your phone**, tap the received sticker and add it to
**Favourites** to reuse it from WhatsApp's sticker picker. A failed or uncertain
send is shown in the app; check the chat before retrying an uncertain delivery.
Sending is tested against local stub servers only; the first real send is a
user action after release.

## Transfer without SayWhat

The saved sticker is a compatible image file, not an installed sticker pack. Copying or
dropping a `.webp` into a Desktop chat is **not a verified sticker-import path**;
it may attach it as a file or image.

The documented route is to transfer the WebP to your phone (for example with
AirDrop), import it using a sticker maker that explicitly accepts **animated WebP**,
and add its pack to WhatsApp. Then use the installed sticker from WhatsApp's sticker
picker on your phone or linked Mac. Check that the import retains animation; some
makers only accept static images or GIFs. The [official iOS guidance](https://github.com/WhatsApp/stickers/blob/main/iOS/README.md)
describes sticker-maker apps as an alternative to building a pack app, and
[WhatsApp's pack help](https://faq.whatsapp.com/1056840314992666) documents custom
packs on Android/iOS. Packs contain 3–30 stickers and must not mix static and
animated stickers. This utility exports individual files and does not build packs.

Direct animated-WebP file import on WhatsApp Desktop for macOS remains
unverified. SayWhat sends through its own paired WhatsApp session instead.

## Development and verification

```sh
cd gif-stickers
swift build
swift test
```

Tests generate GIFs locally and independently inspect output using Homebrew
`webpmux`, covering square canvas, animation, transparent fit padding, static size,
10-second trimming, minimum frame duration, crop bounds, and invalid input.
Library tests use temporary homes and a fake Trash, covering direct add, safe
numbered filenames, rename validation, collision refusal, folder containment and
name sorting. Signed-send tests use
ephemeral loopback HTTP servers and temporary fake secrets, verifying exact
multipart bytes and signature, key rotation, availability, confirmation
cancellation, redirects and readable errors. They never read the real secret
or send a real WhatsApp message.

In an environment that cannot run SwiftPM's nested sandbox, use
`swift test --disable-sandbox`. For the installer in that environment, set
`GIF_STICKERS_DISABLE_SANDBOX=1`. This only controls SwiftPM's build subprocess
sandbox; the app is a normal locally signed Mac app.
