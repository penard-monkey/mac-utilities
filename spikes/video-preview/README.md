# Video Preview spike (throwaway)

A throwaway spike that tests whether an ad-hoc-signed Quick Look **preview
extension** can embed VideoLAN's VLCKit 3.x and play `.mkv` and `.webm` (with
sound, looping) in Finder's Space-bar panel, when it is installed the way our
release installer installs apps. This is not a utility: it has no manifest and
is not part of releases. The verdict and recipe live in the session archive
for this spike under `docs/sessions/`.

## Layout

- `VideoPreviewSpike.xcodeproj`: a hand-written project with two targets: a
  host app (`App/`) and the `.appex` (`PreviewExtension/`). SwiftPM cannot
  build app extensions.
- `scripts/fetch-vlckit.sh`: downloads VLCKit 3.7.3 from download.videolan.org,
  checks the pinned SHA-256 (it fails if the hash does not match) and unpacks
  `VLCKit.framework` into `Vendor/`, which is gitignored and never committed.
- `scripts/build.sh <out>`: builds unsigned with `xcodebuild`, then signs from the
  inside out (VLCKit, then the appex with its entitlements, then the app with
  its entitlements) and zips the result. `LAYOUT=dylib` replaces the framework
  with a flat `Contents/Frameworks/VLCKit.dylib`, because the release archiver
  and installer refuse symlinks. `SIGN_IDENTITY` and `SIGN_KEYCHAIN` select
  another identity (default `-`, ad hoc).
- `scripts/make-samples.sh <dir>`: generates synthetic samples with ffmpeg: a
  test pattern with a sine tone, as VP9/Opus WebM and as H.264/AAC MKV.

## Try it

```sh
LAYOUT=dylib /bin/bash scripts/build.sh ~/.cache/worktrees/mac-utilities/video-preview-spike/out
ditto ".../out/Video Preview Spike.app" ~/Applications/"Video Preview Spike.app"
open ~/Applications/"Video Preview Spike.app"   # once, to register the extension
qlmanage -r && qlmanage -p sample.webm
```

The extension logs to the `com.mac-utilities.video-preview-spike` subsystem
and also forwards libVLC's own log there:
`log stream --predicate 'subsystem == "com.mac-utilities.video-preview-spike"'`.
