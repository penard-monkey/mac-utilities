#!/usr/bin/python3
# <xbar.title>QR Reader</xbar.title>
# <xbar.version>1.0</xbar.version>
# <xbar.author>David Pena</xbar.author>
# <xbar.desc>Scan a QR code off the screen and approve what it opens before it opens.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
"""
QR Reader menu bar item.

A trigger and a log, nothing more: all decoding, approving and opening happens
in QR Reader.app, which owns the Screen Recording permission. This script only
reads state files, so it stays far under the 200 ms budget and never blocks.

  ~/.cache/mac-utilities/qr-reader-history.jsonl   recent scans (already redacted)
  ~/.cache/mac-utilities/qr-reader-state.json      last known permission state
"""
import json
import os
import sys
import time

BUNDLE_ID = "com.macutilities.qr-reader"
APP_PATH = os.path.expanduser("~/Applications/QR Reader.app")
CACHE = os.path.expanduser("~/.cache/mac-utilities")
HISTORY = os.path.join(CACHE, "qr-reader-history.jsonl")
STATE = os.path.join(CACHE, "qr-reader-state.json")
RECENTS = 5

# Launch by bundle id so the app is found wherever it was installed, falling
# back to the documented location. `open` is in /usr/bin, which is always on the
# minimal PATH SwiftBar gives a plugin.
LAUNCH = (
    '/usr/bin/open -g -b {bundle} --args {args}'
    ' || /usr/bin/open -g -a "{app}" --args {args}'
).format(bundle=BUNDLE_ID, app=APP_PATH, args="{args}")


def action(title, args, extra=""):
    command = LAUNCH.format(args=args)
    return '{title} | bash="/bin/bash" param1="-c" param2="{command}" terminal=false{extra}'.format(
        title=title, command=command.replace('"', "\\\""), extra=(" " + extra if extra else ""))


def read_state():
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except Exception:
        return {}


def read_recents():
    try:
        with open(HISTORY) as handle:
            lines = handle.read().strip().split("\n")
    except Exception:
        return []
    entries = []
    for line in lines[-RECENTS:]:
        try:
            entries.append(json.loads(line))
        except ValueError:
            continue
    entries.reverse()
    return entries


def when(stamp):
    """ISO 8601 to a short relative age, without pulling in any dependency."""
    try:
        parsed = time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S")
    except (ValueError, TypeError):
        return ""
    seconds = max(0, int(time.time() - time.mktime(parsed) + time.timezone))
    for limit, divisor, unit in ((3600, 60, "m"), (86400, 3600, "h")):
        if seconds < limit:
            return "%d%s ago" % (max(1, seconds // divisor), unit)
    return "%dd ago" % (seconds // 86400)


DECISION_MARK = {"opened": "↗", "copied": "⧉", "cancelled": "✕", "refused": "⊘"}


def main():
    state = read_state()
    installed = os.path.isdir(APP_PATH) or state.get("bundle_path")

    print(" | sfimage=qrcode.viewfinder")
    print("---")

    if not installed:
        print("QR Reader.app is not installed | sfimage=exclamationmark.triangle sfcolor=orange")
        print("Install it from Mac Utilities | sfimage=square.and.arrow.down")
        return

    print(action("Scan Region…", "--scan=region", "shortcut=CMD+SHIFT+9 sfimage=viewfinder"))
    print(action("Decode Clipboard", "--scan=clipboard", "sfimage=doc.on.clipboard"))
    print(action("Decode Image File…", "--scan=file", "sfimage=photo"))

    if state.get("screen_recording") is False:
        print("---")
        print("Screen Recording is off | sfimage=lock.slash sfcolor=orange")
        print("Region scans will not work until it is granted. | size=11 color=#888888")
        print("Open Privacy Settings… | bash=\"/usr/bin/open\" "
              "param1=\"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture\" "
              "terminal=false sfimage=gear")

    recents = read_recents()
    print("---")
    if not recents:
        print("No scans yet | color=#888888")
    else:
        print("Recent | size=11 color=#888888")
        for entry in recents:
            mark = DECISION_MARK.get(entry.get("decision", ""), "·")
            payload = (entry.get("payload") or "").replace("|", "¦").replace("\n", " ")
            if len(payload) > 54:
                payload = payload[:54] + "…"
            age = when(entry.get("at", ""))
            print("%s %s | font=Menlo size=11 tooltip=\"%s · %s · %s\"" % (
                mark, payload, entry.get("type", "?"), entry.get("decision", "?"), age))

    print("---")
    print("History | size=11 color=#888888")
    print("Open History File | bash=\"/usr/bin/open\" param1=\"-R\" param2=\"%s\" terminal=false" % HISTORY)
    print("Clear History | bash=\"/bin/rm\" param1=\"-f\" param2=\"%s\" terminal=false refresh=true" % HISTORY)


if __name__ == "__main__":
    sys.exit(main())
