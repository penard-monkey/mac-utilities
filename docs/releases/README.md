# Releases and updates

The release format, verified installer and manager Updates tab are ready for a
first release after the public cut-over. No release/tag has been created by this
work. Keep current live installs until that first release is approved. Distribution
uses the MIT `LICENSE` added by the public cut-over; this work does not create it.

`VERSION` is the repository release version. `install.sh` carries the matching
`SCRIPT_VERSION` with a `v` prefix. Per-utility manifests retain their own versions;
app bundles use those versions and the manager uses the repository version.
`REPO` in root `install.sh` is the sole repository-slug setting: the builder writes
it into release metadata and hooks. Change that variable before building for a
new public repository.

## Build and proof

```sh
cache="$HOME/.cache/worktrees/mac-utilities/release-path"
/usr/bin/python3 scripts/release/version_gate.py  # add --tag v1.0.0 after the approved LICENSE exists
bash scripts/release/test.sh
/usr/bin/python3 scripts/release/build.py --output "$cache/dist" --scratch "$cache/build"
MAC_UTILITIES_INSTALL=memory,git-settings,gif-stickers,transcribe \
  bash install.sh --artifacts "$cache/dist" --home "$cache/proof-home" --no-system-effects
bash install.sh --artifacts "$cache/dist" --home "$cache/proof-home" --no-system-effects update --all
```

Use an empty output directory. If the local SwiftPM sandbox is unavailable,
`--disable-sandbox` affects the builder only; `MAC_UTILITIES_DISABLE_SANDBOX=1`
affects the test runner. Build products go to the supplied scratch directory.
The proof home must be isolated; `--no-system-effects` suppresses SwiftBar,
Terminal and app-opening effects. It never launches apps or invokes their normal
checkout installers.

The builder packages universal arm64/x86_64 bundles for Mac Utilities, Git & SSH,
GIF Stickers and Transcribe, checks every architecture and signature, and writes a catalog
archive of nonprivileged utility payloads. The private/system Travel Router is
excluded. Transcribe includes its engine sources, pinned requirements and launchd template;
its release hook installs the engine only when system effects are enabled. The
local MLX engine requires Apple Silicon even though the app bundle is universal.
New native apps (including QR Reader when it lands) require review of their
resources and engine payloads before adding them to release verification.

Artifacts include each app zip, `mac-utilities-catalog.zip`, `release.json`,
`release-runtime.py`, per-asset `.sha256`, combined `checksums.txt`, and notes.
The catalog keeps plugin scripts/engine sources and replaces release app install
hooks with checksum-verified prebuilt downloads. Original checkout manifests and
build scripts keep their developer behavior. Apps do not need Swift to install.

`ci.yml` runs every current Swift and Python suite plus shell/compile checks.
`release.yml` runs those gates, builds and installs actual artifacts in an
isolated home, and uploads them. `workflow_dispatch` only proves/uploads artifacts;
it cannot publish. Only an approved existing `v*` tag enables the publish job,
and the version gate (including matching changelog and approved LICENSE) must pass first. The publish command uses `--verify-tag` so
it cannot silently create a tag.

## Installer interface

Once a public release exists:

```sh
curl -fsSL https://raw.githubusercontent.com/penard-monkey/mac-utilities/main/install.sh | bash
curl -fsSL https://raw.githubusercontent.com/penard-monkey/mac-utilities/v1.0.0/install.sh | \
  MAC_UTILITIES_INSTALL_VERSION=v1.0.0 MAC_UTILITIES_INSTALL=gif-stickers,memory bash
bash install.sh update --all
bash install.sh update memory
bash install.sh update manager
bash install.sh uninstall memory
bash install.sh uninstall manager
```

Default install adds the manager and Tools. With a controlling terminal, it offers
comma-separated optional utility IDs; unattended installs can set
`MAC_UTILITIES_INSTALL`. Pinning wins; otherwise initial installs prefer the
script's own available release and fall back to `releases/latest`. Update commands
resolve latest unless explicitly pinned. Latest is an HTTP redirect, without an
API token or jq. Requires macOS 14+ and system Python 3; SwiftBar and each tool's
runtime dependencies remain separate prerequisites.

Manager and utility apps live in `~/Applications`; receipt-owned payloads live in
`~/Library/Application Support/mac-utilities/payloads`; local proof assets are
cached under that support folder's `releases/<tag>/Assets`. The manager includes
an independent catalog. App hooks verify cached artifacts or download from the
release recorded in their catalog. Original artifacts/checkouts can be deleted.
SwiftBar links always use `~/.swiftbar`.

The installer requires a valid checksum for the bootstrap runtime before executing
it, and for every archive/metadata file before use. Checksums protect integrity,
not authorship: their source is the same release. Pin the installer URL and tag
for reproducibility. ZIP extraction rejects traversal, duplicate paths, links and
special files. Receipt checks refuse modified or unowned apps/plugins/payloads.
Installation is transactional per app/utility, not across the entire collection;
a later utility failure can leave earlier successful installs in place.

Quarantine removal is opt-in with `--strip-quarantine`; default installation never
strips it or re-signs downloaded apps. Ad hoc signing does not provide a stable
privacy identity. See [signing recommendation](signing.md) before deciding how to
ship permission-sensitive applications.

## Migration from a checkout install

Keep the current installs and receipts. Run the release installer into the same
home and `~/Applications`, then `update --all`. The existing directory digests
prove ownership and allow replacing the manager/apps/payloads in place. Hidden
menu settings remain hidden. No uninstall is needed for healthy receipt-owned
installs. Settings in `~/.config/mac-utilities`, caches, `~/.ssh`, `.gitconfig`, and
custom Tools entries are retained. Automated tests exercise a real checkout
Memory receipt transitioning to a release receipt, app updates, hidden menus,
manager replacement, refusal of foreign/changed installations and settings/keys
preservation inside temporary homes.

Unowned apps, changed receipt-owned directories, foreign plugin links and older
installs without receipts cannot be silently adopted. Move those aside after
reviewing them, then reinstall; do not discard keys/settings or blindly delete
payloads. Existing legacy worktree plugin links can first be migrated using
`scripts/install.sh --repo /path/to/checkout install <id>` in developer mode,
which verifies the shared git repository. The release catalog has no provenance
that would safely claim arbitrary checkout links. Privacy grants may need renewal
after rebuilt apps replace old ad hoc builds; preserving paths alone is not a
permission-continuity guarantee. External/private sources in `sources.json` are retained. Their utility updates
continue from those folders; a release marker is never written onto an external
receipt. Direct external updates and uninstall use the installed runtime and do
not require the public feed. `update --all` updates the manager, all available
installed release utilities and configured external utilities, but never installs
an unselected tool. Missing installed sources remain visible in the manager.

The native Updates view and CLI share the same release backend. Latest checks use
`releases/latest` redirects and verify the catalog before showing available
versions. Updates select an immutable snapshot under the support store's
`releases/<tag>/Catalog`, replace healthy receipt-owned files and switch the primary
source to that snapshot. Existing settings files keep their other fields. The
manager relaunches itself after replacement; other apps need a manual restart.
The quarantine opt-in is not saved between sessions.

For isolated fake-feed testing, `MAC_UTILITIES_RELEASE_BASE_URL` overrides the
repository base URL for the backend. HTTPS is required except HTTP loopback;
no token or GitHub API is used. Tests serve real checksummed fixtures through an
HTTP server and exercise the latest redirect, checks, manager replacement,
external folder updates and corruption/refusal paths.

## Verification for this branch

On 2026-10-03 the shared test runner passed 77 tests: release fixtures (12),
manager lifecycle (23), Tools (5), GIF Stickers (8), Git & SSH (12), Transcribe
app core (8), native manager updates (1), and Transcribe engine (8). The native
test checks the latest redirect, updates the manager, updates Memory and preserves
its hidden-menu setting through the same asynchronous process path used by the UI.

The artifact builder produced all four universal app archives and the catalog.
The workflow's install/update commands passed against those artifacts in an
isolated home; all four installed app signatures verified, engine sources and
launchd templates were present, and no launchd jobs were created. No GitHub tag
or release, certificate, or live install was changed. This is an equivalent
local run of the workflow steps; a hosted dispatch has not been run.

The native Updates tab and Check for updates request were observed in a separate
proof app, and the fake feed logged the redirect and verified catalog requests.
The UI automation connection then failed; manager/utility update completion is
covered by the native integration test. Relaunch and real TCC grant continuity
remain manual checks after a signing identity is chosen.
