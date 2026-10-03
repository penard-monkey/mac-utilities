# Public preparation

- **Date:** 2026-10-03
- **Place:** `.worktrees/publish-prep`
- **Branches:** `publish-prep`, `publish-removal`, `close-out-publish-prep`
- **PRs:** [manager #15](https://github.com/penard-monkey/mac-utilities/pull/15),
  [removal #16](https://github.com/penard-monkey/mac-utilities/pull/16), both open
- **Release:** none; repository visibility and remote history unchanged
- **Planning:** redacted `planning.tar.gz`; original private evidence in the
  place's cache and the user's local inbox

## Prepared work

- Split the personal router into a separate private repository with 30
  historical commits plus an independent-documentation commit. Its stable
  checkout retains its own installer, manifest, session, roadmap and instructions.
- Manager PR #15 adds root/nested external catalog sources, app/CLI source
  add/remove, source display, explicit ID collisions and manifest system paths.
  App packaging excludes external repositories and development state.
- Removal PR #16 deletes the personal payload/session/roadmap and untracks the
  local inbox while preserving its symlink. Public utilities replace private
  examples in root documentation. It requires #15 and private source registration
  before merging. A later manifest delete/modify conflict can be resolved by
  merging current main into the removal branch and keeping the directory deleted.
- Registered the stable private source on this Mac and repointed its live plugin
  link after verifying identical bytes and executable mode. A separate native
  manager preview shows the utility and its extra source. Visual shield checking
  remains assigned to the user; the agent never ran the plugin or sudo.
- Rehearsed a history filter in a disposable bare mirror with no remotes. The
  snapshot includes all fetched branch and PR refs: 68 to 33 unique commits,
  197 to 85 blobs, two planning archives inspected, zero expanded privacy hits.
- Delivered a private report and kit in the local inbox with reusable callbacks,
  all-history audit, maps, evidence and a helper that prints the exact deferred
  atomic force-with-lease command. No rewritten refs were pushed.

## Decisions

- Keep the personal utility independent and private while the manager catalogs it
  through local settings. Catalog ID conflicts remain explicit during migration.
- Base both feature PRs independently on main and leave them unmerged. The
  removal PR names the manager/source registration prerequisites.
- Preserve useful public source history and sanitize mixed historical files.
  Drop pre-subtree private changes rather than retain their routing narratives.
- Audit fetched PR refs and compressed archive members as well as patches and
  author/committer fields. A clean branch tip alone cannot establish privacy.
- Keep full evidence private and redact the committed planning archive so this
  session does not reintroduce the details it removes.
- Apply the close-out archive without its merge/fresh-start steps: the task
  explicitly requires open PRs and forbids agent merges.

## Dead ends and gotchas

- Git writes required sandbox escalation despite the declared shared git root.
  Some GitHub requests stalled with transient HTTP 503 responses; retries worked.
- The extracted single-branch clone retained its former fetch refspec; fixing it
  enabled its stable checkout to fast-forward to private main.
- The live plugin uses sudo internally for status and can self-heal. The agent
  stopped, reported the boundary, and continued independent work after the
  coordinator assigned visual verification to the user.
- Filtering private files alone retained old routing messages via generic
  ignore-file changes. Dropping all private-root commit changes and expanding the
  narrative audit fixed that before the final report.
- GitHub's host-controlled PR refs remain affected remotely even though they are
  clean in the scratch mirror. Hosted cleanup must be verified before the same
  repository becomes public. If unavailable, a clean replacement is a user choice.
- Native UI observation waited about 29 minutes for the app permission prompt.
  The preview was separate from the installed manager, with system effects disabled.

## Verification

- 46 tests pass: lifecycle 21, Tools 5, Git & SSH 12, GIF Stickers 8; native manager
  build, shell syntax, Python compilation and diff checks pass.
- GIF video fixtures fail under the restricted filesystem sandbox and pass
  outside it without source changes.
- Removal baseline's 15 lifecycle tests pass; combined cleaned export passes
  all 21 lifecycle tests. Native preview displays the external source correctly.
- Final full-history audit has no hits in patches, metadata, reachable blobs or
  archive members. Mirror integrity passes; 117 public utility file/ref
  comparisons are unchanged outside historical system detection.
- Remote feature/main tips checked unchanged by the rehearsal. Other agents'
  worktrees and host system installation were untouched.

## Follow-ups

- Merge prerequisites and active feature lanes, then take a fresh final mirror;
  today's rehearsal excludes their unmerged work and this archive.
- Verify hosted PR refs/cached views before publication, or choose an approved
  clean replacement repository. Keep all old checkouts and evidence private.
- Choose a license, add it separately, recreate all places against rewritten
  history, and only then consider a separate visibility change.
- User confirms the normal shield; rebuild the installed manager after both
  feature PRs merge. See ROADMAP.md and the private inbox report for the cut-over.
