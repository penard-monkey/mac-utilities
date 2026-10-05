# Roadmap

Parking lot for work we've decided to keep but not do now. Each item links
the session summary that spawned it (see docs/sessions/). Groomed during the
close-out ritual (global `/close-out` skill; this repo's settings in
`.claude/close-out.md`).

## Releases and updates

- **Confirm an update from the manager window.** v1.0.1 was the first real
  in-app update; confirm the Updates tab completes and relaunches.
  ([session](docs/sessions/2026-10-04-releases-and-public-cutover/summary.md))
- **Pick a stable signing identity.** Ad hoc signing may reset privacy
  permissions after each update (matters for QR Reader's Screen Recording).
  See `docs/releases/signing.md`.
  ([session](docs/sessions/2026-10-04-releases-and-public-cutover/summary.md))

## QR Reader

- **Click-test, then PR.** Built locally with ten test codes; never pushed. Add
  it to release verification once merged.

## Transcribe

- **Speaker labels.** Dropped for v1 to avoid torch; would need pyannote.
  ([session](docs/sessions/2026-10-03-transcribe/summary.md))

## Git & SSH

- **Try the folder picker by hand.** The effective-identity view was verified
  with typed paths only. ([session](docs/sessions/2026-10-04-git-includes/summary.md))
- **First-release limits.** Complex existing SSH host blocks open in an external
  editor instead of the form; the key inventory reads only `~/.ssh/*.pub`; keys held
  only by the agent show as a count; diagnostics run only when asked.
  ([session](docs/sessions/2026-10-03-utility-manager/summary.md))

## Mac Utilities manager

- **Drive install and remove through the window once.** The manager's window was
  inspected read-only; installs and removals were verified from the command line and
  in a temporary home. ([session](docs/sessions/2026-10-03-utility-manager/summary.md))

## GIF Stickers

- **Search the library by name.** Names are the filename stems as of 1.2.0.
  ([session](docs/sessions/2026-10-04-gif-stickers-add-rename/summary.md))
- **Check still images and the cut-out by hand.** The UI was not visually
  verified by the lane. ([session](docs/sessions/2026-10-04-gif-stickers-images/summary.md))
- **First real send.** Send a sticker from the library to yourself, then
  favourite it on the phone. ([session](docs/sessions/2026-10-04-gif-stickers-library/summary.md))
- **A `kind=gif` path.** saywhat also accepts looping MP4 "GIFs"; the app only
  sends animated WebP stickers today.
  ([session](docs/sessions/2026-10-04-gif-stickers-library/summary.md))
- **Noisy GIFs fall to quality 1.** The fallback lowers quality before frame
  rate; on busy GIFs dropping frames first may look better. Worth comparing
  on real inputs. ([session](docs/sessions/2026-10-03-gif-stickers/summary.md))
