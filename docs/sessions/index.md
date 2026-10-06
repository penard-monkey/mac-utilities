# Development log

One archive per working session. Each summary records what shipped, the
decisions and their reasoning, and the dead ends: what was tried, what failed,
and why. They are written for whoever picks the work up next, usually a fresh
agent with no memory of the session.

Each session's planning files (`task_plan.md`, `findings.md`, `progress.md`)
are archived beside its summary as `planning.tar.gz`.

| Date | Session |
| --- | --- |
| 2026-10-06 | [Video Preview](2026-10-06-video-preview/summary.md): Quick Look playback for MKV, WebM, AVI, FLV and WMV on VideoLAN's VLCKit, after a spike proved an ad-hoc-signed sandboxed extension loads; VLCKit ships as a flat dylib because release archives refuse symlinks |
| 2026-10-04 | [GIF Stickers still images and cut-out](2026-10-04-gif-stickers-images/summary.md): stickers from PNG/JPEG/HEIC/TIFF/WebP with an on-device Vision subject cut-out; static stickers need `cwebp` because `img2webp` wraps one frame in an animation container, and Vision cannot run on GitHub's virtual runners |
| 2026-10-04 | [GIF Stickers Add to Library and rename](2026-10-04-gif-stickers-add-rename/summary.md): export became a dialog-free Add to Library with safe, non-overwriting names, and stickers can be renamed; the filename is the name, groundwork for search |
| 2026-10-04 | [GIF Stickers library and send](2026-10-04-gif-stickers-library/summary.md): click the empty frame to open a file, a sticker library, and Send to my WhatsApp through saywhat's signed self-only endpoint. A direct-to-GOWA version was built and dropped so saywhat stays the one owner of the WhatsApp session |
| 2026-10-04 | [Git & SSH include rules](2026-10-04-git-includes/summary.md): inventory and edit include/includeIf profiles with the same preview/apply/restore safety, confined to referenced files inside the home folder |
| 2026-10-04 | [Releases and the public cut-over](2026-10-04-releases-and-public-cutover/summary.md): tagged releases, a curl installer and in-app updates; a fresh public repository because GitHub keeps PR refs; gotchas: Bash 3.2 empty arrays, GitHub merge emails, and launchd releasing a label after bootout returns |
| 2026-10-03 | [Transcribe](2026-10-03-transcribe/summary.md): an owned mlx-whisper engine on :8765 with an app, menu bar item and CLI, keeping the old HTTP contract so saywhat kept working |
| 2026-10-03 | [Public preparation](2026-10-03-publish-prep/summary.md): private utility extraction, external catalog sources, a removal PR, and a full-history privacy rehearsal; publication awaits hosted PR-ref cleanup, finished feature lanes and a license |
| 2026-10-03 | [Utility manager, Git & SSH, Tools launcher](2026-10-03-utility-manager/summary.md): a coordinator Codex lane and two builder lanes shipped per-utility manifests, a selective installer with ownership receipts, the Mac Utilities manager app, a Git & SSH settings app with preview/apply/restore, and a Tools menu. Gotchas: Codex's sandbox blocks default fetch and build caches, macOS Bash 3.2 rejects empty arrays under `set -u`, and an SSH host insert once swallowed the config's global preamble |
| 2026-10-03 | [GIF Stickers](2026-10-03-gif-stickers/summary.md): a native app that frames a GIF in a square and exports a 512×512 WebP sticker under WhatsApp's caps. ImageIO cannot encode WebP and Homebrew ffmpeg lacks animated WebP, so encoding shells out to `img2webp`. Tests pass; the UI itself was never driven by hand |
