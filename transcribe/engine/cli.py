#!/usr/bin/python3
"""transcribe — transcribe audio or video files with the local Transcribe engine.

  transcribe FILE...                 print the text and save <stem>.txt next to each file
  transcribe FILE --no-save          print only
  transcribe FILE --format json|md   print JSON (segments) or one paragraph per segment
  transcribe FILE --language es      skip language detection
  transcribe recent [-n N] [--json]  recent transcripts (what the menu bar shows)
  transcribe status [--json]         engine health
  transcribe server start|stop|restart|logs

System python, stdlib only. The engine runs under launchd as
com.mac-utilities.transcribe on 127.0.0.1:8765.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path
from urllib import error as urlerror
from urllib import request as urlrequest

LABEL = "com.mac-utilities.transcribe"
CONFIG = Path.home() / ".config/mac-utilities/transcribe.json"
HOME = Path(os.environ.get("TRANSCRIBE_HOME", Path.home() / ".cache/mac-utilities/transcribe"))
HISTORY = HOME / "history"
JOBS = HOME / "jobs"
LOG = HOME / "engine.log"
HISTORY_KEEP = 200


def settings():
    try:
        s = json.loads(CONFIG.read_text())
        return s if isinstance(s, dict) else {}
    except (OSError, ValueError):
        return {}


def base_url():
    port = os.environ.get("TRANSCRIBE_PORT") or settings().get("port") or 8765
    return "http://127.0.0.1:%s" % port


def http(method, path, body=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    req = urlrequest.Request(base_url() + path, data=data, method=method,
                             headers={"Content-Type": "application/json"})
    try:
        with urlrequest.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"null")
    except urlerror.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        except ValueError:
            return e.code, None


def health():
    try:
        code, v = http("GET", "/health", timeout=2)
        return v if code == 200 else None
    except (OSError, ValueError):
        return None


def save_path(source):
    """<stem>.txt next to the source; never overwrite an existing file."""
    d, stem = source.parent, source.stem
    cand = d / ("%s.txt" % stem)
    n = 1
    while cand.exists():
        cand = d / ("%s transcript%s.txt" % (stem, "" if n == 1 else " %d" % n))
        n += 1
    return cand


def record(source, saved, result):
    HISTORY.mkdir(parents=True, exist_ok=True)
    rid = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    entry = {"id": rid, "source": str(source), "saved": str(saved) if saved else None,
             "text": result.get("text", ""), "language": result.get("language"),
             "duration": result.get("duration"), "created": time.time(), "via": "cli"}
    tmp = HISTORY / (rid + ".json.tmp")
    tmp.write_text(json.dumps(entry, ensure_ascii=False))
    os.replace(tmp, HISTORY / (rid + ".json"))
    old = sorted(p for p in HISTORY.glob("*.json"))
    for p in old[:-HISTORY_KEEP]:
        try:
            p.unlink()
        except OSError:
            pass


def transcribe_one(path, language=None, timeout=1800):
    body = {"file_path": str(path), "mode": "basic", "output_dir": str(JOBS)}
    if language:
        body["language"] = language
    code, v = http("POST", "/jobs", body)
    if code != 202:
        raise RuntimeError((v or {}).get("detail") or "engine rejected the job (%s)" % code)
    job_id, wait, started = v["job_id"], 0.2, time.time()
    while True:
        code, v = http("GET", "/jobs/" + job_id)
        if code == 404:
            raise RuntimeError("job vanished; did the engine restart?")
        st = (v or {}).get("status")
        if st == "done":
            return v["result"]
        if st == "error":
            raise RuntimeError(v.get("error") or "transcription failed")
        if time.time() - started > timeout:
            raise RuntimeError("timed out after %ds" % timeout)
        time.sleep(wait)
        wait = min(wait * 1.5, 2.0)


def as_text(result, fmt):
    if fmt == "json":
        return json.dumps(result, ensure_ascii=False, indent=2)
    if fmt == "md":
        return "\n\n".join(s["text"] for s in result.get("segments", []) if s.get("text"))
    return result.get("text", "")


def file_text(result):
    """What gets saved: one line per segment, which reads better than Whisper's single line."""
    lines = [s["text"] for s in result.get("segments", []) if s.get("text")]
    return ("\n".join(lines) if lines else result.get("text", "")).strip() + "\n"


def cmd_files(args):
    if not health():
        sys.exit("transcribe: engine not running on %s (try: transcribe server start)" % base_url())
    rc = 0
    for f in args.files:
        src = Path(f).expanduser().resolve()
        if not src.is_file():
            print("transcribe: not a file: %s" % src, file=sys.stderr)
            rc = 1
            continue
        try:
            result = transcribe_one(src, args.language)
        except Exception as e:
            print("transcribe: %s: %s" % (src.name, e), file=sys.stderr)
            rc = 1
            continue
        saved = None
        if args.save:
            try:
                saved = save_path(src)
                saved.write_text(file_text(result))
            except OSError as e:
                print("transcribe: could not save next to %s: %s" % (src.name, e), file=sys.stderr)
                saved = None
        record(src, saved, result)
        if len(args.files) > 1:
            print("── %s" % src.name)
        print(as_text(result, args.format))
        if saved:
            print("saved: %s" % saved, file=sys.stderr)
    sys.exit(rc)


def recent(n):
    out = []
    for p in sorted(HISTORY.glob("*.json"), reverse=True)[:n]:
        try:
            out.append(json.loads(p.read_text()))
        except (OSError, ValueError):
            pass
    return out


def cmd_recent(args):
    items = recent(args.n)
    if args.json:
        print(json.dumps(items, ensure_ascii=False, indent=2))
        return
    for e in items:
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(e.get("created", 0)))
        text = " ".join((e.get("text") or "").split())
        print("%s  %s  %s" % (when, Path(e.get("source", "?")).name, text[:100]))


def cmd_status(args):
    h = health()
    s = {"url": base_url(), "running": bool(h), "health": h, "label": LABEL,
         "history": len(list(HISTORY.glob("*.json"))) if HISTORY.is_dir() else 0}
    if args.json:
        print(json.dumps(s, indent=2))
    else:
        if h:
            print("running  %s  model %s (%s)" % (s["url"], h.get("model"),
                  "warm" if h.get("models_loaded", {}).get("whisper") else "loading"))
        else:
            print("not running  %s" % s["url"])
    sys.exit(0 if h else 1)


def cmd_server(args):
    uid = os.getuid()
    target = "gui/%d/%s" % (uid, LABEL)
    plist = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    if args.action == "logs":
        os.execv("/usr/bin/tail", ["tail", "-n", "50", "-f", str(LOG)])
    if args.action in ("start", "restart"):
        if not plist.exists():
            sys.exit("transcribe: %s is not installed (run transcribe/scripts/install-engine.sh)" % plist)
        subprocess.run(["/bin/launchctl", "bootstrap", "gui/%d" % uid, str(plist)], capture_output=True)
        subprocess.run(["/bin/launchctl", "kickstart"] + (["-k"] if args.action == "restart" else []) + [target])
        for _ in range(40):
            if health():
                print("running  %s" % base_url())
                return
            time.sleep(0.5)
        sys.exit("transcribe: engine did not answer; see %s" % LOG)
    if args.action == "stop":
        subprocess.run(["/bin/launchctl", "bootout", target])
        print("stopped (launchd will start it again at login; uninstall-engine.sh removes it)")


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] in ("recent", "status", "server"):
        ap = argparse.ArgumentParser(prog="transcribe")
        sub = ap.add_subparsers(dest="cmd", required=True)
        r = sub.add_parser("recent")
        r.add_argument("-n", type=int, default=10)
        r.add_argument("--json", action="store_true")
        s = sub.add_parser("status")
        s.add_argument("--json", action="store_true")
        v = sub.add_parser("server")
        v.add_argument("action", choices=["start", "stop", "restart", "logs", "status"])
        a = ap.parse_args(argv)
        if a.cmd == "recent":
            return cmd_recent(a)
        if a.cmd == "status" or (a.cmd == "server" and a.action == "status"):
            a.json = getattr(a, "json", False)
            return cmd_status(a)
        return cmd_server(a)
    ap = argparse.ArgumentParser(prog="transcribe", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", metavar="FILE")
    ap.add_argument("--format", choices=["txt", "json", "md"], default="txt")
    ap.add_argument("--save", dest="save", action="store_true", default=True)
    ap.add_argument("--no-save", dest="save", action="store_false")
    ap.add_argument("--language", default=None)
    cmd_files(ap.parse_args(argv))


if __name__ == "__main__":
    main()
