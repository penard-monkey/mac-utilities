# Git & SSH 1.1.0: include rules and profiles

- **Date:** 2026-10-03 to 2026-10-04
- **Worktree:** `.worktrees/git-includes` (removed at close-out)
- **PR:** #5
- **Planning files:** `planning.tar.gz` (task plan, findings, progress, brief)

## What shipped

`git-settings/Sources/GitSettingsCore/Includes.swift` and new screens:

- An inventory of `include.path` and `includeIf.<condition>.path` rules with
  their target files and the values each overrides.
- Editing referenced profile files with the same preview, apply and restore
  transaction as the main config; creating a profile by adding its rule.
- Adding, changing and removing rules without disturbing unrelated content.
  Removing a rule never deletes its file.
- An effective-identity check for a folder, reporting origin and scope from git.

## Decisions

- Only profiles referenced directly from `~/.gitconfig` and inside the home
  folder may be edited; symlinks, recursion and deep includes are refused.
- Profiles used by `hasconfig:remote.*.url:` rules may not contain remote URLs.

## Dead ends and gotchas

- Release fixtures hard-coded utility version 1.0.0; they now read each
  manifest's version.
- CRLF line endings hid rules from the scanner; a CRLF grapheme now counts as a
  newline.

## Verification

24 Git core tests; isolated UI checks of the profile transaction, a second
directory rule and the identity view. The macOS folder picker itself could not
be driven by automation; typed paths were verified.

## Follow-ups

See ROADMAP.md: try the folder picker by hand.
