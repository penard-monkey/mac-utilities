# mac-utilities

A grab bag of small tools, widgets and menu bar items for my Mac. Each utility
lives in its own folder and is self-contained; the repo root only holds the
glue (install script, docs).

## Layout

```
swiftbar/<utility>/<name>.<interval>.<ext>   menu-bar-only utilities: one folder per plugin
<utility>/                                   bigger utilities with their own bin/, scripts/, launchd/, swiftbar/…
scripts/install.sh                           symlinks every SwiftBar plugin into ~/.swiftbar
```

## Utilities

| Utility | Kind | What it does |
| --- | --- | --- |
| [memory](swiftbar/memory/) | SwiftBar | Memory used vs. installed in the menu bar, six looks, Activity Monitor style breakdown |

## Install

```sh
scripts/install.sh            # link all plugins into SwiftBar, refresh
scripts/install.sh --remove   # unlink them again
```

All plugins are symlinked into `~/.swiftbar`, a plain folder that SwiftBar is
pointed at (the script sets that preference and relaunches SwiftBar if it was
pointing elsewhere). Symlinks, not copies: editing a file in this repo is live
on the next refresh.

## Working on a utility

Run a plugin directly to see exactly what SwiftBar sees:

```sh
swiftbar/memory/memory.5s.py | sed -E 's/image=[A-Za-z0-9+/=]+/image=<b64>/g'
```

Force a refresh without waiting for the interval:

```sh
open -g "swiftbar://refreshplugin?name=memory"
```
