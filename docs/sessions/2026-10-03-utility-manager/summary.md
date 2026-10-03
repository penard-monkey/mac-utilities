# Utility manager, Git & SSH app, Tools launcher

- **Date:** 2026-10-03
- **Worktrees:** `.worktrees/git-management` (coordinator), `.worktrees/utilities-manager`,
  `.worktrees/git-settings-app` (all removed at close-out)
- **Branches:** `git-management` integrated the other two; all three worked by Codex
  lanes on `gpt-6.1-sol`, started by the coordinator
- **PR:** [#12](https://github.com/penard-monkey/mac-utilities/pull/12), squash-merged as `1518291`
- **Planning files:** `planning.tar.gz` holds each lane's `.planning/` folder
  (task plan, findings, progress, and the two sub-lanes' briefs)

## What shipped

- **Utility manifests.** Each utility has a `mac-utility.json` (schema 1: id, name,
  version, description, presentation `app` or `plugin`, install/uninstall commands,
  `privileged`, optional dependencies). Manifests exist for memory, Tools, GIF
  Stickers, Git & SSH and travel-router.
- **Selective installer.** `scripts/install.sh` no longer links every plugin. With no
  arguments it prints the catalog; `install`, `update`, `uninstall`, `menu … hide|show`,
  `open`, `--all` and `--remove` act per utility. Logic lives in
  `utilities-manager/backend/lifecycle.py` (system Python 3.9, standard library only).
  Sources are snapshotted to `~/Library/Application Support/mac-utilities/payloads`,
  ownership receipts guard every replace and remove, and apps go to `~/Applications`.
- **Mac Utilities manager** (`utilities-manager/`): a SwiftUI window over the same
  backend that installs, updates, removes, opens and hides utilities. It bundles a
  source snapshot so it keeps working after the checkout is gone.
- **Git & SSH app** (`git-settings/`): global Git identity, signing and defaults with
  config sources shown; SSH key inventory, Ed25519 generation, agent load/unload;
  SSH host aliases with safe edits; on-demand connection diagnostics. Changes go
  through a preview, apply and restore transaction.
- **Tools launcher** (`swiftbar/tools/tools.1m.py`): a menu bar item that opens the
  installed apps and the manager.
- **GIF Stickers installer** fixed for macOS's Bash 3.2.

## Decisions

- **One coordinator lane, two builder lanes.** The coordinator set the manifest
  contract, reviewed lane commits, and integrated them into one PR.
- **Standard-library Python backend** so the system `/usr/bin/python3` runs it with
  no packages.
- **Privileged utilities are "staged", not installed.** The manager never runs sudo;
  it shows the exact Terminal command for travel-router's system setup.
- **Uninstall keeps user data:** preferences, caches, Git config and SSH keys.
- **Dependencies are reported, never installed** (GIF Stickers' `img2webp`). No
  updater downloads anything.
- **Existing hand-made plugin links are adopted** only when they point into the same
  repository, keeping the old target for rollback.

## Dead ends and gotchas

- **Codex's sandbox blocks the defaults** for `git fetch` (FETCH_HEAD), the Swift and
  Clang module caches, and Python's bytecode cache. Point the caches at a writable
  directory; fetch needed an approved escalation.
- **macOS Bash 3.2 treats an empty array as unbound under `set -u`.** The GIF
  installer broke on it; use positional parameters instead.
- **SSH config insertion bug caught in review:** a new `Host` block was appended in a
  way that absorbed the file's global preamble. Fixed with a regression test.
- **Computer-use UI checks paused for minutes** on a per-app permission prompt the
  first time each app was driven.
- **`worktrees new --help` is not supported** and this CLI version lacked the
  report/messages commands; lanes used the MCP tools instead.
- **Hard-coded travel-router paths** in `lifecycle.py` were a shortcut; the
  publish-prep lane is moving them into the manifest.

## Verification

- 36 tests pass: manager lifecycle 15, Tools launcher 5, Git & SSH core 12, GIF
  engine 4. Rerun independently from a clean export before merging #12.
- Isolated temporary-home runs: full catalog install, hide, update, show and
  uninstall; Git & SSH preview, apply and restore of `user.name` on a fixture.
- Manager, Git & SSH, GIF Stickers and Tools installed on the host with valid
  signatures and receipts; memory and travel-router plugins untouched; no real Git or
  SSH changes made.

## Follow-ups

See ROADMAP.md: Git & SSH first-release limits, and exercising install and remove
through the manager window rather than only the command line.
