"""Protocol tests for `transcribe serve`, driven in-process with a fake backend (no model)."""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path

import pytest

from fakes import FakeBackend
from transcribe import models, serve as serve_mod
from transcribe.types import Cancelled

TIMEOUT = 10


def make_wav(path: Path, seconds: float) -> Path:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16_000)
        w.writeframes(b"\x00\x00" * int(16_000 * seconds))
    return path


class Collector:
    """A write-only stream that keeps every NDJSON line it receives."""

    def __init__(self) -> None:
        self.events: list[dict] = []
        self._buf = ""
        self._lock = threading.Lock()

    def write(self, text: str) -> int:
        with self._lock:
            self._buf += text
            while "\n" in self._buf:
                line, self._buf = self._buf.split("\n", 1)
                self.events.append(json.loads(line))
        return len(text)

    def flush(self) -> None:
        pass


class Worker:
    def __init__(self, idle_unload: float = 300.0) -> None:
        self.lines: queue.Queue[str | None] = queue.Queue()
        self.out = Collector()
        self.code: int | None = None
        self.thread = threading.Thread(
            target=self._run, args=(idle_unload,), daemon=True
        )
        self.thread.start()

    def _run(self, idle_unload: float) -> None:
        self.code = serve_mod.serve(
            idle_unload=idle_unload,
            stdin=iter(self.lines.get, None),
            stdout=self.out,
            factory=FakeBackend,
        )

    def send(self, op: dict) -> None:
        self.lines.put(json.dumps(op))

    def eof(self) -> None:
        self.lines.put(None)

    def events(self, id: str | None = None) -> list[dict]:
        evs = list(self.out.events)
        return evs if id is None else [e for e in evs if e.get("id") == id]

    def names(self, id: str | None = None) -> list[str]:
        return [e["event"] for e in self.events(id)]

    def wait(self, pred, what: str = "condition"):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            hit = pred(list(self.out.events))
            if hit:
                return hit
            time.sleep(0.01)
        raise AssertionError(f"timed out waiting for {what}; got {self.out.events}")

    def wait_event(self, name: str, id: str | None = None, **match) -> dict:
        def find(evs):
            for e in evs:
                if e.get("event") == name and (id is None or e.get("id") == id) and all(
                    e.get(k) == v for k, v in match.items()
                ):
                    return e

        return self.wait(find, f"{name} {id or ''}")

    def finish(self) -> int:
        self.send({"op": "shutdown"})
        self.thread.join(TIMEOUT)
        assert not self.thread.is_alive(), "worker did not exit"
        return self.code


@pytest.fixture(autouse=True)
def fresh_fake():
    FakeBackend.reset()
    yield
    FakeBackend.reset()


@pytest.fixture
def worker():
    w = Worker()
    yield w
    if w.thread.is_alive():
        w.finish()


@pytest.fixture
def audio(tmp_path):
    return make_wav(tmp_path / "talk.wav", 70)  # three chunks: 30 + 30 + 10 s


def job(id: str, path: Path, **kw) -> dict:
    return {"op": "enqueue", "job": {"id": id, "input": str(path), **kw}}


# -- enqueue and event order -----------------------------------------------------------------


def test_enqueue_event_order_and_outputs(worker, audio, tmp_path):
    worker.send(job("j1", audio, formats=["md", "txt"], output_dir=str(tmp_path / "out")))
    done = worker.wait_event("file_done", "j1")
    evs = worker.events("j1")
    names = [e["event"] for e in evs]
    assert names[0] == "accepted"
    assert names.count("segment") == 3
    assert names[-1] == "file_done"
    stages = [(e["stage"], e["progress"]) for e in evs if e["event"] == "progress"]
    assert stages[0] == ("decode", 0.0)
    assert ("load", 0.0) in stages and ("load", 1.0) in stages
    assert stages.index(("load", 1.0)) < stages.index(("transcribe", 0.0))
    segs = [e for e in evs if e["event"] == "segment"]
    assert [s["index"] for s in segs] == [1, 2, 3]
    assert [s["start"] for s in segs] == [0.0, 30.0, 60.0]
    assert segs[2]["end"] == 70.0 and segs[0]["text"] == "text 1" and segs[0]["language"] == "English"
    assert done["segments"] == [
        {"start": 0.0, "end": 30.0, "text": "text 1"},
        {"start": 30.0, "end": 60.0, "text": "text 2"},
        {"start": 60.0, "end": 70.0, "text": "text 3"},
    ]
    assert set(done["outputs"]) == {"md", "txt"}
    assert all(Path(p).exists() for p in done["outputs"].values())
    assert done["language"] == "English" and done["duration"] == 70.0
    # Every job event carries the id.
    assert all(e["id"] == "j1" for e in evs)


def test_srt_aligns_each_chunk_right_after_it(worker, audio):
    worker.send(job("j1", audio, formats=["srt"]))
    worker.wait_event("file_done", "j1")
    seq = [
        (e["event"], e.get("chunk"))
        for e in worker.events("j1")
        if e["event"] == "segment" or (e["event"] == "progress" and e["stage"] == "align")
    ]
    assert [x[0] for x in seq] == ["segment", "progress", "segment", "progress", "segment", "progress", "progress"]
    align = [e for e in worker.events("j1") if e["event"] == "progress" and e["stage"] == "align"]
    assert [(e["chunk"], e["total_chunks"]) for e in align[:3]] == [(1, 3), (2, 3), (3, 3)]
    assert align[-1]["progress"] == 1.0
    assert Path(audio.with_suffix(".srt")).read_text().startswith("1\n")


def test_idle_event_after_queue_drains(worker, audio):
    worker.send(job("j1", audio))
    worker.wait_event("file_done", "j1")
    worker.wait_event("idle")
    assert "id" not in worker.wait_event("idle")


def test_invalid_jobs_are_rejected_with_the_job_id(worker, audio):
    worker.send(job("bad1", audio, formats=["docx"]))
    e = worker.wait_event("file_error", "bad1")
    assert "docx" in e["error"]
    assert "accepted" not in worker.names("bad1")
    worker.send(job("bad2", audio.with_name("missing.wav")))
    assert worker.wait_event("file_error", "bad2")["error"]
    worker.send({"op": "enqueue", "job": {"input": "x"}})
    worker.wait_event("log", level="error")


def test_existing_output_needs_overwrite(worker, audio):
    audio.with_suffix(".md").write_text("keep me")
    worker.send(job("j1", audio))
    assert "overwrite" in worker.wait_event("file_error", "j1")["error"]
    assert audio.with_suffix(".md").read_text() == "keep me"
    worker.send(job("j2", audio, overwrite=True))
    worker.wait_event("file_done", "j2")
    assert audio.with_suffix(".md").read_text() != "keep me"


def test_idle_after_a_job_ends_with_output_exists(worker, audio):
    audio.with_suffix(".md").write_text("keep me")
    worker.send(job("j1", audio))
    worker.wait_event("file_error", "j1")
    worker.wait_event("idle")
    assert FakeBackend.log == []  # ended before any model was loaded, and still idle


def test_duplicate_active_id_is_refused(worker, audio):
    FakeBackend.gate = threading.Event()
    worker.send(job("j1", audio))
    worker.wait_event("accepted", "j1")
    worker.send(job("j1", audio))
    worker.wait_event("log", level="error")
    assert worker.names("j1").count("accepted") == 1
    FakeBackend.gate.set()
    worker.wait_event("file_done", "j1")


def test_jobs_run_one_at_a_time_in_order(worker, audio, tmp_path):
    second = make_wav(tmp_path / "two.wav", 10)
    FakeBackend.gate = threading.Event()
    worker.send(job("j1", audio))
    worker.send(job("j2", second))
    worker.wait_event("accepted", "j2")
    time.sleep(0.1)
    assert "progress" not in worker.names("j2")  # waiting its turn
    FakeBackend.gate.set()
    worker.wait_event("file_done", "j2")
    ev = worker.events()
    first_done = next(i for i, e in enumerate(ev) if e.get("event") == "file_done" and e["id"] == "j1")
    second_start = next(i for i, e in enumerate(ev) if e.get("id") == "j2" and e["event"] == "progress")
    assert first_done < second_start
    assert FakeBackend.log == ["load:fake/default"]  # the second job reused the model


# -- cancel ----------------------------------------------------------------------------------


def test_cancel_queued_job_replies_file_stopped(worker, audio, tmp_path):
    second = make_wav(tmp_path / "two.wav", 10)
    FakeBackend.gate = threading.Event()
    worker.send(job("j1", audio))
    worker.send(job("j2", second))
    worker.wait_event("accepted", "j2")
    worker.send({"op": "cancel", "id": "j2"})
    stopped = worker.wait_event("file_stopped", "j2")
    assert stopped["stopped_at"] == 0.0
    FakeBackend.gate.set()
    worker.wait_event("file_done", "j1")
    worker.send(job("j3", second))
    worker.wait_event("file_done", "j3")
    assert "progress" not in worker.names("j2")  # j2 never started
    assert worker.names("j3")[-1] == "file_done"


def test_cancel_running_job_stops_at_chunk_boundary_and_next_job_runs(worker, audio, tmp_path):
    FakeBackend.chunk_delay = 0.2
    out = tmp_path / "out"
    worker.send(job("j1", audio, formats=["md", "srt"], output_dir=str(out)))
    worker.wait_event("segment", "j1", index=1)
    t0 = time.monotonic()
    worker.send({"op": "cancel", "id": "j1"})
    stopped = worker.wait_event("file_stopped", "j1")
    assert time.monotonic() - t0 < 5
    assert 0 < stopped["stopped_at"] < 70
    assert "file_done" not in worker.names("j1")
    assert not out.exists() or list(out.iterdir()) == []  # no partial output left behind
    # The worker is healthy: the next job runs and the model stays loaded.
    FakeBackend.chunk_delay = 0.0
    worker.send(job("j2", audio, output_dir=str(out)))
    worker.wait_event("file_done", "j2")
    assert FakeBackend.log == ["load:fake/default"]


def test_cancelled_job_leaves_no_output_files(worker, audio, tmp_path):
    # A job cancelled before it finishes writes nothing into the output folder.
    FakeBackend.gate = threading.Event()
    worker.send(job("j1", audio, formats=["md", "txt", "json"]))
    worker.wait_event("accepted", "j1")
    worker.send({"op": "cancel", "id": "j1"})
    FakeBackend.gate.set()
    worker.wait_event("file_stopped", "j1")
    assert not [p for p in audio.parent.iterdir() if p.suffix != ".wav"]


def test_cancel_all(worker, audio, tmp_path):
    second = make_wav(tmp_path / "two.wav", 10)
    third = make_wav(tmp_path / "three.wav", 10)
    FakeBackend.gate = threading.Event()
    FakeBackend.chunk_delay = 0.05
    for i, p in enumerate((audio, second, third), 1):
        worker.send(job(f"j{i}", p))
    worker.wait_event("accepted", "j3")
    worker.wait_event("progress", "j1", stage="transcribe")
    worker.send({"op": "cancel_all"})
    FakeBackend.gate.set()
    for i in (1, 2, 3):
        worker.wait_event("file_stopped", f"j{i}")
    assert worker.names().count("file_done") == 0


def test_cancel_during_model_download_stops_the_job(worker, audio):
    FakeBackend.download_on_load = True
    FakeBackend.gate = None
    gate = threading.Event()
    orig = FakeBackend.load

    def slow_load(self, on_progress=None, should_cancel=None):
        gate.wait(5)
        return orig(self, on_progress, should_cancel)

    FakeBackend.load = slow_load
    try:
        worker.send(job("j1", audio))
        worker.wait_event("progress", "j1", stage="load")
        worker.send({"op": "cancel", "id": "j1"})
        time.sleep(0.2)  # let the reader thread flag the job before the download "continues"
        gate.set()
        worker.wait_event("file_stopped", "j1")
        assert "file_done" not in worker.names("j1")
    finally:
        FakeBackend.load = orig


def test_cancelled_download_in_a_job_also_sends_model_error(worker, audio):
    FakeBackend.download_on_load = True
    FakeBackend.download_gate = threading.Event()
    worker.send(job("j1", audio, model="Qwen/Qwen3-ASR-0.6B"))
    worker.wait_event("progress", "j1", stage="download", progress=0.5)
    worker.send({"op": "cancel", "id": "j1"})
    time.sleep(0.2)
    FakeBackend.download_gate.set()
    worker.wait_event("file_stopped", "j1")
    err = worker.wait_event("model_error")
    assert err == {"event": "model_error", "model": "0.6b", "error": "cancelled", "cancelled": True}
    # A job whose download finishes reports no model_error.
    worker.send(job("j2", audio, model="a", overwrite=True))
    worker.wait_event("file_done", "j2")
    assert worker.names().count("model_error") == 1


def test_download_events_during_a_job_carry_its_id(worker, audio):
    FakeBackend.download_on_load = True
    worker.send(job("j1", audio))
    worker.wait_event("file_done", "j1")
    dl = [e for e in worker.events() if e.get("stage") == "download"]
    assert [e["progress"] for e in dl] == [0.0, 0.5, 1.0]
    assert all(e["id"] == "j1" and e["model"] == "fake/default" for e in dl)


# -- shutdown --------------------------------------------------------------------------------


def test_shutdown_stops_running_job_and_exits_zero(worker, audio):
    FakeBackend.chunk_delay = 0.2
    worker.send(job("j1", audio))
    worker.wait_event("segment", "j1", index=1)
    worker.send({"op": "shutdown"})
    worker.thread.join(TIMEOUT)
    assert worker.code == 0
    assert worker.names("j1")[-1] == "file_stopped"
    assert FakeBackend.log[-1] == "unload:fake/default"


def test_stdin_eof_behaves_like_shutdown(worker, audio, tmp_path):
    second = make_wav(tmp_path / "two.wav", 10)
    FakeBackend.chunk_delay = 0.2
    worker.send(job("j1", audio))
    worker.send(job("j2", second))
    worker.wait_event("segment", "j1", index=1)
    worker.eof()
    worker.thread.join(TIMEOUT)
    assert worker.code == 0
    assert worker.wait_event("file_stopped", "j1") and worker.wait_event("file_stopped", "j2")


def test_idle_worker_exits_on_shutdown_and_eof():
    for end in ("shutdown", "eof"):
        w = Worker()
        w.send({"op": "models"})
        w.wait_event("models")
        w.send({"op": "shutdown"}) if end == "shutdown" else w.eof()
        w.thread.join(TIMEOUT)
        assert w.code == 0


# -- model residency -------------------------------------------------------------------------


def test_switching_models_unloads_the_old_one(worker, audio, tmp_path):
    second = make_wav(tmp_path / "two.wav", 10)
    worker.send(job("j1", audio, model="a"))
    worker.wait_event("file_done", "j1")
    worker.send(job("j2", second, model="b"))
    worker.wait_event("file_done", "j2")
    assert FakeBackend.log == ["load:fake/a", "unload:fake/a", "load:fake/b"]
    unloaded = worker.wait_event("unloaded")
    assert unloaded["reason"] == "switch" and "id" not in unloaded


def test_same_model_stays_loaded(worker, audio, tmp_path):
    second = make_wav(tmp_path / "two.wav", 10)
    worker.send(job("j1", audio, model="a"))
    worker.send(job("j2", second, model="a"))
    worker.wait_event("file_done", "j2")
    assert FakeBackend.log == ["load:fake/a"]


def test_idle_unload_then_reload(audio):
    w = Worker(idle_unload=0.3)
    try:
        w.send(job("j1", audio))
        w.wait_event("file_done", "j1")
        w.wait_event("unloaded", reason="idle")
        assert FakeBackend.log == ["load:fake/default", "unload:fake/default"]
        w.send(job("j2", audio, overwrite=True))
        w.wait_event("file_done", "j2")
        assert FakeBackend.log[-1] == "load:fake/default"
        assert ("load", 0.0) in [(e["stage"], e["progress"]) for e in w.events("j2") if e["event"] == "progress"]
    finally:
        w.finish()


def test_configure_changes_idle_unload_at_runtime(worker, audio):
    worker.send(job("j1", audio))
    worker.wait_event("file_done", "j1")
    time.sleep(0.3)
    assert FakeBackend.log == ["load:fake/default"]  # default 300 s: still loaded
    worker.send({"op": "configure", "idle_unload_sec": 0.2})
    assert worker.wait_event("configured")["idle_unload_sec"] == 0.2
    worker.wait_event("unloaded", reason="idle")
    worker.send({"op": "configure", "idle_unload_sec": -1})
    worker.wait_event("log", level="error")


def test_idle_unload_zero_means_never(audio):
    w = Worker(idle_unload=0)
    try:
        w.send(job("j1", audio))
        w.wait_event("file_done", "j1")
        time.sleep(0.5)
        assert FakeBackend.log == ["load:fake/default"]
    finally:
        w.finish()


def test_preload_loads_before_any_job(worker, audio):
    worker.send({"op": "preload", "model": "a"})
    ready = worker.wait_event("model_ready")
    assert ready["model"] == "a" and "id" not in ready
    assert FakeBackend.log == ["load:fake/a"]
    worker.send(job("j1", audio, model="a"))
    worker.wait_event("file_done", "j1")
    assert FakeBackend.log == ["load:fake/a"]  # the job reused the preloaded model
    assert ("load", 0.0) not in [
        (e["stage"], e["progress"]) for e in worker.events("j1") if e["event"] == "progress"
    ]


def test_preload_error_is_reported(worker):
    worker.send({"op": "preload", "model": "aligner"})
    assert "speech" in worker.wait_event("model_error")["error"]


# -- model catalog ops -----------------------------------------------------------------------


@pytest.fixture
def hf_home(tmp_path, monkeypatch):
    for var in ("HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    return tmp_path / "hf" / "hub"


def fake_repo(hub: Path, repo: str, complete: bool) -> int:
    root = hub / ("models--" + repo.replace("/", "--"))
    blobs, snap = root / "blobs", root / "snapshots" / "abc"
    blobs.mkdir(parents=True)
    snap.mkdir(parents=True)
    (root / "refs").mkdir()
    (root / "refs" / "main").write_text("abc")
    (blobs / "cfg").write_text("{}")
    (snap / "config.json").symlink_to(blobs / "cfg")
    if complete:
        (blobs / "w").write_bytes(b"x" * 1000)
        (snap / "model.safetensors").symlink_to(blobs / "w")
        return 1002
    (blobs / "w.incomplete").write_bytes(b"x" * 500)
    return 502


def test_models_op_reports_status_and_sizes_without_double_counting(worker, hf_home):
    size = fake_repo(hf_home, "Qwen/Qwen3-ASR-1.7B", complete=True)
    fake_repo(hf_home, "Qwen/Qwen3-ASR-0.6B", complete=False)
    worker.send({"op": "models"})
    ev = worker.wait_event("models")
    assert "id" not in ev
    rows = {m["id"]: m for m in ev["models"]}
    assert set(rows) == {"1.7b", "0.6b", "aligner"}
    assert rows["1.7b"]["status"] == "downloaded" and rows["1.7b"]["bytes_on_disk"] == size
    assert rows["0.6b"]["status"] == "partial" and rows["0.6b"]["bytes_on_disk"] == 502
    assert rows["aligner"]["status"] == "not_downloaded" and rows["aligner"]["bytes_on_disk"] == 0
    for key in ("repo", "kind", "params", "size_bytes", "ram_gb", "languages", "aligned_languages",
                "license", "url", "status", "bytes_on_disk", "loaded"):  # fmt: skip
        assert key in rows["1.7b"]
    assert rows["1.7b"]["ram_gb"] > 0 and rows["1.7b"]["size_bytes"] > 0
    assert rows["1.7b"]["loaded"] is False and rows["1.7b"]["kind"] == "asr"


def test_blobs_behind_a_shared_store_are_counted_once(hf_home):
    root = hf_home / "models--Qwen--Qwen3-ASR-0.6B"
    (root / "blobs").mkdir(parents=True)
    (hf_home / "blobs" / "ab").mkdir(parents=True)
    real = hf_home / "blobs" / "ab" / "deadbeef"
    real.write_bytes(b"y" * 300)
    (root / "blobs" / "hash1").symlink_to(real)
    (root / "blobs" / "hash2").symlink_to(real)  # two names for the same bytes
    assert models.bytes_on_disk("Qwen/Qwen3-ASR-0.6B") == 300


def test_stale_incomplete_blob_is_ignored_once_the_blob_is_whole(hf_home):
    size = fake_repo(hf_home, "Qwen/Qwen3-ASR-0.6B", complete=True)
    blobs = hf_home / "models--Qwen--Qwen3-ASR-0.6B" / "blobs"
    (blobs / "w.57bfad2b.incomplete").write_bytes(b"x" * 400)  # left by a cancelled, then resumed, download
    assert models.status("Qwen/Qwen3-ASR-0.6B") == ("downloaded", size)


def test_models_op_marks_loaded(worker, hf_home):
    worker.send({"op": "preload", "model": "a"})
    worker.wait_event("model_ready")
    worker.send({"op": "models"})
    # The fake's repo is not in the catalog, so nothing is flagged loaded.
    assert all(m["loaded"] is False for m in worker.wait_event("models")["models"])


def test_aligner_loaded_is_reported_and_cleared_on_unload(worker, hf_home, audio):
    FakeBackend.aligner_repo = "Qwen/Qwen3-ForcedAligner-0.6B"

    def loaded(ev):
        return {m["id"] for m in ev["models"] if m["loaded"]}

    worker.send(job("j1", audio, formats=["srt"], model="Qwen/Qwen3-ASR-0.6B"))
    worker.wait_event("file_done", "j1")
    pushed = [e for e in worker.events() if e["event"] == "models"]
    assert [loaded(e) for e in pushed] == [{"0.6b"}, {"0.6b", "aligner"}]  # sent unasked as each one loads
    worker.send({"op": "models"})
    worker.wait(lambda evs: sum(e["event"] == "models" for e in evs) == 3, "models reply")
    assert loaded([e for e in worker.events() if e["event"] == "models"][-1]) == {"0.6b", "aligner"}

    worker.send(job("j2", audio, model="a", overwrite=True))  # switching models unloads both
    worker.wait_event("file_done", "j2")
    last = [e for e in worker.events() if e["event"] == "models"][-1]
    assert loaded(last) == set()


def test_download_op_events_and_ready(worker, hf_home, monkeypatch):
    def fake_download(info, emit, should_cancel=None):
        for p in (0.0, 0.5, 1.0):
            emit({"event": "progress", "stage": "download", "progress": p, "model": info.repo,
                  "downloaded_bytes": int(p * 10), "total_bytes": 10})  # fmt: skip

    monkeypatch.setattr(models, "download", fake_download)
    worker.send({"op": "download", "model": "0.6b"})
    worker.wait_event("model_ready", model="0.6b")
    dl = [e for e in worker.events() if e.get("stage") == "download"]
    assert [e["progress"] for e in dl] == [0.0, 0.5, 1.0]
    assert all("id" not in e and e["model"] == "0.6b" and e["repo"] == "Qwen/Qwen3-ASR-0.6B" for e in dl)


def test_cancel_download_and_error_events(worker, hf_home, monkeypatch):
    started = threading.Event()

    def slow_download(info, emit, should_cancel=None):
        started.set()
        while not should_cancel():
            time.sleep(0.01)
        raise Cancelled()

    monkeypatch.setattr(models, "download", slow_download)
    worker.send({"op": "download", "model": "1.7b"})
    assert started.wait(TIMEOUT)
    worker.send({"op": "download", "model": "1.7b"})
    assert worker.wait_event("model_error", model="1.7b")["error"] == "already downloading"
    t0 = time.monotonic()
    worker.send({"op": "cancel_download", "model": "1.7b"})
    err = worker.wait_event("model_error", model="1.7b", cancelled=True)
    assert time.monotonic() - t0 < 5 and err["error"] == "cancelled"
    worker.send({"op": "cancel_download", "model": "1.7b"})
    assert worker.wait_event("model_error", error="not downloading")
    worker.send({"op": "download", "model": "nope"})
    assert "unknown" in worker.wait_event("model_error", model="nope")["error"]


def test_download_failure_reports_model_error(worker, hf_home, monkeypatch):
    def boom(info, emit, should_cancel=None):
        raise RuntimeError("offline")

    monkeypatch.setattr(models, "download", boom)
    worker.send({"op": "download", "model": "aligner"})
    assert worker.wait_event("model_error", model="aligner")["error"] == "offline"


def test_remove_model(worker, hf_home):
    fake_repo(hf_home, "Qwen/Qwen3-ASR-0.6B", complete=True)
    worker.send({"op": "remove_model", "model": "0.6b"})
    removed = worker.wait_event("model_removed", model="0.6b")
    assert removed["freed_bytes"] == 1002
    assert not (hf_home / "models--Qwen--Qwen3-ASR-0.6B").exists()
    assert {m["id"]: m["status"] for m in worker.wait_event("models")["models"]}["0.6b"] == "not_downloaded"


def store_blob(hub: Path, digest: str, size: int) -> Path:
    path = hub / "blobs" / digest[:2] / digest
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"z" * size)
    return path


def link_blob(hub: Path, repo: str, etag: str, target: Path) -> None:
    """A repo blob as huggingface_hub 2.x makes it: a relative symlink into the shared store."""
    folder = "models--" + repo.replace("/", "--")
    blob = hub / folder / "blobs" / etag
    blob.parent.mkdir(parents=True, exist_ok=True)
    blob.symlink_to(os.path.relpath(target, blob.parent))
    refs = target.with_name(target.name + ".refs")
    refs.write_text((refs.read_text() if refs.exists() else "") + f"{folder}/blobs/{etag}\n")


def test_remove_deletes_shared_store_blobs_no_other_repo_links_to(hf_home):
    only_ours = store_blob(hf_home, "ab" + "1" * 62, 300)
    both = store_blob(hf_home, "cd" + "2" * 62, 200)
    fake_repo(hf_home, "Qwen/Qwen3-ASR-0.6B", complete=True)  # 1002 bytes of regular blobs
    link_blob(hf_home, "Qwen/Qwen3-ASR-0.6B", "e1", only_ours)
    link_blob(hf_home, "Qwen/Qwen3-ASR-0.6B", "e2", both)
    link_blob(hf_home, "Qwen/Qwen3-ASR-1.7B", "e3", both)
    assert models.bytes_on_disk("Qwen/Qwen3-ASR-0.6B") == 1002 + 300 + 200  # real sizes behind the links
    assert models.bytes_on_disk("Qwen/Qwen3-ASR-1.7B") == 200

    assert models.remove(models.find("0.6b")) == 1002 + 300
    assert not (hf_home / "models--Qwen--Qwen3-ASR-0.6B").exists()
    assert not only_ours.exists() and not only_ours.with_name(only_ours.name + ".refs").exists()
    assert both.exists()  # still linked from 1.7B
    assert both.with_name(both.name + ".refs").read_text() == "models--Qwen--Qwen3-ASR-1.7B/blobs/e3\n"
    assert models.bytes_on_disk("Qwen/Qwen3-ASR-1.7B") == 200
    assert models.status("Qwen/Qwen3-ASR-0.6B") == ("not_downloaded", 0)

    assert models.remove(models.find("1.7b")) == 200
    assert not both.exists()


def test_remove_model_op_reports_shared_bytes_freed(worker, hf_home):
    fake_repo(hf_home, "Qwen/Qwen3-ASR-0.6B", complete=True)
    link_blob(hf_home, "Qwen/Qwen3-ASR-0.6B", "e1", store_blob(hf_home, "ab" + "1" * 62, 300))
    worker.send({"op": "remove_model", "model": "0.6b"})
    assert worker.wait_event("model_removed", model="0.6b")["freed_bytes"] == 1302
    assert not any((hf_home / "blobs").rglob("ab" + "1" * 62))


class _PlanFile:
    def __init__(self, size: int, will_download: bool) -> None:
        self.file_size, self.will_download = size, will_download


@pytest.fixture
def fake_hub_download(monkeypatch):
    """Stub the dry-run listing and the transfer child; returns the emitted download events."""
    import huggingface_hub

    from transcribe import download

    monkeypatch.setattr(download, "EMIT_INTERVAL", 0.0)
    plan = [_PlanFile(2, False), _PlanFile(1000, True)]  # config cached, weights missing
    monkeypatch.setattr(huggingface_hub, "snapshot_download", lambda *a, **k: plan)
    events: list[dict] = []
    return download, events


def test_resumed_download_progress_covers_the_whole_model(hf_home, fake_hub_download, monkeypatch):
    download, events = fake_hub_download

    def child(repo_id, patterns, counter, should_cancel):
        counter.add("received", 600)
        counter.add("written", 1000)

    monkeypatch.setattr(download, "_run_child", child)
    assert download.ensure_model("Qwen/Qwen3-ASR-0.6B", events.append)
    got = [(e["downloaded_bytes"], e["total_bytes"]) for e in events]
    assert got[0] == (2, 1002)  # starts from what is already on disk
    assert got[1] == (602, 1002)
    assert got[-1] == (1002, 1002) and events[-1]["progress"] == 1.0
    assert all(t == 1002 for _, t in got)


def test_cancelled_download_leaves_only_real_bytes(hf_home, fake_hub_download, monkeypatch):
    download, events = fake_hub_download
    blobs = hf_home / "models--Qwen--Qwen3-ASR-0.6B" / "blobs"
    blobs.mkdir(parents=True)
    (blobs / "cfg").write_text("{}")

    def child(repo_id, patterns, counter, should_cancel):
        (blobs / "w.1a2b3c4d.incomplete").write_bytes(b"x" * 400)  # what a killed transfer leaves
        counter.add("received", 600)
        raise Cancelled()

    monkeypatch.setattr(download, "_run_child", child)
    with pytest.raises(Cancelled):
        download.ensure_model("Qwen/Qwen3-ASR-0.6B", events.append)
    assert not list(blobs.glob("*.incomplete"))
    assert models.status("Qwen/Qwen3-ASR-0.6B") == ("partial", 2)


def test_unknown_op_and_garbage_do_not_kill_the_worker(worker):
    worker.lines.put("this is not json")
    worker.send({"op": "frobnicate"})
    worker.lines.put("[1, 2]")
    worker.send({"op": "models"})
    worker.wait_event("models")
    assert worker.names().count("log") == 3


# -- stdout hygiene --------------------------------------------------------------------------


def test_stdout_carries_only_ndjson_even_if_the_model_prints(tmp_path):
    audio = make_wav(tmp_path / "talk.wav", 40)
    driver = (
        "import sys; sys.path.insert(0, %r)\n"
        "from fakes import FakeBackend\n"
        "from transcribe.serve import serve\n"
        "FakeBackend.noisy = True\n"
        "sys.exit(serve(factory=FakeBackend))\n" % str(Path(__file__).parent)
    )
    ops = [json.dumps({"op": "enqueue", "job": {"id": "j1", "input": str(audio)}}), json.dumps({"op": "shutdown"})]
    # Keep stdin open until the job is done: shutdown right away would cancel it.
    proc = subprocess.Popen(
        [sys.executable, "-c", driver], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, env={**os.environ, "PYTHONUNBUFFERED": "1"},
    )  # fmt: skip
    assert proc.stdin and proc.stdout
    proc.stdin.write(ops[0] + "\n")
    proc.stdin.flush()
    lines = []
    for line in proc.stdout:
        lines.append(line)
        if '"file_done"' in line:
            break
    proc.stdin.write(ops[1] + "\n")
    proc.stdin.flush()
    rest, err = proc.communicate(timeout=TIMEOUT)
    lines += rest.splitlines(keepends=True)
    assert proc.returncode == 0
    events = [json.loads(line) for line in lines]  # every line parses: nothing else on stdout
    assert any(e["event"] == "file_done" for e in events)
    assert "library says hello" in err and "raw fd write" in err


# -- library: align, transcript_path and export ----------------------------------------------


def test_align_and_transcript_path_with_no_formats(worker, audio, tmp_path):
    master = tmp_path / "lib" / "item" / "transcript.json"
    worker.send(job("j1", audio, formats=[], align=True, transcript_path=str(master)))
    done = worker.wait_event("file_done", "j1")
    assert done["transcript"] == str(master) and done["outputs"] == {}
    assert any(e.get("stage") == "align" for e in worker.events("j1"))  # cues requested without srt/vtt
    assert not audio.with_suffix(".md").exists()  # only the master was written
    data = json.loads(master.read_text())
    assert data["source"] == "talk.wav" and data["cues"] and data["cue_timing"] == done["cue_timing"]
    from transcribe.types import Transcript

    assert [s.text for s in Transcript.from_dict(data).segments] == ["text 1", "text 2", "text 3"]


def test_transcript_path_alongside_formats_and_default_formats(worker, audio, tmp_path):
    master = tmp_path / "m.json"
    worker.send(job("j1", audio, formats=["txt"], output_dir=str(tmp_path / "o"), transcript_path=str(master)))
    done = worker.wait_event("file_done", "j1")
    assert set(done["outputs"]) == {"txt"} and done["transcript"] == str(master)
    assert json.loads(master.read_text())["cues"] is None  # no align, no srt: no cues
    worker.send(job("j2", audio, formats=[], output_dir=str(tmp_path / "o2")))  # empty without a master: md
    assert set(worker.wait_event("file_done", "j2")["outputs"]) == {"md"}
    assert "transcript" not in worker.wait_event("file_done", "j2")


def test_relative_transcript_path_is_rejected(worker, audio):
    worker.send(job("j1", audio, transcript_path="rel/t.json"))
    assert "absolute" in worker.wait_event("file_error", "j1")["error"]


def test_export_op(worker, audio, tmp_path):
    master = tmp_path / "t.json"
    worker.send(job("j1", audio, formats=[], transcript_path=str(master)))
    worker.wait_event("file_done", "j1")
    out = tmp_path / "exp"
    worker.send({"op": "export", "id": "x1", "transcript": str(master), "formats": ["md", "srt"],
                 "output_dir": str(out), "timestamps": True})  # fmt: skip
    e = worker.wait_event("exported", "x1")
    assert e["outputs"] == {"md": str(out / "talk.md"), "srt": str(out / "talk.srt")}
    assert e["estimated_cues"] is True
    assert "**[00:00:30]** text 2" in (out / "talk.md").read_text()
    worker.send({"op": "export", "id": "x2", "transcript": str(master), "formats": ["txt"],
                 "output_dir": str(out), "title": "Renamed"})  # fmt: skip
    assert worker.wait_event("exported", "x2")["outputs"] == {"txt": str(out / "Renamed.txt")}


def test_export_is_answered_while_a_job_runs(worker, audio, tmp_path):
    master = tmp_path / "t.json"
    worker.send(job("j0", audio, formats=[], align=True, transcript_path=str(master)))
    worker.wait_event("file_done", "j0")
    FakeBackend.gate = threading.Event()  # the next job blocks inside its first chunk
    worker.send(job("j1", audio, output_dir=str(tmp_path / "o")))
    worker.wait_event("progress", "j1", stage="transcribe")
    worker.send({"op": "export", "id": "x1", "transcript": str(master), "formats": ["srt"],
                 "output_dir": str(tmp_path / "exp")})  # fmt: skip
    e = worker.wait_event("exported", "x1")
    assert e["estimated_cues"] is False
    assert "file_done" not in worker.names("j1")
    FakeBackend.gate.set()
    worker.wait_event("file_done", "j1")
    names = [(ev["event"], ev.get("id")) for ev in worker.events()]
    assert names.index(("exported", "x1")) < names.index(("file_done", "j1"))


def test_export_errors(worker, tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("{nope")
    cases = {
        "e1": {"transcript": str(bad), "formats": ["md"], "output_dir": str(tmp_path)},
        "e2": {"transcript": str(tmp_path / "missing.json"), "formats": ["md"], "output_dir": str(tmp_path)},
        "e3": {"transcript": str(bad), "formats": ["docx"], "output_dir": str(tmp_path)},
        "e4": {"transcript": str(bad), "formats": [], "output_dir": str(tmp_path)},
        "e5": {"formats": ["md"], "output_dir": str(tmp_path)},
    }
    for rid, op in cases.items():
        worker.send({"op": "export", "id": rid, **op})
    for rid in cases:
        assert worker.wait_event("export_error", rid)["message"]
    assert "not valid JSON" in worker.wait_event("export_error", "e1")["message"]
    assert "docx" in worker.wait_event("export_error", "e3")["message"]
    worker.send({"op": "export", "transcript": str(bad)})  # no id: logged, worker survives
    worker.wait_event("log", level="error")
    assert [e["id"] for e in worker.events() if e["event"] == "export_error"] == list(cases)


# -- align op ---------------------------------------------------------------------------------


def saved_transcript(tmp_path: Path, seconds: float = 70.0, name: str = "t.json") -> Path:
    from transcribe.exporters import ExportOptions, render
    from transcribe.types import Segment, Transcript

    segs = [Segment(f"text {i + 1}", i * 30.0, min((i + 1) * 30.0, seconds)) for i in range(int((seconds + 29) // 30))]
    t = Transcript(text=" ".join(s.text for s in segs), language="English", duration=seconds, backend="fake",
                   model="fake/default", segments=segs)  # fmt: skip
    t.warn("timing_estimated", "subtitle timing is estimated", [(0.0, seconds)])
    path = tmp_path / name
    path.write_text(render("json", t, ExportOptions(source="talk.wav")), encoding="utf-8")
    return path


def test_align_op_rewrites_the_transcript(worker, audio, tmp_path):
    FakeBackend.aligns = True
    src = saved_transcript(tmp_path)
    worker.send({"op": "align", "id": "a1", "transcript": str(src), "source": str(audio)})
    done = worker.wait_event("aligned", "a1")
    assert done["transcript"] == str(src) and done["cue_timing"] == "aligned" and done["notices"] == []
    names = worker.names("a1")
    assert names[0] == "accepted" and names[-1] == "aligned"
    stages = [e["stage"] for e in worker.events("a1") if e["event"] == "progress"]
    assert stages[0] == "decode" and stages.count("align") == 4  # 3 segments + 1.0
    data = json.loads(src.read_text())
    assert data["cue_timing"] == "aligned" and len(data["words"]) == 6 and data["source"] == "talk.wav"
    worker.wait_event("idle")
    assert not any(entry.startswith("load:") for entry in FakeBackend.log)  # aligner only


def test_align_op_waits_for_the_running_job_and_can_be_cancelled(worker, audio, tmp_path):
    FakeBackend.gate = threading.Event()
    FakeBackend.aligns = True
    worker.send(job("j1", audio, output_dir=str(tmp_path / "out")))
    worker.wait_event("accepted", "j1")
    src = saved_transcript(tmp_path)
    before = src.read_text()
    worker.send({"op": "align", "id": "a1", "transcript": str(src), "source": str(audio)})
    worker.send({"op": "align", "id": "a2", "transcript": str(src), "source": str(audio),
                 "output": str(tmp_path / "o.json")})  # fmt: skip
    worker.wait_event("accepted", "a2")
    worker.send({"op": "cancel", "id": "a1"})
    err = worker.wait_event("align_error", "a1")
    assert err["cancelled"] is True
    FakeBackend.gate.set()
    worker.wait_event("aligned", "a2")
    order = [e["event"] for e in worker.events() if e.get("id") in ("j1", "a2") and e["event"] in ("file_done", "aligned")]
    assert order == ["file_done", "aligned"]
    assert src.read_text() == before and json.loads((tmp_path / "o.json").read_text())["cue_timing"] == "aligned"


def test_cancel_running_align_leaves_the_transcript(worker, audio, tmp_path):
    FakeBackend.align_gate = threading.Event()
    FakeBackend.aligns = True
    src = saved_transcript(tmp_path)
    before = src.read_text()
    worker.send({"op": "align", "id": "a1", "transcript": str(src), "source": str(audio)})
    worker.wait(lambda evs: any(e.get("stage") == "align" for e in evs), "align progress")
    worker.send({"op": "cancel", "id": "a1"})
    assert worker.wait_event("align_error", "a1")["cancelled"] is True
    FakeBackend.align_gate.set()
    assert src.read_text() == before


def test_align_op_errors(worker, audio, tmp_path):
    src = saved_transcript(tmp_path)
    worker.send({"op": "align", "id": "a1", "transcript": "rel.json", "source": str(audio)})
    assert "absolute" in worker.wait_event("align_error", "a1")["message"]
    worker.send({"op": "align", "id": "a2", "transcript": str(src)})
    assert '"source"' in worker.wait_event("align_error", "a2")["message"]
    worker.send({"op": "align", "id": "a3", "transcript": str(src), "source": str(make_wav(tmp_path / "s.wav", 5))})
    assert "right source file" in worker.wait_event("align_error", "a3")["message"]
    worker.send({"op": "align", "id": "a4", "transcript": str(tmp_path / "nope.json"), "source": str(audio)})
    assert "cannot read" in worker.wait_event("align_error", "a4")["message"]
    worker.send({"op": "align", "transcript": str(src), "source": str(audio)})
    worker.wait(lambda evs: any(e.get("event") == "log" and "align needs" in e.get("message", "") for e in evs), "log")
