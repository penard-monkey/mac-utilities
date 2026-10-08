# Changelog

## [1.5.2]

- QR Reader 1.0.2: the approval window shows the link again. The payload box
  rendered empty and the window was narrower than its contents, clipping the
  box and the Cancel button. Detail values now wrap instead of truncating.

## [1.5.1]

- QR Reader 1.0.1: region scans decode again; the capture was deleted before it
  was read.

## [1.5.0]

- New utility, **QR Reader** 1.0.0: drag a box around a QR code on screen and
  see exactly what it would do before anything happens. The approval window
  shows the payload in full, with the host highlighted, and lists what is wrong
  with it — credentials before the host (`https://apple.com@evil.tld/`),
  punycode shown decoded, mixed alphabets, invisible or direction-changing
  characters, `%00`, known shorteners, cleartext `http`, raw IP hosts and odd
  ports. Cancel is the default, Escape and closing the window deny, and nothing
  is ever on a timer.
- QR Reader never opens `otpauth:` (the secret is masked on screen and redacted
  in history), `javascript:`, `data:`, `file:`, `vbscript:` or `about:`. Any
  other scheme costs a second confirmation. Wi-Fi codes are shown, not joined.
- Scan from a screen region, the clipboard or an image file. Clipboard and file
  scans need no permission; region scans need Screen Recording, which macOS
  fails silently without, so the app checks and asks for it explicitly.
- Scan history is redacted before it is written (Wi-Fi passwords, OTP secrets,
  URL userinfo, credential-ish query parameters), kept at mode 600, newest 100,
  and the last five show in the menu bar item.

## [1.4.0]

- New utility, **Video Preview**: press Space in Finder to play MKV, WebM,
  AVI, FLV and WMV videos with sound in Quick Look. Videos loop, and a click
  pauses them. Playback uses VideoLAN's VLCKit 3.7.3 (LGPL-2.1+). The app
  shows the extension's state, can turn it on or off, and refreshes Quick Look.
- Mac Utilities registers an app's bundled extensions after installing it and
  unregisters them before removal (`app.extensions` in the manifest).
- Release builder: utilities can supply their own build hook (Video Preview
  builds with Xcode). Every bundled binary is now checked for both
  architectures and the macOS 14 target, and extensions for the App Sandbox.

## [1.3.0]

- GIF Stickers: open PNG, JPEG, HEIC/HEIF, TIFF and static WebP images,
  upright and with transparency preserved, and export static 512×512 stickers
  within WhatsApp’s 100 KB limit.
- Optional **Cut out subject** removes still-image backgrounds on-device,
  keeps all detected subjects, and caches the result for quick re-framing.

## [1.2.0]

- GIF Stickers: Add to Library (⌘S) saves the preview directly, with a safe
  source filename and numbered collisions, and highlights it in the library.
- Rename library stickers with validation and collision protection; the grid
  now sorts by name.

## [1.1.1]

- Tools: the menu bar glyph is drawn at 18 pt instead of twice that size.

## [1.1.0]

- GIF Stickers: save exports into a configurable sticker library with animated
  previews, validated WebP imports, copy/reveal actions and confirmed Trash.
- Send previewed or saved stickers to your own WhatsApp chat through SayWhat's
  signed daemon, with confirmation, connection help and readable errors.

- GIF Stickers: click or use the keyboard to open a file from the empty frame,
  and choose a replacement without interfering with cropping or drag and drop.

- Git & SSH lists include rules and profile overrides, edits referenced profiles
  inside the home folder, and previews adding, changing or removing rules.
- Create a profile by adding its rule and applying settings to the new file;
  removing a rule preserves the profile. Profile edits retain lock, symlink,
  stale-preview and guarded-backup protections.
- Check effective commit identity and signing settings for a chosen folder,
  with the configuration origin and scope reported by Git.

## [1.0.1]

- Transcribe: updating from the manager no longer fails with "Bootstrap
  failed: 5: Input/output error". The engine installer now waits for launchd
  to release the old job before loading the new one, and retries the load
  briefly, so an update can no longer leave the engine stopped.

## [1.0.0]

- Install Mac Utilities with a checksum-verified `curl | bash` installer, with
  optional utility selection and pinned release versions.
- Download universal macOS 14+ app bundles for Mac Utilities, Git & SSH,
  GIF Stickers and Transcribe; install plugins and engine sources from a
  standalone release catalog.
- Check and install releases from the manager's Updates tab, including manager
  replacement and relaunch. External utility sources keep updating from folders.
- Migrate healthy receipt-owned checkout installs in place, keeping preferences,
  caches, Git configuration, SSH keys and menu visibility.
- Build releases on approved `v*` tags; prove artifacts without publishing via
  workflow dispatch. Run every utility test suite on pull requests.

These builds use ad hoc signing. Quarantine removal requires explicit opt-in;
privacy grants may need renewal. A persistent signing identity remains a user
choice; see `docs/releases/signing.md`.
