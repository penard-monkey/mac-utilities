# QR Reader: scan a QR code off the screen, approve before anything opens

- **Date:** 2026-09-15 to 2026-10-07
- **Worktree:** `.worktrees/qr-reader` (removed at close-out)
- **PR:** #16
- **Release:** v1.5.0 (QR Reader 1.0.0)
- **Planning files:** `planning.tar.gz`, sanitized

## What shipped

`qr-reader/`: a SwiftUI app plus a SwiftBar trigger. Scan a dragged screen
region, the clipboard image or an image file; decode with Vision; classify the
payload and its risks (lookalike and punycode hosts, credentials before the
host, blocked schemes, masked one-time-password secrets, Wi-Fi shown but never
joined); then an explicit approval window where only the Open button opens
anything. Redacted history, capped at 100 entries.

## Decisions

- **The approval step is the product.** Prompt every time; no allowlist or
  "always trust". `otpauth:`, `javascript:`, `data:` and `file:` never open;
  unknown schemes are copy-only behind a second confirmation.
- **What was approved is what opens**: the URL built at classification time,
  never a re-parse of the displayed text.
- **Captured images live in a 0700 temporary folder deleted on every path.**
- **Vision, not CIDetector**, because only Vision tells a binary payload from
  no code.
- **Ad-hoc signing accepted for now**, with the cost written down.

## Dead ends and gotchas

- **A rebuild alone revokes Screen Recording** for an ad-hoc-signed app, even
  with the same bundle id and path. Measured on a real Mac; every update costs
  one re-grant until a stable signing identity exists. `screencapture` reports a
  missing or stale grant only as "could not create image from display"; the app
  now turns that into its permission window.
- Rebuilding a dev app while the user held a grant on it revoked the grant and
  produced confusing popups. Finish diagnostics before asking for a grant.
- `payloadData` is available from macOS 14, not 15; a wrong availability guard
  would have made binary codes read as "no code found" on macOS 14.
- The approval window's keyboard handling needed care: Cancel owns Return, the
  panel owns Escape, and focus starts on the deny button so a stray Space
  cannot press Open.

## Verification

31 tests. By hand on a dev copy: the approval window waited four minutes
untouched, then recorded "cancelled" and opened nothing; clipboard input end to
end; the Screen Recording prompt and grant; risk flag and redaction in history.
The release build produced a signed universal app with its icon.

**Not verified:** a region scan returned "No code found" once with the cause
unknown (blanked capture or decode miss); image-file input; the OTP and
`javascript:` refusals by hand; the SwiftBar hotkey. The user chose to test
these live after release.

## Follow-ups

See ROADMAP.md under QR Reader.
