# Roadmap

Parking lot for work we've decided to keep but not do now. Each item links
the session summary that spawned it (see docs/sessions/). Groomed during the
close-out ritual (global `/close-out` skill; this repo's settings in
`.claude/close-out.md`).

## Git & SSH

- **First-release limits.** Complex existing SSH host blocks open in an external
  editor instead of the form; the key inventory reads only `~/.ssh/*.pub`; keys held
  only by the agent show as a count; diagnostics run only when asked.
  ([session](docs/sessions/2026-10-03-utility-manager/summary.md))

## Mac Utilities manager

- **Drive install and remove through the window once.** The manager's window was
  inspected read-only; installs and removals were verified from the command line and
  in a temporary home. ([session](docs/sessions/2026-10-03-utility-manager/summary.md))

## GIF Stickers

- **Use the app by hand once.** It has never been launched interactively:
  install with `gif-stickers/scripts/install.sh`, open a real GIF, frame it,
  export. ([session](docs/sessions/2026-10-03-gif-stickers/summary.md))
- **Find out whether WhatsApp Desktop accepts the WebP as a sticker** by drag
  or paste. Today the documented route is a phone sticker pack.
  ([session](docs/sessions/2026-10-03-gif-stickers/summary.md))
- **Noisy GIFs fall to quality 1.** The fallback lowers quality before frame
  rate; on busy GIFs dropping frames first may look better. Worth comparing
  on real inputs. ([session](docs/sessions/2026-10-03-gif-stickers/summary.md))
