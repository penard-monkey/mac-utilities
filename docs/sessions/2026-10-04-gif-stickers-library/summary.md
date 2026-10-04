# GIF Stickers 1.1.0: open by click, library, Send to my WhatsApp

- **Date:** 2026-10-03 to 2026-10-04
- **Worktree:** `.worktrees/gif-stickers-send` (removed at close-out)
- **PRs:** #6 (click-to-open), #7 (library and send)
- **Planning files:** `planning.tar.gz`, sanitized

## What shipped

- Clicking or pressing Return on the empty frame opens the file picker;
  "Choose another file…" appears once a file is loaded.
- A sticker library (default `~/Pictures/GIF Stickers`) with animated previews
  and Send, Copy, Reveal and Delete (to Trash), plus validated import of
  512x512 WebP stickers.
- "Send to my WhatsApp" through saywhat's signed `POST /send` on
  127.0.0.1:3220: `kind=sticker` plus the file, HMAC-SHA256 over
  `"<timestamp>." + raw body` keyed by saywhat's `send.secret`, sent only to the
  user's own chat, confirmed in the app first.

## Decisions

- **saywhat owns the WhatsApp session.** A direct-to-GOWA version was built and
  tested, then dropped at the user's choice so one program talks to WhatsApp.
- The key is read at send time and never copied, logged or stored.

## Dead ends and gotchas

- WhatsApp has no import for a ready-made animated WebP on desktop; sticker
  packs need a published app. Sending to one's own chat, then favouriting the
  sticker on the phone, is the practical route.
- The GitHub runner's older Swift rejects captured mutable variables in a
  concurrent closure that newer Swift accepts; copy them into constants first.

## Verification

Signed-send tests check the exact signature over the raw body and the multipart
shape against stub servers; library tests use temporary homes and a fake Trash.
No real message was sent.

## Follow-ups

See ROADMAP.md: the first real send, and a `kind=gif` path.
