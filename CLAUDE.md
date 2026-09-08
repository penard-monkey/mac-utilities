# mac-utilities

Personal collection of Mac tooling. One utility per folder; the root holds only
shared glue. Utilities are meant to be worked on independently (often in
separate worktrees), so keep them self-contained and avoid shared libraries
unless two utilities genuinely need the same code.

## Conventions

- **SwiftBar plugins** go in `swiftbar/<utility>/` and follow SwiftBar's
  `<name>.<interval>.<ext>` naming (for example `memory.5s.py`). The plugin
  file is the entry point; helper files sit next to it in the same folder.
  `scripts/install.sh` symlinks `swiftbar/*/*.*.*` (skipping `.md/.json/.txt`)
  into SwiftBar's plugin folder, so anything matching that glob must be
  executable and must be a real plugin.
- **Python plugins** use `#!/usr/bin/python3` (the system 3.9, no pyenv, no
  third-party packages). SwiftBar runs plugins with a minimal environment, so
  never rely on the user's shell PATH; call binaries by absolute path or by
  names that resolve in `/usr/bin:/bin:/usr/sbin:/sbin`.
- **Per-utility state** lives under `~/.config/mac-utilities/` (settings the
  user chooses) and `~/.cache/mac-utilities/` (regenerable data such as
  history). Name files after the utility.
- **Menu bar items** should adapt to light/dark (SwiftBar sets
  `OS_APPEARANCE` to `Light`/`Dark`) and stay cheap: aim for well under 200 ms
  per run since they execute every few seconds.
- Each utility has a short `README.md` describing what it shows, how it
  computes it, and any user-facing options.

## Verifying a plugin

- Run it directly and strip base64 to read the SwiftBar output:
  `swiftbar/<u>/<plugin> | sed -E 's/image=[A-Za-z0-9+/=]+/image=<b64>/g'`
- `open -g "swiftbar://refreshplugin?name=<name>"` re-runs it immediately.
- For a real look, `screencapture -x -R 0,0,<width>,26 out.png` grabs the
  menu bar. On this Mac (notched display, macOS 26) the item lands to the
  left of the notch, roughly x=640–760 pt.
