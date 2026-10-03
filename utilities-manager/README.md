# Mac Utilities

A native SwiftUI window for selectively installing, updating, opening, and removing
Mac tooling. It shows five catalog entries: Tools, Memory, Travel Router,
GIF Stickers, and Git & SSH. Menu visibility is independent of installation.
Apps appear through the Tools launcher; menu-only utilities use SwiftBar.

## Install and open

```sh
scripts/install.sh manager               # ~/Applications/Mac Utilities.app
open "$HOME/Applications/Mac Utilities.app"
# Or choose an application destination:
utilities-manager/scripts/install.sh /path/to/Applications
```

Requires macOS 14+, Apple's Swift toolchain, and system `/usr/bin/python3`.
The installer records ownership of the manager app, signs it ad hoc, and includes a source snapshot for every
manifest available in the checkout. It also installs Tools when its manifest
is available. The app continues working after the checkout is removed. A pre-existing unowned
manager bundle is left alone; move it aside before installing a managed copy.
`utilities-manager/scripts/uninstall.sh [destination]` removes only the verified
manager app and keeps installed tools and preferences.
Choose a newer complete checkout in the window to update utilities; **Bundled
source** returns to the shipped snapshot. Updates deliberately rebuild even
when a utility's version number has not changed.

A missing tool source stays in the catalog with an actionable prompt. GIF
Stickers' encoder dependency is reported rather than installed automatically.
No updater downloads software or modifies Homebrew.

## Selective command line

```sh
scripts/install.sh                       # catalog/status JSON; no blanket install
scripts/install.sh install memory
scripts/install.sh update memory
scripts/install.sh menu memory hide
scripts/install.sh menu memory show
scripts/install.sh open gif-stickers
scripts/install.sh uninstall memory
scripts/install.sh --all                 # all available manifests; privileged hooks skipped
scripts/install.sh --remove              # owned nonprivileged utilities only
```

The former no-argument worktree-link installer now lists the catalog. Use
`--all` to request installation deliberately. No worktree symlinks are created:
source payloads live under `~/Library/Application Support/mac-utilities/payloads`.
Apps go in `~/Applications`, receipts in the support folder's `state/receipts`,
and SwiftBar links in `~/.swiftbar`. The backend only points SwiftBar at that
shared folder; an already-running SwiftBar may need a manual relaunch if its
folder was previously different.

Preferences remain under `~/.config/mac-utilities` and caches under
`~/.cache/mac-utilities`. Uninstall retains them, Git/SSH settings, and keys.
The launcher gets an atomic `installed-tools.json` array of
`{id,name,app,visible}` records. Custom `tools.json` is untouched.

Ownership receipts hash installed directories and track exact plugin symlink
targets. Unrelated files or changed installations block replacement/removal
with an explanation. Known legacy plugin links from this repository can be
migrated into stable copies; foreign files and links are left alone.

Travel Router installation here stages its source and menu plugin. The window
shows separate system-file detection and setup/removal commands, with buttons
that open them in Terminal so `sudo` can prompt. Existing scripts perform all
privileged changes. After successfully running the system uninstall, explicitly
remove the staged files in the window (CLI: `forget-system travel-router`).
The manager never automatically changes networking or claims ownership of
previously installed system files.

## Manifest contract

Place `mac-utility.json` in `<utility>/` or `swiftbar/<utility>/`:

```json
{
  "schema": 1,
  "id": "example",
  "name": "Example",
  "version": "1.0.0",
  "description": "A short explanation.",
  "presentation": "app",
  "app": {"name": "Example.app", "bundle_id": "com.example.utility"},
  "install": {"command": ["scripts/install.sh", "{applications}"]},
  "uninstall": {"command": ["scripts/uninstall.sh"]},
  "privileged": false
}
```

`presentation` is `app`, `plugin`, or `launcher`. `app`, `plugin`, hooks, and
`dependencies` are optional. A plugin is `{"path":"swiftbar/example.5s.py"}`
(or a path at the utility's root). Paths stay inside the utility; plugins must
be executable and obey SwiftBar's filename convention. App installers receive
an isolated staging destination via `{applications}` and must put the named
bundle there, without changing user settings. Install hooks run with system
PATH and the selected HOME. Nonprivileged uninstall hooks are documented
metadata: the manager removes verified receipt-owned files itself rather than
trusting a script to delete user paths. Privileged hooks only become Terminal
commands; the manager never executes them automatically.

Dependencies use `{"name":"img2webp","paths":["/opt/homebrew/bin/img2webp",
"/usr/local/bin/img2webp"],"help":"Install with brew install webp"}`.
A missing executable is reported in the catalog and window.

## Additional catalog sources

The selected checkout or bundled catalog is the primary source. Add independent
utility repositories with **Add source…**, and remove extras with **Remove**.
Each utility row shows its source folder. Removing a source keeps installed
payloads, receipts, and preferences; updates need its source to be available.

```sh
scripts/install.sh source list
scripts/install.sh source add ~/workspace/example-utility
scripts/install.sh source remove ~/workspace/example-utility
```

Extra folders live in `~/.config/mac-utilities/sources.json` as a JSON array
of absolute directory paths. Each is scanned for a root `mac-utility.json`,
`*/mac-utility.json`, and `swiftbar/*/mac-utility.json`. Duplicate utility IDs
are errors naming both folders; no source wins silently. A missing folder is
shown as unavailable and can still be removed. The app bundles only its primary
catalog, never a user's extra repositories.

Privileged manifests can declare `"system_paths": ["/usr/local/sbin/example",
"/Library/LaunchDaemons/com.example.service.plist"]`. These absolute paths
are used only for detecting an existing system installation. The manager
never writes or deletes them. Without this field no system installation is
inferred. Privileged hooks remain Terminal commands requiring administrator
access.

## Isolated verification

```sh
/usr/bin/python3 -m unittest discover -s utilities-manager/tests -v
scripts/install.sh --home /tmp/example-home --no-system-effects install memory
MAC_UTILITIES_HOME=/tmp/example-home MAC_UTILITIES_DISABLE_SANDBOX=1 \
  utilities-manager/scripts/install.sh /tmp/example-apps
```

Temporary homes require `--no-system-effects`; SwiftBar defaults, application
opening, and Terminal execution are then suppressed. The native app accepts
`MAC_UTILITIES_HOME`, `MAC_UTILITIES_NO_SYSTEM_EFFECTS=1`, and
`MAC_UTILITIES_SOURCE` for isolated UI inspection. Tests use temporary directories
and mock app installers, never privileged hooks or host settings.
