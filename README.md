# mac-utilities

Small, independent tools for this Mac, with a shared installer and Tools menu.

| Utility | Where it appears | What it does |
| --- | --- | --- |
| [Mac Utilities](utilities-manager/) | Tools → Manage Utilities… | Install, update, remove and show/hide individual utilities |
| [Git & SSH](git-settings/) | Tools → Git & SSH | Machine-level Git settings, SSH keys/hosts, backups and connection diagnostics |
| [GIF Stickers](gif-stickers/) | Tools → GIF Stickers | Native GIF cropping and WebP sticker export |
| [Memory](swiftbar/memory/) | Own menu-bar item | Memory usage and pressure, with configurable looks |
| [Transcribe](transcribe/) | Tools → Transcribe, own menu-bar item | Local audio/video transcription (mlx-whisper), saved next to the file; `transcribe` command |
| [Tools](swiftbar/tools/) | Shared menu-bar item | Launch installed utility apps and custom app entries |

## Install

Release tooling is being prepared; **no first release exists yet**. Keep current
installs until the public cut-over and first release are approved. See
[release verification and migration](docs/releases/) and the
[signing recommendation](docs/releases/signing.md).

Once a public release is published, install prebuilt apps without Swift:

```sh
curl -fsSL https://raw.githubusercontent.com/penard-monkey/mac-utilities/main/install.sh | bash
# Pin a release and choose optional utilities:
curl -fsSL https://raw.githubusercontent.com/penard-monkey/mac-utilities/v1.0.0/install.sh | \
  MAC_UTILITIES_INSTALL_VERSION=v1.0.0 MAC_UTILITIES_INSTALL=gif-stickers,memory bash
# From a downloaded installer:
bash install.sh update --all
bash install.sh uninstall memory
bash install.sh uninstall manager
```

The release installer puts Mac Utilities and Tools in their standard locations,
then installs named utilities (or offers a terminal choice). It requires every
artifact's SHA-256 checksum. Quarantine is retained unless explicitly requested
with `--strip-quarantine`. Receipt-owned checkout installs can be replaced in
place while preserving settings, caches, Git config and SSH keys; unowned or
modified installs are reported for review. Ad hoc builds may need fresh privacy
grants after updates. The manager’s **Updates** tab checks and installs releases,
then relaunches after updating itself. External sources update from their folders.

For development, build the manager and Tools menu from your selected checkout:

```sh
scripts/install.sh manager
open "$HOME/Applications/Mac Utilities.app"
```

Then install **Git & SSH**, **GIF Stickers**, or any other utility from the
manager. Apps open in independent native windows. Memory keeps its own status
item. Hiding an item is separate from uninstalling it.

Requires macOS 14+, Apple's Swift toolchain to build native apps, and SwiftBar
for menu-bar items. GIF Stickers also needs Homebrew `webp`, and Transcribe needs
`ffmpeg` and `uv`; the manager reports missing dependencies. Transcribe's
engine stays installed after the manager removes the app; see its README.
Privileged utilities from extra repositories retain their own administrator
setup and removal scripts.

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

With external catalog support, add an independent utility repository in the
manager with **Add source…**, or run `scripts/install.sh source add <folder>`.
Sources are recorded in `~/.config/mac-utilities/sources.json`; duplicate
utility IDs are reported explicitly. Extra repositories are kept out of the
manager's bundled catalog. See [catalog sources](utilities-manager/#additional-catalog-sources).

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
