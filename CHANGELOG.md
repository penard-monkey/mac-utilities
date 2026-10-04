# Changelog

## [1.0.1]

- Transcribe: updating from the manager no longer fails with "Bootstrap
  failed: 5: Input/output error". The engine installer now waits for launchd
  to release the old job before loading the new one, and retries the load
  briefly, so an update can no longer leave the engine stopped.

## [1.0.0]

- Install Mac Utilities with a checksum-verified `curl | bash` installer, with
  optional utility selection and pinned release versions.
- Download universal macOS 14+ app bundles for Mac Utilities, Git & SSH,
  GIF Stickers and Transcribe; install plugins and engine sources from a
  standalone release catalog.
- Check and install releases from the manager's Updates tab, including manager
  replacement and relaunch. External utility sources keep updating from folders.
- Migrate healthy receipt-owned checkout installs in place, keeping preferences,
  caches, Git configuration, SSH keys and menu visibility.
- Build releases on approved `v*` tags; prove artifacts without publishing via
  workflow dispatch. Run every utility test suite on pull requests.

These builds use ad hoc signing. Quarantine removal requires explicit opt-in;
privacy grants may need renewal. A persistent signing identity remains a user
choice; see `docs/releases/signing.md`.
