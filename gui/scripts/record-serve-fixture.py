#!/usr/bin/env python3
"""Record a `transcribe serve` session for scripts/fake-serve.py.

    scripts/record-serve-fixture.py jobs     --audio A.m4a --audio B.mp3 [--cli PATH]
    scripts/record-serve-fixture.py download --hf-home /tmp/empty-hf [--cancel-after 6]

`jobs` runs a scripted session against the real worker: models, configure, a job with md+srt
(zh), a job on the 0.6B model (a model switch) with timestamps, a job cancelled after its
second segment, a job for a missing file, then shutdown. `download` uses an empty HF_HOME:
the `download` op for 0.6B cancelled after a few seconds, a job whose lazy download is
cancelled, then shutdown.

Every line in either direction is written to Tests/TranscribeKitTests/Fixtures/serve-NAME/
session.ndjson as {"t": seconds since start, "dir": "in"|"out", "msg": {...}}, and the outputs
the worker wrote are copied to outputs/. Paths are rewritten to /tmp/fixture/audio and
/tmp/fixture/out so fixtures don't depend on where they were recorded. Development tool only:
the app never runs Python.
"""
import argparse
import json
import os
import pathlib
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
FIXTURES = HERE.parent / "Tests" / "TranscribeKitTests" / "Fixtures"


class Session:
    def __init__(self, cmd, env, work):
        self.work = work
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=env, text=True, bufsize=1)
        self.t0 = time.monotonic()
        self.lines = []
        self.events = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    def _now(self):
        return round(time.monotonic() - self.t0, 3)

    def _read(self):
        for raw in self.proc.stdout:
            raw = raw.strip()
            if not raw:
                continue
            msg = json.loads(raw)
            self.lines.append({"t": self._now(), "dir": "out", "msg": msg})
            self.events.put(msg)
        self.events.put(None)

    def _drain_stderr(self):
        for line in self.proc.stderr:
            sys.stderr.write("  serve: " + line)

    def send(self, op):
        self.lines.append({"t": self._now(), "dir": "in", "msg": op})
        self.proc.stdin.write(json.dumps(op) + "\n")
        self.proc.stdin.flush()
        print("→", json.dumps(op)[:120], file=sys.stderr)

    def wait(self, pred, timeout=900):
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                raise TimeoutError("waiting for an event")
            msg = self.events.get(timeout=left)
            if msg is None:
                raise EOFError("worker exited")
            if msg.get("event") not in ("progress",):
                print("←", json.dumps(msg, ensure_ascii=False)[:120], file=sys.stderr)
            if pred(msg):
                return msg

    def finish(self):
        try:
            self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        return self.proc.returncode


def ends(job_id):
    return lambda m: m.get("id") == job_id and m.get("event") in ("file_done", "file_error", "file_stopped")


def jobs(s: Session, audio: list[pathlib.Path], out: pathlib.Path):
    a, b = audio[0], audio[1] if len(audio) > 1 else audio[0]
    s.send({"op": "models"})
    s.wait(lambda m: m.get("event") == "models")
    s.send({"op": "configure", "idle_unload_sec": 300})
    s.wait(lambda m: m.get("event") == "configured")
    s.send({"op": "enqueue", "job": {"id": "j1", "input": str(a), "formats": ["md", "srt"], "output_dir": str(out),
                                     "timestamps": False, "language": "zh", "context": "", "overwrite": True,
                                     "model": "1.7b"}})
    s.wait(ends("j1"))
    s.wait(lambda m: m.get("event") == "idle")
    s.send({"op": "enqueue", "job": {"id": "j2", "input": str(b), "formats": ["md", "txt"], "output_dir": str(out),
                                     "timestamps": True, "language": None, "context": "Marlowe", "overwrite": True,
                                     "model": "0.6b"}})
    s.wait(ends("j2"))
    s.send({"op": "enqueue", "job": {"id": "j3", "input": str(a), "formats": ["md"], "output_dir": str(out),
                                     "timestamps": False, "language": None, "context": "", "overwrite": True,
                                     "model": "1.7b"}})
    s.send({"op": "enqueue", "job": {"id": "j4", "input": str(out / "missing.m4a"), "formats": ["md"],
                                     "output_dir": str(out), "overwrite": True, "model": "1.7b"}})
    s.wait(lambda m: m.get("id") == "j3" and m.get("event") == "segment" and m.get("index") == 2)
    s.send({"op": "cancel", "id": "j3"})
    s.wait(ends("j3"))
    s.wait(ends("j4"))
    s.send({"op": "models"})
    s.wait(lambda m: m.get("event") == "models")
    s.send({"op": "shutdown"})


def download(s: Session, audio: list[pathlib.Path], out: pathlib.Path, cancel_after: float):
    s.send({"op": "models"})
    s.wait(lambda m: m.get("event") == "models")
    s.send({"op": "download", "model": "0.6b"})
    time.sleep(cancel_after)
    s.send({"op": "cancel_download", "model": "0.6b"})
    s.wait(lambda m: m.get("event") == "model_error")
    s.send({"op": "models"})
    s.wait(lambda m: m.get("event") == "models")
    s.send({"op": "enqueue", "job": {"id": "d1", "input": str(audio[0]), "formats": ["md"], "output_dir": str(out),
                                     "overwrite": True, "model": "0.6b"}})
    s.wait(lambda m: m.get("id") == "d1" and m.get("stage") == "download")
    time.sleep(cancel_after)
    s.send({"op": "cancel", "id": "d1"})
    s.wait(ends("d1"))
    s.send({"op": "models"})
    s.wait(lambda m: m.get("event") == "models")
    s.send({"op": "shutdown"})


def rewrite(value, mapping):
    if isinstance(value, str):
        for src, dst in mapping:
            value = value.replace(src, dst)
        return value
    if isinstance(value, list):
        return [rewrite(v, mapping) for v in value]
    if isinstance(value, dict):
        return {k: rewrite(v, mapping) for k, v in value.items()}
    return value


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario", choices=["jobs", "download"])
    ap.add_argument("--audio", action="append", default=[])
    ap.add_argument("--hf-home")
    ap.add_argument("--cancel-after", type=float, default=6)
    ap.add_argument("--cli", default=os.path.expanduser("~/.local/bin/transcribe"))
    a = ap.parse_args()

    work = pathlib.Path(tempfile.mkdtemp(prefix="serve-fixture-"))
    audio_dir, out = work / "audio", work / "out"
    audio_dir.mkdir()
    out.mkdir()
    audio = []
    for p in map(pathlib.Path, a.audio):
        shutil.copy(p, audio_dir / p.name)
        audio.append(audio_dir / p.name)
    env = dict(os.environ)
    if a.hf_home:
        env["HF_HOME"] = a.hf_home
    s = Session([a.cli, "serve"], env, work)
    try:
        if a.scenario == "jobs":
            jobs(s, audio, out)
        else:
            download(s, audio, out, a.cancel_after)
    finally:
        code = s.finish()

    dest = FIXTURES / f"serve-{a.scenario}"
    if dest.exists():
        shutil.rmtree(dest)
    (dest / "outputs").mkdir(parents=True)
    mapping = [(str(audio_dir), "/tmp/fixture/audio"), (str(out), "/tmp/fixture/out")]
    if a.hf_home:
        mapping.append((a.hf_home, "/tmp/fixture/hf"))
    with open(dest / "session.ndjson", "w") as f:
        for line in s.lines:
            f.write(json.dumps(rewrite(line, mapping), ensure_ascii=False) + "\n")
    for p in out.iterdir():
        if p.is_file():
            shutil.copy(p, dest / "outputs" / p.name)
    (dest / "exit").write_text(f"{code}\n")
    print(f"wrote {dest} ({len(s.lines)} lines, exit {code})", file=sys.stderr)
    shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
