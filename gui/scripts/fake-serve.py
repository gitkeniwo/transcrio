#!/usr/bin/env python3
"""A stand-in for `transcribe serve` that replays sessions recorded from the real worker.

    TRANSCRIBE_CLI=gui/scripts/fake-serve.py  (the app runs `<cli> serve`)

Job events come from Tests/TranscribeKitTests/Fixtures/serve-jobs/session.ndjson (recorded
by record-serve-fixture.py): each recorded job is a template, picked by the input's file name
when one matches, otherwise in turn. Ids, paths and (when ffprobe can read the file) times are
rewritten for the job at hand, outputs are written from the template's outputs, and the
recorded pacing is kept. It answers every op the real worker does: enqueue, cancel (a running
job stops at its next segment), cancel_all, configure, preload, models, download,
cancel_download, remove_model, export, align and shutdown; stdin EOF and SIGTERM also shut it down.

Environment (all optional):
  FAKE_SERVE_FIXTURE   fixture directory (default: serve-jobs next to this script's tests)
  FAKE_SERVE_SPEED     pacing multiplier, e.g. 20 = twenty times faster (default 1)
  FAKE_SERVE_MODELS    initial statuses, e.g. "1.7b=downloaded,0.6b=not_downloaded,aligner=partial"
  FAKE_SERVE_DOWNLOAD_SEC  how long a full model download takes before SPEED (default 12)
  FAKE_SERVE_PAUSE_AT  hold every job after this many segments until it is cancelled (screenshots)
  FAKE_SERVE_FAIL      comma-separated input file names that fail with a decode error
  FAKE_SERVE_CRASH_AFTER  exit 1 abruptly after this many segments in total (worker-died tests)
  FAKE_SERVE_OPS_LOG   append every op received to this file (tests read it)
  FAKE_SERVE_EXPORT_DELAY  seconds an `export` op takes before SPEED (default 0; the making state)
  FAKE_SERVE_EXPORT_FAIL   comma-separated formats whose export fails (failed chips)
  FAKE_SERVE_ALIGN_SEC     seconds an `align` op takes before SPEED (default 4; the progress)
  FAKE_SERVE_ALIGN_FAIL    an `align` op fails with this message

Job keys from the library protocol are honoured: "align": true forces cues (as if srt were
asked for), and "transcript_path" writes the full transcript JSON there atomically (text,
segments, cues, words, language, model, duration, source); file_done then carries
"transcript", and "formats" may be [].
"""
import json
import os
import re
import pathlib
import signal
import subprocess
import sys
import threading
import time
from collections import deque

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_FIXTURE = HERE.parent / "Tests" / "TranscribeKitTests" / "Fixtures" / "serve-jobs"

SPEED = float(os.environ.get("FAKE_SERVE_SPEED") or 1) or 1
DOWNLOAD_SEC = float(os.environ.get("FAKE_SERVE_DOWNLOAD_SEC") or 12)
PAUSE_AT = int(os.environ["FAKE_SERVE_PAUSE_AT"]) if os.environ.get("FAKE_SERVE_PAUSE_AT") else None
FAIL = {n.strip() for n in (os.environ.get("FAKE_SERVE_FAIL") or "").split(",") if n.strip()}
CRASH_AFTER = int(os.environ["FAKE_SERVE_CRASH_AFTER"]) if os.environ.get("FAKE_SERVE_CRASH_AFTER") else None
OPS_LOG = os.environ.get("FAKE_SERVE_OPS_LOG")
CUE_FORMATS = {"srt", "vtt"}
EXPORT_DELAY = float(os.environ.get("FAKE_SERVE_EXPORT_DELAY") or 0)
ALIGN_SEC = float(os.environ.get("FAKE_SERVE_ALIGN_SEC") or 4)
ALIGN_FAIL = os.environ.get("FAKE_SERVE_ALIGN_FAIL")
EXPORT_FAIL = {f.strip() for f in (os.environ.get("FAKE_SERVE_EXPORT_FAIL") or "").split(",") if f.strip()}

out_lock = threading.Lock()


class AlignTask:
    """An `align` op waiting for (or on) the worker queue, like serve.py's AlignJob."""

    def __init__(self, op):
        self.id = op["id"]
        self.op = op
        self.cancelled = False


def send(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def log(message, level="info"):
    send({"event": "log", "level": level, "message": message})


# -- fixture -------------------------------------------------------------------------------


class Template:
    def __init__(self, job, events, outputs_dir):
        self.job = job
        self.name = pathlib.Path(job["input"]).name
        self.stem = pathlib.Path(job["input"]).stem
        self.events = events  # [(dt since accepted, msg)]
        self.done = next((m for _, m in events if m.get("event") == "file_done"), None)
        self.outputs = {}
        for p in outputs_dir.glob(self.stem + ".*") if outputs_dir.is_dir() else []:
            self.outputs[p.suffix[1:]] = p.read_text()

    @property
    def duration(self):
        return (self.done or {}).get("duration") or 0


def load_fixture(path):
    session = [json.loads(line) for line in open(path / "session.ndjson")]
    jobs, events, accepted_at = {}, {}, {}
    models = None
    for rec in session:
        msg = rec["msg"]
        if rec["dir"] == "in" and msg.get("op") == "enqueue":
            jobs[msg["job"]["id"]] = msg["job"]
        elif rec["dir"] == "out":
            if msg.get("event") == "models" and models is None:
                models = msg["models"]
            jid = msg.get("id")
            if jid in jobs:
                if msg.get("event") == "accepted":
                    accepted_at[jid] = rec["t"]
                    events[jid] = []
                elif jid in events:
                    events[jid].append((rec["t"] - accepted_at[jid], msg))
    templates = [Template(jobs[j], events[j], path / "outputs") for j in events]
    complete = [t for t in templates if t.done]
    # Pace each template from its own decode start: queued time in the recording isn't work.
    for t in templates:
        first = next((dt for dt, m in t.events if m.get("event") == "progress"), 0)
        t.events = [(max(dt - first, 0), m) for dt, m in t.events]
    return complete, models or []


# -- output writers --------------------------------------------------------------------------


def stamp(sec, sep=","):
    ms = int(round(sec * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02}:{m:02}:{s:02}{sep}{ms:03}"


def render(fmt, title, segments, timestamps):
    if fmt == "md":
        body = []
        for s in segments:
            mm, ss = divmod(int(s["start"]), 60)
            body.append((f"**[{mm:02}:{ss:02}]** " if timestamps else "") + s["text"])
        return f"# {title}\n\n" + "\n\n".join(body) + "\n"
    if fmt == "txt":
        return "\n\n".join(s["text"] for s in segments) + "\n"
    if fmt == "json":
        return json.dumps({"segments": segments}, ensure_ascii=False, indent=2) + "\n"
    cues = []
    for i, s in enumerate(segments, 1):
        sep = "," if fmt == "srt" else "."
        head = f"{i}\n" if fmt == "srt" else ""
        cues.append(f"{head}{stamp(s['start'], sep)} --> {stamp(s['end'], sep)}\n{s['text']}\n")
    return ("WEBVTT\n\n" if fmt == "vtt" else "") + "\n".join(cues)


def split_cues(seg):
    """Subtitle-sized cues for one segment: split at sentence punctuation, times by length."""
    parts = [p.strip() for p in re.split(r"(?<=[.!?。！？，,；;])\s*", seg["text"]) if p.strip()] or [seg["text"]]
    total = sum(len(p) for p in parts) or 1
    out, t = [], seg["start"]
    span = seg["end"] - seg["start"]
    for p in parts:
        end = t + span * len(p) / total
        out.append({"text": p, "start": round(t, 2), "end": round(end, 2), "speaker": None})
        t = end
    return out


def split_words(cue):
    tokens = cue["text"].split() if " " in cue["text"] else list(cue["text"])
    span = (cue["end"] - cue["start"]) / max(len(tokens), 1)
    return [{"text": w, "start": round(cue["start"] + i * span, 2), "end": round(cue["start"] + (i + 1) * span, 2)}
            for i, w in enumerate(tokens)]


def transcript_dict(src, segments, done, model_repo, duration, want_cues, cue_timing):
    """What `Transcript.to_dict()` gives the real worker, plus the source path."""
    cues = [c for s in segments for c in split_cues(s)] if want_cues else None
    return {
        "text": "\n\n".join(s["text"] for s in segments),
        "language": done.get("language"),
        "duration": duration,
        "backend": "mlx",
        "model": model_repo,
        "segments": [{"text": s["text"], "start": s["start"], "end": s["end"], "speaker": None} for s in segments],
        "cues": cues,
        "cue_timing": cue_timing if want_cues else None,
        "words": [w for c in cues for w in split_words(c)] if cues else None,
        "warnings": done.get("warnings", []),
        "notices": done.get("notices", []),
        "source": str(src),
    }


def write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def out_path(src, fmt, out_dir):
    base = pathlib.Path(out_dir).expanduser() if out_dir else src.parent
    return base / f"{src.stem}.{fmt}"


def probe_duration(path):
    try:
        r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                           capture_output=True, text=True, timeout=10)
        return float(r.stdout.strip())
    except Exception:
        return None


# -- worker ----------------------------------------------------------------------------------


class Cancelled(Exception):
    pass


class Job:
    def __init__(self, spec):
        self.spec = spec
        self.id = spec["id"]
        self.cancelled = False


class Fake:
    def __init__(self):
        fixture = pathlib.Path(os.environ.get("FAKE_SERVE_FIXTURE") or DEFAULT_FIXTURE)
        self.templates, catalog = load_fixture(fixture)
        self.models = {m["id"]: dict(m, loaded=False) for m in catalog}
        for item in (os.environ.get("FAKE_SERVE_MODELS") or "").split(","):
            if "=" in item:
                mid, status = item.split("=", 1)
                if mid in self.models:
                    m = self.models[mid]
                    m["status"] = status
                    m["bytes_on_disk"] = {"downloaded": m["size_bytes"], "partial": m["size_bytes"] // 3}.get(status, 0)
        self.cv = threading.Condition()
        self.pending = deque()
        self.current = None
        self.loaded = None  # catalog id of the loaded ASR model
        self.downloads = {}  # id -> threading.Event (cancel flag)
        self.idle_unload = 600.0
        self.last_active = time.monotonic()
        self.stopping = False
        self.turn = 0
        self.segments_sent = 0

    # ---- helpers

    def find(self, spec):
        if spec is None:
            return self.models.get("1.7b")
        key = str(spec).lower()
        for m in self.models.values():
            if key in (m["id"].lower(), m["repo"].lower()):
                return m
        return None

    def describe(self):
        return [dict(m) for m in self.models.values()]

    def sleep(self, seconds, flag=None):
        """Sleep `seconds` of recorded time; returns early (True) when flag() says stop."""
        end = time.monotonic() + seconds / SPEED
        with self.cv:
            while True:
                if self.stopping or (flag and flag()):
                    return True
                left = end - time.monotonic()
                if left <= 0:
                    return False
                self.cv.wait(left)

    # ---- ops (reader thread)

    def read(self):
        try:
            for raw in sys.stdin:
                raw = raw.strip()
                if not raw:
                    continue
                if OPS_LOG:
                    with open(OPS_LOG, "a") as f:
                        f.write(raw + "\n")
                try:
                    op = json.loads(raw)
                    name = op["op"]
                except (ValueError, KeyError, TypeError):
                    log("bad input line", "error")
                    continue
                handler = getattr(self, "op_" + name, None)
                if handler is None:
                    log(f"unknown op {name!r}", "error")
                else:
                    handler(op)
                if self.stopping:
                    return
        finally:
            self.shutdown()

    def op_enqueue(self, op):
        spec = op.get("job") or {}
        jid = spec.get("id")
        if not jid or not spec.get("input"):
            if jid:
                send({"id": jid, "event": "file_error", "error": 'job needs an "input" path'})
            else:
                log("enqueue rejected: job needs a non-empty string \"id\"", "error")
            return
        with self.cv:
            if any(j.id == jid for j in self.pending if isinstance(j, Job)) or (
                    isinstance(self.current, Job) and self.current.id == jid):
                log(f"enqueue rejected: job id {jid!r} is already queued or running", "error")
                return
            self.pending.append(Job(spec))
            send({"id": jid, "event": "accepted"})
            self.cv.notify_all()

    def op_export(self, op):
        """Formats from a transcript JSON, like serve.py's op_export (on the reader thread)."""
        rid = op.get("id")
        try:
            formats = op.get("formats") or []
            if not formats:
                raise ValueError('"formats" must be a non-empty list')
            data = json.loads(pathlib.Path(op["transcript"]).read_text())
            if EXPORT_DELAY:
                time.sleep(EXPORT_DELAY / SPEED)
            bad = [f for f in formats if f in EXPORT_FAIL]
            if bad:
                raise ValueError(f"cannot export {', '.join(bad)} (FAKE_SERVE_EXPORT_FAIL)")
            out_dir = pathlib.Path(op["output_dir"]).expanduser()
            title = (op.get("title") or pathlib.Path(data.get("source") or "transcript").stem).replace("/", "_")
            segments = data.get("segments") or []
            cues = data.get("cues")
            outputs = {}
            for fmt in formats:
                path = out_dir / f"{title}.{fmt}"
                if fmt == "json":
                    write_atomic(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")
                else:
                    rows = cues if fmt in CUE_FORMATS and cues else segments
                    write_atomic(path, render(fmt, title, rows, bool(op.get("timestamps"))))
                outputs[fmt] = str(path)
            send({"id": rid, "event": "exported", "outputs": outputs, "estimated_cues": cues is None})
        except Exception as e:  # noqa: BLE001 - every failure is an export_error, like the real worker
            send({"id": rid, "event": "export_error", "message": str(e)})

    def op_align(self, op):
        """Queues an align of a saved transcript (serve.py's op_align): real cue times replace estimated ones."""
        rid = op.get("id")
        if not isinstance(rid, str) or not rid:
            log('align needs a non-empty string "id"', "error")
            return
        for key in ("transcript", "source"):
            if not os.path.isabs(op.get(key) or ""):
                send({"id": rid, "event": "align_error", "message": f'"{key}" must be an absolute path'})
                return
        with self.cv:
            self.pending.append(AlignTask(op))
            send({"id": rid, "event": "accepted"})
            self.cv.notify_all()

    def run_align(self, task):
        op = task.op
        try:
            data = json.loads(pathlib.Path(op["transcript"]).read_text())
            if not os.path.exists(op["source"]):
                raise ValueError(f"cannot read {op['source']}: no such file")
            send({"id": task.id, "event": "progress", "stage": "decode", "progress": 0.0})
            segments = [s for s in data.get("segments") or [] if s.get("text")]
            if not segments:
                raise ValueError("nothing to align: the transcript has no text")
            for n in range(len(segments)):
                if self.sleep(ALIGN_SEC / len(segments), lambda: task.cancelled):
                    send({"id": task.id, "event": "align_error", "message": "cancelled", "cancelled": True})
                    return
                send({"id": task.id, "event": "progress", "stage": "align", "progress": (n + 1) / len(segments),
                      "chunk": n + 1, "total_chunks": len(segments)})
            if ALIGN_FAIL:
                raise ValueError(ALIGN_FAIL)
            cues = [c for s in segments for c in split_cues(s)]
            drop = {"timing_estimated", "alignment_failed"}
            notices = [n for n in data.get("notices") or [] if n.get("code") not in drop]
            data.update(cues=cues, cue_timing="aligned", words=[w for c in cues for w in split_words(c)], notices=notices,
                        warnings=[n["message"] for n in notices])
            out = pathlib.Path(op.get("output") or op["transcript"])
            write_atomic(out, json.dumps(data, ensure_ascii=False, indent=2) + "\n")
            send({"id": task.id, "event": "aligned", "transcript": str(out), "cue_timing": "aligned", "notices": notices})
        except Exception as e:  # noqa: BLE001 - every failure is an align_error, like the real worker
            send({"id": task.id, "event": "align_error", "message": str(e)})

    def op_cancel(self, op):
        jid = op.get("id")
        with self.cv:
            for j in list(self.pending):
                if isinstance(j, AlignTask) and j.id == jid:
                    self.pending.remove(j)
                    send({"id": jid, "event": "align_error", "message": "cancelled", "cancelled": True})
                    return
                if isinstance(j, Job) and j.id == jid:
                    self.pending.remove(j)
                    send({"id": jid, "event": "file_stopped", "stopped_at": 0.0})
                    return
            if isinstance(self.current, AlignTask) and self.current.id == jid:
                self.current.cancelled = True
                self.cv.notify_all()
                return
            if isinstance(self.current, Job) and self.current.id == jid:
                self.current.cancelled = True
                self.cv.notify_all()
                return
        log(f"cancel: no queued or running job {jid!r}")

    def op_cancel_all(self, op):
        self.cancel_everything()

    def cancel_everything(self):
        with self.cv:
            for j in list(self.pending):
                if isinstance(j, Job):
                    send({"id": j.id, "event": "file_stopped", "stopped_at": 0.0})
                elif isinstance(j, AlignTask):
                    send({"id": j.id, "event": "align_error", "message": "cancelled", "cancelled": True})
            self.pending.clear()
            if isinstance(self.current, (Job, AlignTask)):
                self.current.cancelled = True
            for flag in self.downloads.values():
                flag.set()
            self.cv.notify_all()

    def op_shutdown(self, op):
        self.shutdown()

    def shutdown(self):
        with self.cv:
            self.stopping = True
        self.cancel_everything()

    def op_configure(self, op):
        value = op.get("idle_unload_sec")
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
            log('configure: "idle_unload_sec" must be a number >= 0', "error")
            return
        with self.cv:
            self.idle_unload = float(value)
            self.cv.notify_all()
        send({"event": "configured", "idle_unload_sec": float(value)})

    def op_models(self, op):
        send({"event": "models", "models": self.describe()})

    def resolve(self, op):
        m = self.find(op.get("model")) if isinstance(op.get("model"), str) else None
        if m is None:
            send({"event": "model_error", "model": op.get("model"), "error": f"unknown model {op.get('model')!r}"})
        return m

    def op_preload(self, op):
        m = self.find(op.get("model"))
        if m is None:
            send({"event": "model_error", "model": op.get("model"), "error": f"unknown model {op.get('model')!r}"})
            return
        with self.cv:
            self.pending.append(("preload", m))
            self.cv.notify_all()

    def op_download(self, op):
        m = self.resolve(op)
        if m is None:
            return
        with self.cv:
            if m["id"] in self.downloads:
                send({"event": "model_error", "model": m["id"], "error": "already downloading"})
                return
            flag = self.downloads[m["id"]] = threading.Event()
        threading.Thread(target=self.download_thread, args=(m, flag), daemon=True).start()

    def download_thread(self, m, flag):
        try:
            self.download(m, flag.is_set, lambda e: send({**e, "model": m["id"], "repo": m["repo"]}))
            send({"event": "model_ready", "model": m["id"]})
        except Cancelled:
            send({"event": "model_error", "model": m["id"], "error": "cancelled", "cancelled": True})
        finally:
            with self.cv:
                self.downloads.pop(m["id"], None)

    def download(self, m, stop, emit):
        """Fill the fake cache for `m`, emitting progress like download.py. Raises Cancelled."""
        if m["status"] == "downloaded":
            return
        total = m["size_bytes"]
        done = m["bytes_on_disk"]
        step = total / max(DOWNLOAD_SEC * 4, 1)
        while done < total:
            emit({"event": "progress", "stage": "download", "progress": round(done / total, 4),
                  "model_id": m["id"], "downloaded_bytes": int(done), "total_bytes": total})
            if self.sleep(0.25 * SPEED, stop):  # wall-clock 0.25 s per step regardless of SPEED
                m["bytes_on_disk"] = int(done)
                m["status"] = "partial" if done > 0 else "not_downloaded"
                raise Cancelled()
            done = min(done + step * SPEED, total)
            m["bytes_on_disk"] = int(done)
            m["status"] = "partial"
        emit({"event": "progress", "stage": "download", "progress": 1.0, "model_id": m["id"],
              "downloaded_bytes": total, "total_bytes": total})
        m["status"], m["bytes_on_disk"] = "downloaded", total

    def op_cancel_download(self, op):
        m = self.resolve(op)
        if m is None:
            return
        with self.cv:
            flag = self.downloads.get(m["id"])
        if flag is None:
            send({"event": "model_error", "model": m["id"], "error": "not downloading"})
        else:
            flag.set()
            with self.cv:
                self.cv.notify_all()

    def op_remove_model(self, op):
        m = self.resolve(op)
        if m is None:
            return
        with self.cv:
            if m["id"] in self.downloads:
                send({"event": "model_error", "model": m["id"], "error": "is downloading"})
                return
            if self.loaded == m["id"]:
                if self.current is not None:
                    send({"event": "model_error", "model": m["id"], "error": "model is in use"})
                    return
                self.pending.append(("remove", m))
                self.cv.notify_all()
                return
        self.remove(m)

    def remove(self, m):
        freed = m["bytes_on_disk"]
        m["status"], m["bytes_on_disk"], m["loaded"] = "not_downloaded", 0, False
        send({"event": "model_removed", "model": m["id"], "freed_bytes": freed})
        self.op_models({})

    # ---- worker (main thread)

    def work(self):
        while True:
            task = self.next_task()
            if task is None:
                break
            with self.cv:
                self.current = task
            try:
                if isinstance(task, Job):
                    self.run_job(task)
                elif isinstance(task, AlignTask):
                    self.run_align(task)
                elif task[0] == "preload":
                    self.run_preload(task[1])
                else:
                    self.unload("remove")
                    self.remove(task[1])
            finally:
                with self.cv:
                    self.current = None
                    self.last_active = time.monotonic()
                    drained = not self.pending
                if drained and not self.stopping and self.loaded:
                    send({"event": "idle"})
        self.unload("shutdown")

    def next_task(self):
        while True:
            with self.cv:
                if self.stopping:
                    return None
                if self.pending:
                    return self.pending.popleft()
                remaining = None
                if self.loaded and self.idle_unload > 0:
                    remaining = self.last_active + self.idle_unload - time.monotonic()
                if remaining is None or remaining > 0:
                    self.cv.wait(remaining)
                    continue
            self.unload("idle")

    def unload(self, reason):
        if not self.loaded:
            return
        m = self.models[self.loaded]
        m["loaded"] = False
        self.loaded = None
        send({"event": "unloaded", "model": m["repo"], "reason": reason})

    def switch_to(self, m, emit, stop, recorded_load=1.0):
        if self.loaded and self.loaded != m["id"]:
            self.unload("switch")
        if self.loaded == m["id"]:
            return
        self.download(m, stop, lambda e: emit({**e, "model": m["repo"]}))
        emit({"event": "progress", "stage": "load", "progress": 0.0})
        if self.sleep(recorded_load, stop):
            raise Cancelled()
        emit({"event": "progress", "stage": "load", "progress": 1.0})
        self.loaded = m["id"]
        m["loaded"] = True

    def run_preload(self, m):
        flag = threading.Event()
        with self.cv:
            self.downloads[m["id"]] = flag
        try:
            self.switch_to(m, send, flag.is_set, 3.0)
            send({"event": "model_ready", "model": m["id"]})
        except Cancelled:
            send({"event": "model_error", "model": m["id"], "error": "cancelled", "cancelled": True})
        finally:
            with self.cv:
                self.downloads.pop(m["id"], None)

    def pick(self, src):
        for t in self.templates:
            if t.name == src.name:
                return t
        t = self.templates[self.turn % len(self.templates)]
        self.turn += 1
        return t

    def run_job(self, job):
        spec = job.spec
        jid = job.id

        def ev(e):
            send({"id": jid, **{k: v for k, v in e.items() if k != "id"}})

        def stop():
            return job.cancelled or self.stopping

        src = pathlib.Path(spec["input"]).expanduser()
        transcript_path = spec.get("transcript_path")
        raw_formats = spec.get("formats")
        if raw_formats is None or (not raw_formats and not transcript_path):
            raw_formats = ["md"]
        formats = list(dict.fromkeys(f.lower() for f in raw_formats))
        written = []
        reached = 0.0
        try:
            targets = {f: out_path(src, f, spec.get("output_dir")) for f in formats}
            if not spec.get("overwrite"):
                existing = [str(p) for p in targets.values() if p.exists()]
                if existing:
                    raise FileExistsError(f"output exists (use overwrite): {', '.join(existing)}")
            m = self.find(spec.get("model"))
            if m is None:
                raise ValueError(f"unknown model {spec.get('model')!r}")
            ev({"event": "progress", "stage": "decode", "progress": 0.0})
            if not src.exists():
                raise FileNotFoundError(f"no such file: {src}")
            if src.name in FAIL:
                raise RuntimeError(f"ffmpeg could not decode {src.name}: Invalid data found when processing input")
            t = self.pick(src)
            real = probe_duration(src)
            scale = (real / t.duration) if real and t.duration else 1.0

            def sc(v):
                return round(v * scale, 2)

            events = t.events
            load_dts = [dt for dt, e in events if e.get("stage") == "load"]
            load_time = (load_dts[-1] - load_dts[0]) if len(load_dts) == 2 else 1.0
            if self.sleep(0.25, stop):
                raise Cancelled()
            self.switch_to(m, ev, stop, load_time)
            # Replay from the end of loading.
            start_at = load_dts[-1] if load_dts else 0
            clock = start_at
            segments = []
            want_cues = bool(CUE_FORMATS & set(formats)) or bool(spec.get("align"))
            for dt, e in events:
                if dt < start_at or e.get("event") in ("accepted", "file_done", "file_stopped", "file_error"):
                    continue
                if e.get("event") == "progress" and e.get("stage") in ("decode", "load", "download"):
                    continue
                if e.get("event") == "progress" and e.get("stage") == "align" and not want_cues:
                    continue
                if self.sleep(dt - clock, stop if not segments else None) and stop() and not segments:
                    raise Cancelled()
                clock = dt
                if e.get("event") == "segment":
                    seg = {"start": sc(e["start"]), "end": sc(e["end"]), "text": e["text"]}
                    segments.append(seg)
                    reached = seg["end"]
                    ev({**e, "start": seg["start"], "end": seg["end"]})
                    self.segments_sent += 1
                    if CRASH_AFTER is not None and self.segments_sent >= CRASH_AFTER:
                        os._exit(1)
                    if PAUSE_AT is not None and len(segments) >= PAUSE_AT:
                        while not self.sleep(3600, stop):
                            pass
                    if stop():
                        raise Cancelled()
                else:
                    ev(e)
            if stop():
                raise Cancelled()
            done = t.done
            outputs = {}
            for fmt, path in targets.items():
                path.parent.mkdir(parents=True, exist_ok=True)
                text = t.outputs.get(fmt) if scale == 1.0 else None
                path.write_text(text or render(fmt, src.stem, segments, bool(spec.get("timestamps"))))
                written.append(path)
                outputs[fmt] = str(path)
            cue_timing = (done.get("cue_timing") or "aligned") if want_cues else None
            extra = {}
            if transcript_path:
                tp = pathlib.Path(transcript_path).expanduser()
                write_atomic(tp, json.dumps(transcript_dict(src, segments, done, m["repo"], sc(done.get("duration") or 0),
                                                            want_cues, cue_timing), ensure_ascii=False, indent=2) + "\n")
                written.append(tp)
                extra["transcript"] = str(tp)
            ev({
                "event": "file_done", "outputs": outputs, **extra,
                "elapsed": round(done.get("elapsed", 0) / SPEED, 2), "language": done.get("language"),
                "duration": sc(done.get("duration") or 0), "model": m["repo"],
                "cue_timing": cue_timing,
                "warnings": done.get("warnings", []), "notices": done.get("notices", []),
                "segments": segments,
            })
        except Cancelled:
            for p in written:
                p.unlink(missing_ok=True)
            ev({"event": "file_stopped", "stopped_at": round(reached, 2)})
        except Exception as exc:
            for p in written:
                p.unlink(missing_ok=True)
            ev({"event": "file_error", "error": str(exc) or type(exc).__name__})


def main():
    args = sys.argv[1:]
    if args[:1] in (["doctor"], ["backends"]):
        # The environment checks come from the batch-mode fake.
        os.execv(str(HERE / "fake-transcribe.sh"), [str(HERE / "fake-transcribe.sh"), *args])
    if args[:1] != ["serve"]:
        print("fake-serve.py only implements `serve`", file=sys.stderr)
        return 2
    fake = Fake()
    signal.signal(signal.SIGTERM, lambda *_: fake.shutdown())
    signal.signal(signal.SIGINT, lambda *_: fake.shutdown())
    threading.Thread(target=fake.read, daemon=True).start()
    fake.work()
    return 0


if __name__ == "__main__":
    sys.exit(main())
