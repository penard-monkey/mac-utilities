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
  `<utility>/swiftbar/`. `gif-stickers/` and `git-settings/` model the second shape.
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
- **Shell scripts** must run under macOS's `/bin/bash` 3.2, which is what
  users and CI have. With `set -u`, never expand a possibly empty array as
  `"${arr[@]}"`: use positional parameters (`set -- …; "$@"`) or
  `${arr[@]+"${arr[@]}"}`. Test scripts with `/bin/bash` explicitly, not the
  Homebrew bash on your PATH.
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

`_tmp` is a local, gitignored symlink to a folder the user shares across
projects. Screenshots, logs, and other files the user wants looked at are
dropped there; read them from `_tmp/<file>`. Keep the symlink and its target
out of git, and leave existing links on disk. Treat it as an inbox, not a place for project files.
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

<!-- worktrees:rules v1 sha=5b0e980407f1d471 — managed by `worktrees rules apply`; edit outside this block, or it stops updating -->
## Working with worktrees

This repository is managed by [worktrees](https://github.com/penard-monkey/worktrees):
every branch lives in its own PLACE, a git worktree under `.worktrees/<slug>`
plus a tmux session. `(main)` is the repository root and stays on the default
branch. If worktrees launched you, you also have the `worktrees` skill: it is
newer than this section and wins where they differ (`worktrees guide` prints
it). Without worktrees installed, ignore this section.

- **Branch work:** MCP `create_worktree {branch}` or `worktrees new <branch>
  --no-attach`, then work in `.worktrees/<slug>`. Never `git worktree add`;
  never switch branches in `(main)` or in a place that is not yours.
- **Spin up a lane** (hand work to another agent): `create_worktree {branch,
  provider, model, brief}` or `worktrees new <branch> --ai claude --brief
  "<text>" --no-attach`. The brief lands in `.planning/brief.md` and is the
  whole handover: goal, deliverable, rules, and when to stop and report. Never
  type an agent command into a pane.
- **Which tool:** `list_places` (every place) · `place_status` (one place: is
  its agent busy, what is its plan) · `report` / `messages` / `wait` (talk
  between places, wait for an agent to go idle) · `send` (type into a Codex or
  pi pane; check it is not mid-input first) · `show_doc` (open a file for the
  user) · `set_note` / `set_lifecycle` · `remove_worktree` (needs `confirm`).
  Claude sessions can also `SendMessage` the place's tmux session name.
- **A place with a running agent belongs to that agent.** Do not edit its
  tree; message it.
- **Planning:** plans are working memory in `.planning/` inside each place
  (`task_plan.md`, `findings.md`, `progress.md`). Not committed.
- **Finishing:** commit, push and open the pull request from the place. After
  it merges, remove the place or park it on a fresh `<place>-next` branch. At
  the end of a work stream, run the `close-out` skill.
- **Never touch:** another place's working tree, a branch checked out in
  another worktree, a harness's own state files (`~/.claude.json`), or a
  running app you did not start.
<!-- worktrees:rules end -->
