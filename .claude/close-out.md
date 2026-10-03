# close-out overrides — mac-utilities

Project config for the global `close-out` skill. Only the deltas from that
skill's defaults live here.

| Setting | This repo |
| --- | --- |
| archive dir | `docs/sessions/<YYYY-MM-DD>-<slug>/` (default). ALSO add a row at the top of the table in `docs/sessions/index.md` |
| scratch dir | `~/.cache/worktrees/mac-utilities/<worktree-name>/` |
| planning files | `task_plan.md`, `findings.md`, `progress.md` (gitignored, repo root of each worktree) |
| roadmap | `ROADMAP.md` (default), one section per utility |
| merge | squash (default) |
| branch naming | one worktree per utility, branch named after the utility; close-out branch `close-out-<slug>` |

## Gates

There is no repo-wide build. Run the gates of each utility the session
touched, from its folder:

```sh
swift test --package-path gif-stickers          # gif-stickers
bash -n scripts/*.sh */scripts/*.sh             # every shell script
/usr/bin/python3 -m py_compile swiftbar/*/*.py  # Python plugins
```

## Notes

- A lane worked by another agent leaves its brief at `.planning/brief.md`;
  archive it in the tarball with the planning files. `.planning/` is excluded
  through `.git/info/exclude`, never committed.
- `_tmp/` is the user's iCloud inbox symlink; leave its contents alone.
