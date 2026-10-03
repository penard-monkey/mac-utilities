#!/usr/bin/python3
# <xbar.title>Transcribe</xbar.title>
# <xbar.desc>Engine status and recent transcripts from the Transcribe utility.</xbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisappearPlugin>true</swiftbar.hideDisappearPlugin>
"""Menu bar item for Transcribe. Reads ~/.cache/mac-utilities/transcribe/history
(one JSON file per transcript, written by the app and the `transcribe` CLI) and
asks the engine's /health with a short timeout. Actions re-invoke this script
(`copy|reveal|open <id>`) so neither text nor paths with spaces travel through
SwiftBar parameters."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib import request

HOME = Path.home()
HISTORY = HOME / ".cache/mac-utilities/transcribe/history"
CONFIG = HOME / ".config/mac-utilities/transcribe.json"
CLI = HOME / ".local/bin/transcribe"
SHOW = 6


def port():
    try:
        return int(json.loads(CONFIG.read_text()).get("port") or 8765)
    except (OSError, ValueError, TypeError):
        return 8765


def health():
    try:
        with request.urlopen("http://127.0.0.1:%d/health" % port(), timeout=0.3) as r:
            return json.loads(r.read())
    except Exception:
        return None


def entries(n):
    out = []
    try:
        names = sorted((p for p in os.listdir(HISTORY) if p.endswith(".json")), reverse=True)[:n]
    except OSError:
        return out
    for name in names:
        try:
            out.append(json.loads((HISTORY / name).read_text()))
        except (OSError, ValueError):
            pass
    return out


def clean(s, n):
    s = " ".join((s or "").split()).replace("|", "¦")
    return s if len(s) <= n else s[: n - 1] + "…"


def ago(ts):
    d = max(0, time.time() - (ts or 0))
    if d < 60:
        return "now"
    if d < 3600:
        return "%dm" % (d // 60)
    if d < 86400:
        return "%dh" % (d // 3600)
    return "%dd" % (d // 86400)


def action(args):
    if len(args) < 2:
        return
    e = next((x for x in entries(500) if x.get("id") == args[1]), None)
    if not e:
        return
    if args[0] == "copy":
        subprocess.run(["/usr/bin/pbcopy"], input=(e.get("text") or "").encode(), check=False)
    elif args[0] == "reveal" and e.get("saved"):
        subprocess.run(["/usr/bin/open", "-R", e["saved"]], check=False)
    elif args[0] == "open" and e.get("source"):
        subprocess.run(["/usr/bin/open", e["source"]], check=False)


def main():
    if len(sys.argv) > 1:
        return action(sys.argv[1:])
    me = os.path.abspath(sys.argv[0])
    h = health()
    warm = bool(h and (h.get("models_loaded") or {}).get("whisper"))
    icon = "waveform" if warm else ("waveform.badge.exclamationmark" if not h else "waveform.path")
    print("| sfimage=%s sfsize=15" % icon)
    print("---")
    if not h:
        print("Engine not running | color=#d9534f")
        if CLI.exists():
            print("Start engine | bash=%s param1=server param2=start terminal=false refresh=true" % CLI)
    else:
        model = (h.get("model") or "").split("/")[-1]
        print("Engine %s · %s | size=12" % ("ready" if warm else "loading", model))
    print("Open Transcribe… | bash=/usr/bin/open param1=-a param2=Transcribe terminal=false")
    print("---")
    items = entries(SHOW)
    if not items:
        print("No transcripts yet | size=12")
    for e in items:
        name = Path(e.get("source", "?")).name
        print("%s  %s | size=13" % (clean(name, 34), ago(e.get("created"))))
        print("%s | size=11 trim=false" % clean(e.get("text") or "(no speech found)", 70))
        print("--Copy text | bash=%s param1=copy param2=%s terminal=false" % (me, e.get("id")))
        saved = e.get("saved")
        if saved and os.path.exists(saved):
            print("--Show transcript file | bash=%s param1=reveal param2=%s terminal=false" % (me, e.get("id")))
        src = e.get("source")
        if src and os.path.exists(src):
            print("--Open original | bash=%s param1=open param2=%s terminal=false" % (me, e.get("id")))


if __name__ == "__main__":
    main()
