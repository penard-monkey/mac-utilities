# mac-utilities

Small, independent tools for this Mac, with a shared installer and Tools menu.

| Utility | Where it appears | What it does |
| --- | --- | --- |
| [Mac Utilities](utilities-manager/) | Tools → Manage Utilities… | Install, update, remove and show/hide individual utilities |
| [Git & SSH](git-settings/) | Tools → Git & SSH | Machine-level Git settings, SSH keys/hosts, backups and connection diagnostics |
| [GIF Stickers](gif-stickers/) | Tools → GIF Stickers | Native GIF cropping and WebP sticker export |
| [Memory](swiftbar/memory/) | Own menu-bar item | Memory usage and pressure, with configurable looks |
| [Tools](swiftbar/tools/) | Shared menu-bar item | Launch installed utility apps and custom app entries |

## Install

Build the manager and install the shared Tools menu:

```sh
scripts/install.sh manager
open "$HOME/Applications/Mac Utilities.app"
```

Then install **Git & SSH**, **GIF Stickers**, or any other utility from the
manager. Apps open in independent native windows. Memory keeps its own status item. Hiding an item is separate from uninstalling it.

Requires macOS 14+, Apple's Swift toolchain to build native apps, and SwiftBar
for menu-bar items. GIF Stickers also needs Homebrew `webp`; the manager reports
missing dependencies. Privileged utilities retain their own administrator setup and removal scripts.

The manager includes a source catalog, so installed tools keep working after
a development worktree is removed. Select a newer checkout in the manager to
update its utilities. Applications live in `~/Applications`, utility payloads
in `~/Library/Application Support/mac-utilities`, and SwiftBar links in
`~/.swiftbar`. SwiftBar must always use that one plugin directory.

Settings remain in `~/.config/mac-utilities`, caches in
`~/.cache/mac-utilities`. Uninstall preserves preferences, Git configuration
and SSH keys. Ownership receipts protect unrelated files from removal.

## Command line

```sh
scripts/install.sh                       # list catalog/status
scripts/install.sh install git-settings
scripts/install.sh update gif-stickers
scripts/install.sh menu memory hide
scripts/install.sh menu memory show
scripts/install.sh uninstall git-settings
```

The old no-argument blanket plugin-link operation now lists status. Explicit
`--all` installs available utilities; `--remove` removes managed nonprivileged
utilities. See [Mac Utilities](utilities-manager/) for isolation flags,
legacy plugin migration, manifests and privileged-tool handling.

## Layout and development

- `swiftbar/<utility>/` contains menu-bar-only utilities.
- `<utility>/` contains larger tools, their native source/installers, and any
  `swiftbar/` plugin.
- Each installable utility has a `mac-utility.json` manifest.
- Root `scripts/install.sh` delegates to the shared lifecycle manager.

Utilities remain self-contained. Work in managed worktree places; install from
the selected checkout when you want an updated stable copy. Source edits do
not automatically change installed plugins.

Run a plugin directly to inspect its output:

```sh
swiftbar/memory/memory.5s.py | sed -E 's/image=[A-Za-z0-9+/=]+/image=<b64>/g'
swiftbar/tools/tools.1m.py
```

Refresh an installed plugin:

```sh
open -g "swiftbar://refreshplugin?name=tools"
```

The [Tools README](swiftbar/tools/) explains custom launchers. Each utility's
README documents its behavior, options and verification commands.
