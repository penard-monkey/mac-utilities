# GIF Stickers 1.2.0: Add to Library and rename

- **Date:** 2026-10-04
- **Worktree:** `.worktrees/gif-stickers-add-rename` (removed at close-out)
- **PR:** #10
- **Release:** v1.2.0
- **Planning files:** `planning.tar.gz`, sanitized

## What shipped

- **Add to Library** (Cmd-S) replaces Export Sticker. It writes the current
  preview straight into the library folder with no dialog, no Finder reveal and
  no clipboard copy. The name comes from the source file; collisions get " 2",
  " 3" and so on, and nothing is overwritten. The status line confirms it and
  the Library selects the new sticker.
- **Rename** from a button or the context menu, in a sheet where Return commits
  and Escape cancels. The grid sorts by name, and labels show the real filename
  stem, so 1.1.0's UUID-named stickers can be renamed too.

## Decisions

- The filename stem is the sticker's name; no separate metadata file. That
  keeps the library a plain folder other tools can read.
- Renames only move files already inside the library folder, reject symlinks,
  and refuse case-insensitive duplicates instead of overwriting.
- Search is left for later; names are the groundwork.

## Dead ends and gotchas

- macOS's default filesystem is case-insensitive, so "Foo" and "foo" collide.
  A capitalisation-only rename of the same file still works with
  `FileManager.moveItem`.

## Verification

29 GIF Stickers tests in Swift 5 mode, 13 of them for the library: default
naming, collisions, every rename rejection, case-insensitive collisions, and
staying inside the library folder. A v1.2.0 release build produced a signed
universal app with its icon.

## Follow-ups

See ROADMAP.md: search by name.
