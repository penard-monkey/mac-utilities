"""Transcribe engine: keeps mlx-whisper warm and serves jobs over loopback HTTP.

Contract (unchanged from the audio-notes server it replaces, so saywhat and
other clients need no code change):

  GET  /health            {"status":"ok","models_loaded":{"whisper":bool,"diarization":false},
                           "engine":"mlx-whisper","model":<repo>}
  POST /jobs              {"file_path", "mode":"basic", "output_dir"?, "language"?}
                          202 {"job_id","status"} | 400 {"detail"}
  GET  /jobs/{id}         {"job_id","status":queued|running|done|error,"result","error"} | 404
  result = {"text","segments":[{"start","end","text"}],"language","output_file","duration"}

Differences from audio-notes, on purpose:
- Only mode "basic" (no speaker labels, no LM Studio roles).
- Without output_dir the JSON goes to the engine's own jobs dir, never next to
  the input.
- Video is decoded by ffmpeg directly; no <stem>.wav is left behind.
- A file with no audio stream fails as "no audio track in <name> — nothing to
  transcribe" (clients treat that text as a permanent failure).

Stdlib only apart from mlx_whisper, which is imported lazily so tests run with
a fake transcriber and no model.
"""

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
DEFAULT_PORT = 8765
MAX_JOBS_KEPT = 500
FFPROBE_CANDIDATES = ("/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe")


class NoAudioTrack(ValueError):
    """The container is readable but carries no audio stream (a GIF, a silent clip)."""


def ffprobe_path():
    for p in FFPROBE_CANDIDATES:
        if os.access(p, os.X_OK):
            return p
    return shutil.which("ffprobe")


def has_audio_stream(path):
    """True/False from ffprobe; None when ffprobe could not be asked."""
    probe = ffprobe_path()
    if not probe:
        return None
    try:
        out = subprocess.run(
            [probe, "-v", "error", "-select_streams", "a",
             "-show_entries", "stream=codec_type", "-of", "csv=p=0", str(path)],
            capture_output=True, text=True, timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return "audio" in out.stdout


class MlxWhisper:
    """The real engine. One model, loaded once, used from one worker thread."""

    def __init__(self, model):
        self.model = model
        self.loaded = False

    def warm(self):
        # Fill the same cache transcribe() reads (ModelHolder, fp16), so the
        # first real job does not load the weights a second time.
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder
        ModelHolder.get_model(self.model, mx.float16)
        self.loaded = True

    def __call__(self, path, language=None):
        import mlx_whisper
        kwargs = {"path_or_hf_repo": self.model}
        if language:
            kwargs["language"] = language
        r = mlx_whisper.transcribe(str(path), **kwargs)
        self.loaded = True
        return r


class Job:
    def __init__(self, file_path, output_dir, language):
        self.id = str(uuid.uuid4())
        self.file_path = file_path
        self.output_dir = output_dir
        self.language = language
        self.status = "queued"
        self.result = None
        self.error = None
        self.created = time.time()

    def view(self):
        return {"job_id": self.id, "status": self.status, "result": self.result, "error": self.error}


class Engine:
    def __init__(self, transcriber, jobs_dir, model, probe=has_audio_stream, warm=None):
        self.transcriber = transcriber
        self.jobs_dir = Path(jobs_dir)
        self.model = model
        self.probe = probe
        self.jobs = {}
        self.order = []
        self.lock = threading.Lock()
        self.queue = queue.Queue()
        self.warm = warm
        threading.Thread(target=self._worker, name="transcribe-worker", daemon=True).start()

    def submit(self, file_path, output_dir=None, language=None):
        job = Job(file_path, output_dir, language)
        with self.lock:
            self.jobs[job.id] = job
            self.order.append(job.id)
            while len(self.order) > MAX_JOBS_KEPT:
                old = self.jobs.get(self.order[0])
                if old and old.status in ("queued", "running"):
                    break
                self.jobs.pop(self.order.pop(0), None)
        self.queue.put(job)
        return job

    def get(self, job_id):
        with self.lock:
            return self.jobs.get(job_id)

    def _worker(self):
        # MLX is used from this one thread only: warm-up first, then jobs.
        if self.warm:
            t = time.time()
            try:
                self.warm()
                sys.stderr.write("model %s warm in %.1fs\n" % (self.model, time.time() - t))
            except Exception as exc:
                sys.stderr.write("warm-up failed (first job will retry): %s\n" % exc)
        while True:
            job = self.queue.get()
            job.status = "running"
            try:
                job.result = self._run(job)
                job.status = "done"
            except Exception as exc:  # reported to the client, never fatal to the worker
                job.error = str(exc) or type(exc).__name__
                job.status = "error"
                sys.stderr.write("job %s failed: %s\n" % (job.id, job.error))

    def _run(self, job):
        src = Path(job.file_path)
        if self.probe(src) is False:
            raise NoAudioTrack("no audio track in %s — nothing to transcribe" % src.name)
        out_dir = Path(job.output_dir) if job.output_dir else self.jobs_dir
        out_dir.mkdir(parents=True, exist_ok=True)
        started = time.time()
        r = self.transcriber(src, language=job.language)
        segments = [
            {"start": float(s.get("start", 0)), "end": float(s.get("end", 0)),
             "text": (s.get("text") or "").strip()}
            for s in (r.get("segments") or [])
        ]
        payload = {
            "text": (r.get("text") or "").strip(),
            "segments": segments,
            "language": r.get("language"),
            "duration": segments[-1]["end"] if segments else None,
            "elapsed": round(time.time() - started, 3),
            "engine": "mlx-whisper",
            "model": self.model,
        }
        out_path = out_dir / ("%s.json" % src.stem)
        tmp = out_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2))
        os.replace(tmp, out_path)
        return dict(payload, output_file=str(out_path))

    def health(self):
        return {"status": "ok",
                "models_loaded": {"whisper": bool(getattr(self.transcriber, "loaded", True)), "diarization": False},
                "engine": "mlx-whisper", "model": self.model,
                "queued": self.queue.qsize()}


def make_handler(engine):
    class Handler(BaseHTTPRequestHandler):
        server_version = "transcribe/1"

        def _send(self, code, body):
            data = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = self.path.split("?", 1)[0].rstrip("/")
            if path == "/health":
                return self._send(200, engine.health())
            if path.startswith("/jobs/"):
                job = engine.get(path[len("/jobs/"):])
                if not job:
                    return self._send(404, {"detail": "Job not found"})
                return self._send(200, job.view())
            self._send(404, {"detail": "Not found"})

        def do_POST(self):
            if self.path.split("?", 1)[0].rstrip("/") != "/jobs":
                return self._send(404, {"detail": "Not found"})
            try:
                n = int(self.headers.get("Content-Length") or 0)
                req = json.loads(self.rfile.read(n) or b"{}")
            except (ValueError, json.JSONDecodeError):
                return self._send(400, {"detail": "Body must be JSON"})
            if not isinstance(req, dict) or not req.get("file_path"):
                return self._send(400, {"detail": "file_path is required"})
            mode = req.get("mode") or "basic"
            if mode != "basic":
                return self._send(400, {"detail": "mode must be basic (speaker labels were removed)"})
            path = Path(os.path.expanduser(req["file_path"])).resolve()
            if not path.is_file():
                return self._send(400, {"detail": "File not found: %s" % path})
            out = req.get("output_dir")
            out = str(Path(os.path.expanduser(out)).resolve()) if out else None
            job = engine.submit(str(path), out, req.get("language") or None)
            self._send(202, {"job_id": job.id, "status": job.status})

        def log_message(self, fmt, *args):
            if os.environ.get("TRANSCRIBE_ACCESS_LOG"):
                sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    return Handler


def main(argv=None):
    ap = argparse.ArgumentParser(description="Transcribe engine (mlx-whisper over loopback HTTP)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=int(os.environ.get("TRANSCRIBE_PORT", DEFAULT_PORT)))
    ap.add_argument("--model", default=os.environ.get("TRANSCRIBE_MODEL", DEFAULT_MODEL))
    ap.add_argument("--home", default=os.environ.get(
        "TRANSCRIBE_HOME", os.path.expanduser("~/.cache/mac-utilities/transcribe")))
    args = ap.parse_args(argv)
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        ap.error("the engine only binds to loopback")
    whisper = MlxWhisper(args.model)
    engine = Engine(whisper, Path(args.home) / "jobs", args.model, warm=whisper.warm)
    httpd = ThreadingHTTPServer((args.host, args.port), make_handler(engine))
    sys.stderr.write("transcribe engine on http://%s:%d (%s)\n" % (args.host, args.port, args.model))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
