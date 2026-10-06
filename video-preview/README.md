# Video Preview

Press **Space** on a video in Finder and it plays in the Quick Look panel, with
sound. Video Preview adds a Quick Look preview extension for formats macOS
can't preview itself, and plays them with VideoLAN's
[VLCKit](https://code.videolan.org/videolan/VLCKit) 3.7.3.

| Format | Extension | Checked with a generated sample |
| --- | --- | --- |
| Matroska | `.mkv` | H.264 + AAC |
| WebM | `.webm` | VP9 + Opus |
| AVI | `.avi` | MPEG-4 Part 2 + MP3 |
| Flash video | `.flv` | H.264 + AAC |
| Windows Media | `.wmv` | WMV2 + WMA2 |

Videos loop. Clicking the video pauses it, and clicking again resumes. Ogg video (`.ogv`) isn't
registered because no Theora sample could be generated to verify it.

Requires macOS 14+. It needs no other dependencies once installed.

## The app

**Video Preview.app** registers the extension when it launches and shows:

- the supported formats;
- the extension's state as Quick Look sees it (on, off, or not registered),
  with **Turn On**/**Turn Off** (`pluginkit -e use|ignore`);
- **Refresh Quick Look** (`qlmanage -r` and `qlmanage -r cache`), which helps
  when Finder keeps showing an icon or its own preview;
- the VLCKit notice and licenses.

The app doesn't need to stay open. Quick Look runs the extension on its own.

## Install

From a release, select `video-preview` in the Mac Utilities manager or with
`MAC_UTILITIES_INSTALL=video-preview` in the installer. The manager puts the
app in `~/Applications` and then registers the extension (`lsregister -f`,
`pluginkit -a`, `qlmanage -r`). Uninstalling unregisters it and refreshes
Quick Look.

**Downloaded with a browser?** The app is only ad hoc signed, so a quarantined
copy is blocked by Gatekeeper and runs from a temporary translocated folder,
where its extension is never registered. Use the installer, which does not
add quarantine, or use `--strip-quarantine` with an installer that does. You
can also open the app once, then allow it under **System Settings → Privacy &
Security → Open Anyway**.

From a checkout (needs Xcode, and downloads VLCKit once):

```sh
video-preview/scripts/install.sh            # builds into ~/Applications
open "$HOME/Applications/Video Preview.app"   # registers the extension
```

## Limits

- **Subtitle files next to a video are not loaded.** The extension runs in
  the App Sandbox, which only grants access to the previewed file, not to its
  folder. Subtitles embedded in the file (for example in MKV) work.
- One preview at a time plays. Leaving the preview stops playback.
- Formats macOS already previews (MP4, MOV, M4V) are left to macOS.

## How it is built

`VideoPreview.xcodeproj` has two targets: the host app and the
`VideoPreviewQuickLook` app extension. SwiftPM can't build app extensions, so
the project is built with `xcodebuild`.

- `scripts/fetch-vlckit.sh [dir]`: downloads VLCKit 3.7.3 from
  download.videolan.org, verifies the pinned SHA-256 and unpacks
  `VLCKit.framework` into `Vendor/` (gitignored). The archive is cached in
  `~/.cache/mac-utilities/vlckit`.
- `scripts/build.sh --output <dir> [--version X.Y.Z] [--dev]`: builds
  unsigned. It copies VLCKit's single library into the extension as a flat
  `Contents/Frameworks/VLCKit.dylib`, because release archives refuse the
  framework's symlinks, and rewrites the install names with
  `install_name_tool`. It then signs from the inside out, ad hoc: the dylib,
  then the extension with `QuickLookExtension.entitlements` (App Sandbox plus
  read-only user-selected files), then the app. `--dev` builds
  **Video Preview Dev.app** (`com.mac-utilities.video-preview.dev`), so a
  development copy never collides with an installed release. The release
  builder runs this script through `release.build` in `mac-utility.json`.
- `scripts/make-samples.sh <dir>`: generates synthetic test videos with ffmpeg
  (a test pattern with a tone). No media is committed.

The extension logs to the `com.mac-utilities.video-preview` subsystem
(`log stream --predicate 'subsystem == "com.mac-utilities.video-preview"'`):
one line when playback starts, plus libVLC errors.

Tests: `python3 -m unittest discover -s video-preview/tests` checks the pinned
fetch and plist consistency, then builds a dev app and checks the relinked
dylib, signatures, entitlements, licenses and the release verification. Set
`VIDEO_PREVIEW_SKIP_BUILD_TESTS=1` to skip the build.

## License

Video Preview is MIT licensed, like the rest of this repository. VLCKit is
LGPL-2.1-or-later. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
[licenses/LGPL-2.1.txt](licenses/LGPL-2.1.txt). Both also ship in the app's
Resources.
