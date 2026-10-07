# qr-reader — scan a QR code, see what it does, then decide

Drag a box around a QR code on screen. QR Reader decodes it, tells you exactly
what it is about to do, and does nothing until you click. The approval step is
the point of this utility; decoding is the easy part.

```
menu bar (qr.1h.py) ──trigger──> QR Reader.app ──> screencapture -i -s
                                      │
                                      ├─ Vision decode (QR, Aztec, DataMatrix, PDF417, Code128…)
                                      ├─ classify + local risk checks
                                      ├─ approval window ── Cancel / Copy / Open
                                      └─ redacted history ──> menu bar recents
```

## What it shows you before anything happens

The approval window shows the decoded payload **in full** — wrapped and
scrollable, never truncated, because a hidden tail is where a nasty URL keeps
its surprise. The host is bold and the rest dimmed, so your eye lands on where
this actually goes rather than on a familiar-looking prefix.

Underneath it lists what it found wrong, if anything. All of these checks are
local; nothing touches the network unless you press **Resolve redirects…**:

| Flag | Why it matters |
| --- | --- |
| Credentials before the host | `https://apple.com@evil.tld/` goes to **evil.tld**. The part you recognise is just a username. |
| Punycode host | `xn--pple-43d.com` is shown decoded, so a Cyrillic а pretending to be an `a` is visible. |
| Rewritten when opened | macOS normalises as it parses. When the string that gets opened differs from the string in the code, you are told, with both forms. |
| Mixed alphabets | One label mixing Latin with Cyrillic or Greek. |
| Hidden characters | Invisible or direction-changing characters that make text read as something else. |
| Encoded null byte | `%00`, which some software treats as the end of the string. |
| Shortened link | A known shortener hides the destination. Resolve redirects to see it. |
| Not encrypted / Numeric address / Unusual port | `http://`, a raw IP, a port that isn't 80/443. |
| Authenticator seed | An `otpauth:` code. Opening it would silently add an account to an authenticator app. |

## What it refuses

- **`otpauth:`** — never opened. The secret is masked on screen and redacted in
  history. Copy if you really want it.
- **`javascript:`, `data:`, `file:`, `vbscript:`, `about:`** — never opened.
- **Any other scheme** (`zoommtg:`, `slack:`, anything) — hands the payload to
  whichever app claims it, so it takes a second, separate confirmation.
- **Wi-Fi codes** are shown, not joined. The password is hidden behind *Reveal*.

Cancel is the default button, Escape cancels, and closing the window is a deny.
Nothing is on a timer: no timeout ever approves anything. The URL that opens is
the one built when the code was classified, never a re-parse of the text on
screen — so what you approved is what happens.

## Three ways in

| Source | Permission needed |
| --- | --- |
| **Scan Region…** (⌘⇧9 from the menu bar) | Screen Recording |
| **Decode Clipboard** — take a screenshot with ⌃⇧⌘4, then this | none |
| An image file — `--file=<path>`, or open one with QR Reader | none |

### Screen Recording

Region scanning needs it, and **macOS fails silently without it** — the
selection just never produces a code. So QR Reader checks first
(`CGPreflightScreenCaptureAccess`), raises the system prompt itself
(`CGRequestScreenCaptureAccess`), and offers both a link to
Privacy & Security › Screen & System Audio Recording and the clipboard route,
which needs no permission at all. The menu bar item shows the last known state.

**Expect to re-grant it after an update.** The app is signed ad hoc, so every
build is a new signing identity, and macOS ties a privacy grant to that identity.
This was measured, not assumed: rebuilding the app with nothing else changed —
same bundle id, same path — revoked a working grant.
Updating QR Reader can therefore cost you one click in System Settings again.
That is a deliberate trade — the alternative is a paid or self-managed signing
certificate — and it is written down in `docs/releases/signing.md`.

It is bounded on purpose: nothing else about the app depends on that grant.
**Decode Clipboard and image files keep working with no permission at all**, and
the menu bar item tells you when the grant is missing instead of silently doing
nothing.

## History

`~/.cache/mac-utilities/qr-reader-history.jsonl`, mode 600, newest 100 entries,
one JSON object per line. Secrets are stripped **before** anything is written:
Wi-Fi passwords, `otpauth` secrets, URL userinfo, and query parameters named
like credentials (`token`, `secret`, `key`, `code`, `password`, …). The last
five appear in the menu with a mark for what you chose — `↗` opened, `⧉`
copied, `✕` cancelled, `⊘` refused.

Settings live in `~/.config/mac-utilities/qr-reader.json` and are only written
when you change one:

| Key | Default | Meaning |
| --- | --- | --- |
| `historyEnabled` | `true` | write scans to the history file at all |
| `historyLimit` | `100` | entries kept |
| `offerRedirectResolution` | `true` | show the Resolve redirects… button |

## Install

```sh
scripts/install.sh install qr-reader      # from the repository root, via the manager
```

That builds the app, places it in `~/Applications`, and links the menu bar
plugin. `qr-reader/scripts/install.sh [destination]` builds the bundle on its
own if you want it without the manager. Removing it leaves history and settings
in place.

## Working on it

```sh
swift test --package-path qr-reader          # the classifier and risk table
qr-reader/swiftbar/qr.1h.py                  # what SwiftBar sees
open -g "swiftbar://refreshplugin?name=qr"   # re-render the menu item now
open -g -b com.macutilities.qr-reader --args --scan=clipboard
```

`QRReaderCore` holds everything worth testing — payload parsing, the risk
checks, punycode decoding, redaction, history — with no AppKit in it. The app
target is capture, windows and opening.

### Notes from building it

- **Vision, not CIDetector.** On a binary payload CIDetector returns a nil
  string, indistinguishable from "no code here"; Vision hands back the bytes.
  Vision's first call in a process costs ~1.7 s of model loading and ~20 ms
  after that, so it is warmed at launch while you are still dragging.
- **Vision does not return codes in reading order.** They are sorted by
  bounding box before the picker shows them.
- **A colon does not make a scheme.** "Notes: 10:30 standup" parses as a URL
  with scheme `Notes`, so an unrecognised scheme has to look like a URL (no
  whitespace) before it is treated as one. Known-dangerous schemes skip that
  test, so `javascript: alert(1)` is still caught.
