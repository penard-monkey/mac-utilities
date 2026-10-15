# Worktrees rules for agents

- Date: 2026-10-15
- Place: `agent-instructions`
- Branch: `agent-instructions` (squash-merged)
- PR: [#22](https://github.com/penard-monkey/mac-utilities/pull/22), `chore: apply the worktrees rules`
- Release: none (documentation and agent tooling only)
- Planning files: none

## What shipped

`worktrees rules apply` generated the whole change. No utility code changed.

- `AGENTS.md`: a managed "Working with worktrees" block (between
  `<!-- worktrees:rules v1 … -->` markers). It covers places, lanes and briefs,
  which MCP tool to use for what, finishing a branch and what never to touch,
  and it applies to every agent that reads `AGENTS.md`, including sessions
  worktrees did not start.
- `.claude/skills/close-out/SKILL.md`: a repo-local copy of the close-out
  ritual, marked `worktrees:managed v1`. It reads `.claude/close-out.md` for
  this repo's overrides, as the global skill already did.
- `.agents/skills/close-out` → `../../.claude/skills/close-out`: a symlink so
  that agents reading `.agents/skills` (Codex, pi) find the same skill.

## Decisions

- **Keep the generated text as is.** Both files carry a `sha=` marker. Editing
  inside a managed block stops worktrees from updating it, so repo-specific
  rules go outside the block or into `.claude/close-out.md`.
- **The `worktrees` skill wins over the block.** The block itself says so. That
  keeps one source of truth when the tool moves faster than this repo.

## Dead ends / gotchas

- **Two conflicting planning locations.** The new block says plans live in
  `.planning/` inside each place. The older "Planning docs" section of
  `AGENTS.md` and `.claude/close-out.md` both say `task_plan.md`,
  `findings.md` and `progress.md` sit at the worktree root. The SessionStart
  hook also points to `.planning/<place>/`. Left as is; see Follow-ups.
- **"Upstream gone" is normal after a merge.** GitHub deletes the head branch
  when it merges, so `git status` reports `[gone]`. HEAD (`309c5d6`) and
  `origin/main` (`bbac9f6`) are the same tree, with one commit on each side
  because of the squash.
- **Stale MCP server.** This session's worktrees MCP server was v0.41.0 while
  v0.42.0 was installed. Reload it to pick up the newer tool definitions.

## Verification

- `gh pr list --head agent-instructions --state all`: #22 MERGED at
  2026-10-15T21:39:56Z.
- `git diff HEAD origin/main` over the three files was empty before parking.
- No gates ran: no utility code, shell scripts or Python changed.

## Follow-ups

- Settle the planning location: either `.planning/<place>/` everywhere
  (update the "Planning docs" section and `.claude/close-out.md`) or the root
  files (tell worktrees). Recorded in `ROADMAP.md` under "Repository
  conventions".
