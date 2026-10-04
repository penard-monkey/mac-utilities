# Releases, the curl installer, in-app updates, and the public cut-over

- **Date:** 2026-10-03 to 2026-10-04
- **Worktrees:** `.worktrees/release-path`, `.worktrees/publish-prep` (removed)
- **PRs:** #19 (archive repository) for releases; #1-#3 in this repository
- **Releases:** v1.0.0, v1.0.1
- **Planning files:** release-path's notes in `planning.tar.gz`, sanitized.
  publish-prep has its own archive (2026-10-03-publish-prep).

## What shipped

- `VERSION`, a version gate, `CHANGELOG.md`, universal app and catalog
  packaging, `checksums.txt`, a tag-triggered `release.yml` and a PR `ci.yml`.
- `install.sh`: a checksum-verifying `curl | bash` installer with version
  pinning and opt-in quarantine removal, modelled on worktrees.
- An Updates tab in the manager and `install.sh update`, sharing one backend;
  checkout installs migrate in place.
- The public cut-over: the original repository became a private archive and a
  fresh public repository received an audited clean history, an MIT license and
  Actions. All local tools were uninstalled and reinstalled with the public
  installer.
- v1.0.1 fixed the Transcribe engine reload race found on the first in-app
  update.

## Decisions

- A fresh public repository instead of rewriting the old one: GitHub keeps every
  pull request's refs and diffs, which a force-push cannot remove.
- Ad hoc signing for now; a persistent identity is documented as the user's
  choice in `docs/releases/signing.md`.
- Live installs change only through releases and the update path.

## Dead ends and gotchas

- **macOS `/bin/bash` 3.2** rejects an empty array under `set -u`. It broke CI
  twice; now a rule in AGENTS.md.
- **GitHub authors test-merge refs and web merges with the account's primary
  email** unless email privacy is on, and even then a squash of a commit with a
  co-author trailer used it once. Always merge with
  `gh pr merge --author-email <no-reply>`.
- The cut-over kit's rebuild restored ignored files before replaying a lane's
  commits, so a lane whose `.gitignore` arrived in its own commit failed; the
  remaining places were rebuilt with the kit's functions in the right order.
- **launchd `bootout` returns before the label is released.** Bootstrapping too
  early fails with error 5 and leaves the job unloaded. Wait for
  `launchctl print` to fail, then retry the bootstrap.

## Verification

Hosted CI and release runs passed; v1.0.0 installed from GitHub into an isolated
home, then for real; `update --all` ran against GitHub; full privacy audits of
the public mirror, including pull-request refs, found no hits.

## Follow-ups

See ROADMAP.md: a stable signing identity, and confirming an in-app update.
