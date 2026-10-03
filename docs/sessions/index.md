# Development log

One archive per working session. Each summary records what shipped, the
decisions and their reasoning, and the dead ends: what was tried, what failed,
and why. They are written for whoever picks the work up next, usually a fresh
agent with no memory of the session.

Each session's planning files (`task_plan.md`, `findings.md`, `progress.md`)
are archived beside its summary as `planning.tar.gz`.

| Date | Session |
| --- | --- |
| 2026-10-03 | [Utility manager, Git & SSH, Tools launcher](2026-10-03-utility-manager/summary.md): a coordinator Codex lane and two builder lanes shipped per-utility manifests, a selective installer with ownership receipts, the Mac Utilities manager app, a Git & SSH settings app with preview/apply/restore, and a Tools menu. Gotchas: Codex's sandbox blocks default fetch and build caches, macOS Bash 3.2 rejects empty arrays under `set -u`, and an SSH host insert once swallowed the config's global preamble |
| 2026-10-03 | [GIF Stickers](2026-10-03-gif-stickers/summary.md): a native app that frames a GIF in a square and exports a 512×512 WebP sticker under WhatsApp's caps. ImageIO cannot encode WebP and Homebrew ffmpeg lacks animated WebP, so encoding shells out to `img2webp`. Tests pass; the UI itself was never driven by hand |
