"""Contract tests: run with /usr/bin/python3 -m unittest discover -s transcribe/engine -v
No model, no network beyond loopback: the transcriber and ffprobe are faked."""

import json
import sys
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib import error, request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cli  # noqa: E402
import server  # noqa: E402


class FakeWhisper:
    loaded = True

    def __call__(self, path, language=None):
        return {"text": " hola mundo ", "language": language or "es",
                "segments": [{"start": 0, "end": 1.0, "text": " hola"}, {"start": 1.0, "end": 2.5, "text": "mundo "}]}


class EngineContract(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.audio = self.tmp / "note.oga"
        self.audio.write_bytes(b"OggS")
        self.silent = self.tmp / "silent.mp4"
        self.silent.write_bytes(b"x")
        probe = lambda p: Path(p).name != "silent.mp4"  # noqa: E731
        self.engine = server.Engine(FakeWhisper(), self.tmp / "jobs", "fake/model", probe=probe)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.engine))
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]

    def tearDown(self):
        self.httpd.shutdown()

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = request.Request(self.base + path, data=data, method=method,
                              headers={"Content-Type": "application/json"})
        try:
            with request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except error.HTTPError as e:
            return e.code, json.loads(e.read())

    def wait(self, job_id):
        for _ in range(100):
            code, v = self.call("GET", "/jobs/" + job_id)
            if v["status"] in ("done", "error"):
                return v
            time.sleep(0.02)
        self.fail("job never finished")

    def test_health_matches_saywhat_reader(self):
        code, v = self.call("GET", "/health")
        self.assertEqual(code, 200)
        self.assertEqual(v["status"], "ok")
        self.assertIs(v["models_loaded"]["whisper"], True)
        self.assertIs(v["models_loaded"]["diarization"], False)

    def test_basic_job_writes_into_output_dir(self):
        out = self.tmp / "out"
        code, v = self.call("POST", "/jobs", {"file_path": str(self.audio), "mode": "basic", "output_dir": str(out)})
        self.assertEqual(code, 202)
        self.assertEqual(set(v), {"job_id", "status"})
        done = self.wait(v["job_id"])
        self.assertEqual(done["status"], "done")
        r = done["result"]
        self.assertEqual(r["text"], "hola mundo")
        self.assertEqual(r["segments"][-1], {"start": 1.0, "end": 2.5, "text": "mundo"})
        self.assertEqual(r["duration"], 2.5)
        self.assertEqual(Path(r["output_file"]), out / "note.json")
        self.assertTrue((out / "note.json").is_file())
        self.assertFalse((self.tmp / "note.json").exists(), "nothing may land next to the input")

    def test_no_output_dir_uses_engine_jobs_dir(self):
        code, v = self.call("POST", "/jobs", {"file_path": str(self.audio)})
        done = self.wait(v["job_id"])
        self.assertEqual(Path(done["result"]["output_file"]), self.tmp / "jobs" / "note.json")

    def test_language_passes_through(self):
        code, v = self.call("POST", "/jobs", {"file_path": str(self.audio), "language": "en"})
        self.assertEqual(self.wait(v["job_id"])["result"]["language"], "en")

    def test_no_audio_track_is_a_clear_error(self):
        code, v = self.call("POST", "/jobs", {"file_path": str(self.silent)})
        done = self.wait(v["job_id"])
        self.assertEqual(done["status"], "error")
        self.assertIn("no audio track in silent.mp4", done["error"])

    def test_rejections(self):
        self.assertEqual(self.call("POST", "/jobs", {"file_path": str(self.tmp / "nope.m4a")})[0], 400)
        self.assertEqual(self.call("POST", "/jobs", {"file_path": str(self.audio), "mode": "diarize"})[0], 400)
        self.assertEqual(self.call("POST", "/jobs", {})[0], 400)
        self.assertEqual(self.call("GET", "/jobs/does-not-exist")[0], 404)


class SaveNaming(unittest.TestCase):
    def test_never_overwrites(self):
        d = Path(tempfile.mkdtemp())
        src = d / "memo.m4a"
        src.write_bytes(b"")
        self.assertEqual(cli.save_path(src), d / "memo.txt")
        (d / "memo.txt").write_text("mine")
        self.assertEqual(cli.save_path(src), d / "memo transcript.txt")
        (d / "memo transcript.txt").write_text("")
        self.assertEqual(cli.save_path(src), d / "memo transcript 2.txt")

    def test_file_text_is_one_line_per_segment(self):
        r = FakeWhisper()(Path("x"))
        r["segments"] = [dict(s, text=s["text"].strip()) for s in r["segments"]]
        self.assertEqual(cli.file_text(r), "hola\nmundo\n")


if __name__ == "__main__":
    unittest.main()
