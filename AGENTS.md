# mac-utilities

Personal collection of Mac tooling. One utility per folder; the root holds only
shared glue. Utilities are meant to be worked on independently (often in
separate worktrees), so keep them self-contained and avoid shared libraries
unless two utilities genuinely need the same code.

## Conventions

- **Two shapes of utility.** A menu-bar-only utility is a folder under
  `swiftbar/<utility>/` holding the plugin. Anything bigger (its own binaries,
  launchd jobs, installers) is a top-level folder `<utility>/` with whatever
  internal layout it needs, and its SwiftBar plugin, if any, in
  `<utility>/swiftbar/`. `gif-stickers/` is the model for the second shape.
- **SwiftBar plugins** follow SwiftBar's `<name>.<interval>.<ext>` naming
  (for example `memory.5s.py`). Installable utilities declare a
  `mac-utility.json` manifest next to their README. `scripts/install.sh`
  delegates selective installation to `utilities-manager`; plugins are linked
  from stable installed payloads into `~/.swiftbar`. Plugin scripts must be
  executable. `~/.swiftbar` is the single SwiftBar plugin folder on this Mac;
  never point SwiftBar anywhere else. No arguments lists installation status;
  use `install <id>` or the native manager to install a utility.
- **Utility-specific installers** (like `git-settings/scripts/install.sh`)
  handle their own system side (binaries, launchd, sudoers) and link their
  plugin into `~/.swiftbar` themselves; they must not touch SwiftBar's folder
  setting beyond making sure it is `~/.swiftbar`.
- **Python plugins** use `#!/usr/bin/python3` (the system 3.9, no pyenv, no
  third-party packages). SwiftBar runs plugins with a minimal environment, so
  never rely on the user's shell PATH; call binaries by absolute path or by
  names that resolve in `/usr/bin:/bin:/usr/sbin:/sbin`.
- **Installed payloads** live under `~/Library/Application Support/mac-utilities`,
  with ownership receipts; native apps live in `~/Applications`. Do not point
  installed tools into disposable development worktrees. Keep apps independent;
  the shared Tools plugin only launches them.
- **Per-utility state** lives under `~/.config/mac-utilities/` (settings the
  user chooses) and `~/.cache/mac-utilities/` (regenerable data such as
  history). Name files after the utility.
- **Menu bar items** should adapt to light/dark (SwiftBar sets
  `OS_APPEARANCE` to `Light`/`Dark`) and stay cheap: aim for well under 200 ms
  per run since they execute every few seconds.
- Each utility has a short `README.md` describing what it shows, how it
  computes it, and any user-facing options.

## Sharing files with the assistant

`_tmp` is a local, gitignored inbox symlink to a folder the user shares across
projects. Screenshots, logs, and other files the user wants looked at are
dropped there; read them from `_tmp/<file>`. Neither the symlink nor its contents belong in git, so treat it as an inbox, not a place for project files.
When you need to hand a file back (a rendered preview, an export), write it to
`_tmp/` as well.

## Verifying a plugin

- Run it directly and strip base64 to read the SwiftBar output:
  `swiftbar/<u>/<plugin> | sed -E 's/image=[A-Za-z0-9+/=]+/image=<b64>/g'`
- `open -g "swiftbar://refreshplugin?name=<name>"` re-runs it immediately.
- For a real look, `screencapture -x -R 0,0,<width>,26 out.png` grabs the
  menu bar. On this Mac (notched display, macOS 26) the item lands to the
  left of the notch, roughly x=640–760 pt.

## Planning docs

`task_plan.md`, `findings.md` and `progress.md` at the root of each worktree
are gitignored working memory. Read them at session start and keep them
current. At close-out they are tarballed into the session archive.

## Scratch files

Throwaway artifacts (build output, harness logs, screenshots you made) go in
`~/.cache/worktrees/mac-utilities/<worktree-name>/`, never the repo. Files for
the user to look at go in `_tmp/`.

## Close-out ritual

When a work stream is done, run the global `/close-out` skill. This repo's
paths and gates live in `.claude/close-out.md`. Short version: session summary
and planning tarball go to `docs/sessions/<date>-<slug>/` with a row in
`docs/sessions/index.md`, leftovers go to `ROADMAP.md`, all in one
`chore: close out <slug> session` PR.
