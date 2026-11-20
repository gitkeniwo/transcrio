"""`transcribe serve`: a resident worker that speaks NDJSON on stdin/stdout.

One process keeps the model in memory between jobs. A reader thread parses ops from stdin and
answers the cheap ones at once (cancel, configure, models, export, ...); everything that touches the
model (load, transcribe, align, unload) runs on the main thread, one job at a time, because MLX streams
belong to the thread that created them. Downloads started with the `download` op run on their own
thread so they do not hold up transcription.

stdout carries events and nothing else: at start-up file descriptor 1 is pointed at stderr, so a
stray `print` or progress bar from any library cannot corrupt the stream, and the events go out
through a private copy of the original stdout.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import threading
import time
from collections import deque
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, TextIO

from . import backends, models
from .audio import load_audio
from .backends.base import Backend
from .exporters import CUE_FORMATS, EXPORTERS, ExportOptions, export_transcript, out_path, render, to_json, write_text
from .languages import normalize
from .pipeline import transcribe_audio
from .types import Cancelled, ChunkResult, TranscribeRequest

DEFAULT_IDLE_UNLOAD = 300.0
BackendFactory = Callable[[str | None], Backend]


def _default_factory(model: str | None) -> Backend:
    return backends.create(backends.DEFAULT_BACKEND, model)


@dataclass
class Job:
    id: str
    input: Path
    formats: list[str]
    output_dir: Path | None
    timestamps: bool
    language: str | None
    context: str
    overwrite: bool
    model: str | None
    align: bool = False  # subtitle cues (forced alignment) even when no srt/vtt is asked for
    transcript_path: Path | None = None  # where the master transcript JSON goes, if wanted
    cancelled: bool = False
    written: list[Path] = field(default_factory=list)


@dataclass
class AlignJob:
    """Re-time a saved transcript with the forced aligner (the `align` op)."""

    id: str
    transcript: Path
    source: Path
    output: Path
    cancelled: bool = False


@dataclass
class Preload:
    model: str | None
    info: models.ModelInfo | None


@dataclass
class Remove:
    info: models.ModelInfo


class Server:
    def __init__(self, out: TextIO, idle_unload: float, factory: BackendFactory) -> None:
        self._out = out
        self._write_lock = threading.Lock()
        self._cv = threading.Condition()
        self._pending: deque[Job | AlignJob | Preload | Remove] = deque()
        self._current: Job | AlignJob | Preload | None = None
        self._stopping = False
        self._idle_unload = idle_unload
        self._factory = factory
        self._backend: Backend | None = None
        self._last_active = time.monotonic()
        self._downloads: dict[str, threading.Event] = {}  # model id -> cancel flag
        self._reported_loaded: frozenset[str] = frozenset()  # catalog repos last reported as loaded

    # -- output ---------------------------------------------------------------------------

    def send(self, event: dict[str, Any]) -> None:
        line = json.dumps(event, ensure_ascii=False, allow_nan=False)
        try:
            with self._write_lock:
                self._out.write(line + "\n")
                self._out.flush()
        except (BrokenPipeError, ValueError, OSError):
            self.shutdown()  # nobody is listening any more

    def log(self, message: str, level: str = "info") -> None:
        self.send({"event": "log", "level": level, "message": message})
        print(f"transcribe serve: {message}", file=sys.stderr, flush=True)

    # -- input (reader thread) ------------------------------------------------------------

    def read(self, lines: Iterable[str]) -> None:
        try:
            for raw in lines:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    op = json.loads(raw)
                    if not isinstance(op, dict) or not isinstance(op.get("op"), str):
                        raise ValueError('expected an object with a string "op"')
                except ValueError as exc:
                    self.log(f"bad input line: {exc}", "error")
                    continue
                try:
                    self.dispatch(op)
                except Exception as exc:  # a bad op must never take the worker down
                    self.log(f"op {op['op']!r} failed: {exc}", "error")
                if self._stopping:
                    return
        finally:
            self.shutdown()  # stdin EOF

    def dispatch(self, op: dict[str, Any]) -> None:
        name = op["op"]
        handler = getattr(self, f"op_{name}", None)
        if handler is None:
            self.log(f"unknown op {name!r}", "error")
        else:
            handler(op)

    def op_enqueue(self, op: dict[str, Any]) -> None:
        spec = op.get("job")
        job_id = spec.get("id") if isinstance(spec, dict) else None
        try:
            job = self._parse_job(spec)
        except ValueError as exc:
            if isinstance(job_id, str) and job_id:
                self.send({"id": job_id, "event": "file_error", "error": str(exc)})
            else:
                self.log(f"enqueue rejected: {exc}", "error")
            return
        with self._cv:
            if self._stopping:
                return
            if self._busy_with(job.id):
                self.log(f"enqueue rejected: job id {job.id!r} is already queued or running", "error")
                return
            self._pending.append(job)
            self.send({"id": job.id, "event": "accepted"})
            self._cv.notify_all()

    def _busy_with(self, job_id: str) -> bool:
        """Whether a job or align with this id is queued or running. Call with `_cv` held."""
        return any(isinstance(j, (Job, AlignJob)) and j.id == job_id for j in self._pending) or (
            isinstance(self._current, (Job, AlignJob)) and self._current.id == job_id
        )

    def op_align(self, op: dict[str, Any]) -> None:
        """Queue a forced-alignment pass over a saved transcript. It needs the aligner model, so it
        runs on the worker like a job: replies `accepted`, progress, then `aligned` or `align_error`."""
        req_id = op.get("id")
        if not isinstance(req_id, str) or not req_id:
            self.log('align needs a non-empty string "id"', "error")
            return
        paths: dict[str, Path] = {}
        for key in ("transcript", "source", "output"):
            value = op.get(key, op.get("transcript") if key == "output" else None)
            if not isinstance(value, str) or not value or not Path(value).expanduser().is_absolute():
                self.send({"event": "align_error", "id": req_id, "message": f'"{key}" must be an absolute path'})
                return
            paths[key] = Path(value).expanduser()
        task = AlignJob(req_id, paths["transcript"], paths["source"], paths["output"])
        with self._cv:
            if self._stopping:
                return
            if self._busy_with(req_id):
                self.send({"event": "align_error", "id": req_id, "message": f"id {req_id!r} is already queued or running"})
                return
            self._pending.append(task)
            self.send({"id": req_id, "event": "accepted"})
            self._cv.notify_all()

    @staticmethod
    def _parse_job(spec: Any) -> Job:
        if not isinstance(spec, dict):
            raise ValueError('enqueue needs a "job" object')
        job_id, src = spec.get("id"), spec.get("input")
        if not isinstance(job_id, str) or not job_id:
            raise ValueError('job needs a non-empty string "id"')
        if not isinstance(src, str) or not src:
            raise ValueError('job needs an "input" path')
        transcript_path = spec.get("transcript_path")
        if transcript_path is not None and (
            not isinstance(transcript_path, str) or not Path(transcript_path).expanduser().is_absolute()
        ):
            raise ValueError('"transcript_path" must be an absolute path')
        formats = spec.get("formats")
        if formats is None or (formats == [] and transcript_path is None):
            formats = ["md"]
        if not isinstance(formats, list) or not all(isinstance(f, str) for f in formats):
            raise ValueError('"formats" must be a list of strings')
        formats = list(dict.fromkeys(f.lower() for f in formats))
        bad = [f for f in formats if f not in EXPORTERS]
        if bad:
            raise ValueError(f"unknown format(s) {bad}; choose from {', '.join(EXPORTERS)}")
        out_dir = spec.get("output_dir")
        model = spec.get("model")
        language, context = spec.get("language"), spec.get("context") or ""
        if (out_dir is not None and not isinstance(out_dir, str)) or (
            model is not None and not isinstance(model, str)
        ) or (language is not None and not isinstance(language, str)) or not isinstance(context, str):
            raise ValueError('"output_dir", "model", "language" and "context" must be strings')
        if model is not None:
            known = models.find(model)
            if known is not None and known.kind != "asr":
                raise ValueError(f"{model!r} is not a speech-recognition model")
        return Job(
            id=job_id,
            input=Path(src).expanduser(),
            formats=formats,
            output_dir=Path(out_dir).expanduser() if out_dir else None,
            timestamps=bool(spec.get("timestamps", False)),
            language=normalize(language),
            context=context,
            overwrite=bool(spec.get("overwrite", False)),
            model=model or None,
            align=bool(spec.get("align", False)),
            transcript_path=Path(transcript_path).expanduser() if transcript_path else None,
        )

    def op_export(self, op: dict[str, Any]) -> None:
        """Render formats from a saved transcript. Runs right here on the reader thread: no model is
        involved, so it never waits for a job, a model load or a download."""
        req_id = op.get("id")
        if not isinstance(req_id, str) or not req_id:
            self.log('export needs a non-empty string "id"', "error")
            return
        try:
            src, formats, out_dir, title = op.get("transcript"), op.get("formats"), op.get("output_dir"), op.get("title")
            if not isinstance(src, str) or not src:
                raise ValueError('export needs a "transcript" path')
            if not isinstance(formats, list) or not formats or not all(isinstance(f, str) for f in formats):
                raise ValueError('"formats" must be a non-empty list of strings')
            if not isinstance(out_dir, str) or not out_dir:
                raise ValueError('export needs an "output_dir"')
            if title is not None and not isinstance(title, str):
                raise ValueError('"title" must be a string')
            result = export_transcript(
                Path(src).expanduser(),
                [f.lower() for f in formats],
                Path(out_dir).expanduser(),
                timestamps=bool(op.get("timestamps", False)),
                title=title or None,
            )
        except Exception as exc:
            self.send({"event": "export_error", "id": req_id, "message": str(exc) or type(exc).__name__})
            return
        self.send({
            "event": "exported", "id": req_id,
            "outputs": {fmt: str(path) for fmt, path in result.outputs.items()},
            "estimated_cues": result.estimated_cues,
        })  # fmt: skip

    def op_cancel(self, op: dict[str, Any]) -> None:
        job_id = op.get("id")
        with self._cv:
            for item in list(self._pending):
                if isinstance(item, (Job, AlignJob)) and item.id == job_id:
                    self._pending.remove(item)
                    self._send_stopped(item)
                    return
            if isinstance(self._current, (Job, AlignJob)) and self._current.id == job_id:
                self._current.cancelled = True
                self._cv.notify_all()
                return
        self.log(f"cancel: no queued or running job {job_id!r}")

    def op_cancel_all(self, op: dict[str, Any]) -> None:
        self._cancel_everything()

    def _cancel_everything(self) -> None:
        with self._cv:
            for item in list(self._pending):
                if isinstance(item, (Job, AlignJob)):
                    self._send_stopped(item)
            self._pending.clear()
            if isinstance(self._current, (Job, AlignJob)):
                self._current.cancelled = True
            for flag in self._downloads.values():
                flag.set()
            self._cv.notify_all()

    def _send_stopped(self, item: Job | AlignJob) -> None:
        if isinstance(item, AlignJob):
            self.send({"event": "align_error", "id": item.id, "message": "cancelled", "cancelled": True})
        else:
            self.send({"id": item.id, "event": "file_stopped", "stopped_at": 0.0})

    def op_shutdown(self, op: dict[str, Any]) -> None:
        self.shutdown()

    def shutdown(self) -> None:
        with self._cv:
            self._stopping = True
        self._cancel_everything()

    def op_configure(self, op: dict[str, Any]) -> None:
        value = op.get("idle_unload_sec")
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
            self.log('configure: "idle_unload_sec" must be a number >= 0', "error")
            return
        with self._cv:
            self._idle_unload = float(value)
            self._cv.notify_all()
        self.send({"event": "configured", "idle_unload_sec": float(value)})

    def op_models(self, op: dict[str, Any]) -> None:
        loaded = self._loaded_catalog_repos()
        self._reported_loaded = loaded
        self.send({"event": "models", "models": models.describe_all(loaded)})

    def _loaded_catalog_repos(self) -> frozenset[str]:
        backend = self._backend
        repos = frozenset(backend.loaded_repos()) if backend else frozenset()
        return repos & {m.repo for m in models.catalog()}

    def _report_loaded(self) -> None:
        """Send `models` when a catalog model (the ASR model or the aligner) was loaded or unloaded."""
        if self._loaded_catalog_repos() != self._reported_loaded:
            self.op_models({})

    def _resolve(self, op: dict[str, Any]) -> models.ModelInfo | None:
        spec = op.get("model")
        info = models.find(spec) if isinstance(spec, str) else None
        if info is None:
            self.send({"event": "model_error", "model": spec, "error": f"unknown model {spec!r}"})
        return info

    def op_preload(self, op: dict[str, Any]) -> None:
        spec = op.get("model")
        info = models.find(spec) if isinstance(spec, str) else None
        if spec is not None and info is None and not isinstance(spec, str):
            self.send({"event": "model_error", "model": spec, "error": "model must be a string"})
            return
        if info is not None and info.kind != "asr":
            self.send({"event": "model_error", "model": info.id, "error": "not a speech-recognition model"})
            return
        with self._cv:
            if not self._stopping:
                self._pending.append(Preload(spec, info))
                self._cv.notify_all()

    def op_download(self, op: dict[str, Any]) -> None:
        info = self._resolve(op)
        if info is None:
            return
        with self._cv:
            if info.id in self._downloads:
                self.send({"event": "model_error", "model": info.id, "error": "already downloading"})
                return
            flag = self._downloads[info.id] = threading.Event()
        threading.Thread(target=self._download, args=(info, flag), daemon=True).start()

    def _download(self, info: models.ModelInfo, flag: threading.Event) -> None:
        def emit(e: dict[str, Any]) -> None:
            self.send({**e, "model": info.id, "repo": info.repo} if e.get("stage") == "download" else e)

        try:
            models.download(info, emit, flag.is_set)
            self.send({"event": "model_ready", "model": info.id})
        except Cancelled:
            self.send({"event": "model_error", "model": info.id, "error": "cancelled", "cancelled": True})
        except Exception as exc:
            self.send({"event": "model_error", "model": info.id, "error": str(exc)})
        finally:
            with self._cv:
                self._downloads.pop(info.id, None)

    def op_cancel_download(self, op: dict[str, Any]) -> None:
        info = self._resolve(op)
        if info is None:
            return
        with self._cv:
            flag = self._downloads.get(info.id)
        if flag is None:
            self.send({"event": "model_error", "model": info.id, "error": "not downloading"})
        else:
            flag.set()

    def op_remove_model(self, op: dict[str, Any]) -> None:
        info = self._resolve(op)
        if info is None:
            return
        with self._cv:
            if info.id in self._downloads:
                self.send({"event": "model_error", "model": info.id, "error": "is downloading"})
                return
            backend = self._backend
            if backend is not None and info.repo in backend.loaded_repos():
                if self._current is not None:
                    self.send({"event": "model_error", "model": info.id, "error": "model is in use"})
                    return
                self._pending.append(Remove(info))  # the worker unloads it first
                self._cv.notify_all()
                return
        self._remove(info)

    def _remove(self, info: models.ModelInfo) -> None:
        try:
            freed = models.remove(info)
        except Exception as exc:
            self.send({"event": "model_error", "model": info.id, "error": str(exc)})
            return
        self.send({"event": "model_removed", "model": info.id, "freed_bytes": freed})
        self.op_models({})

    # -- worker (main thread) -------------------------------------------------------------

    def work(self) -> None:
        while True:
            task = self._next_task()
            if task is None:
                break
            with self._cv:
                self._current = task
            try:
                if isinstance(task, Job):
                    self._run_job(task)
                elif isinstance(task, AlignJob):
                    self._run_align(task)
                elif isinstance(task, Preload):
                    self._run_preload(task)
                else:
                    self._unload("remove", only=task.info.repo)
                    self._remove(task.info)
            finally:
                with self._cv:
                    self._current = None
                    self._last_active = time.monotonic()
                    drained = not self._pending
                # After a job always (even one that ended before a model was loaded), after a
                # preload only when it left a model in memory.
                loaded = self._backend is not None and self._backend.loaded
                if drained and not self._stopping and (isinstance(task, (Job, AlignJob)) or loaded):
                    self.send({"event": "idle"})
        self._unload("shutdown")

    def _next_task(self) -> Job | AlignJob | Preload | Remove | None:
        """Block for the next task; unload the model once it has been idle too long."""
        while True:
            with self._cv:
                if self._stopping:
                    return None
                if self._pending:
                    return self._pending.popleft()
                remaining = None
                if self._backend is not None and self._backend.loaded_repos() and self._idle_unload > 0:
                    remaining = self._last_active + self._idle_unload - time.monotonic()
                if remaining is None or remaining > 0:
                    self._cv.wait(remaining)
                    continue
            self._unload("idle")

    def _unload(self, reason: str, only: str | None = None) -> None:
        backend = self._backend
        if backend is None:
            return
        repos = backend.loaded_repos()
        if only is not None and only not in repos:
            return
        model = backend.model_id
        self._backend = None
        if repos:
            backend.unload()
            self.send({"event": "unloaded", "model": model, "reason": reason})
            self._report_loaded()

    def _switch_to(self, model: str | None) -> Backend:
        """The backend for `model`; the previously loaded one is unloaded first (one model at a time)."""
        wanted = self._factory(model)
        current = self._backend
        if current is not None and (current.info.name, current.model_id) != (wanted.info.name, wanted.model_id):
            self._unload("switch")
            current = None
        if current is None:
            self._backend = wanted
        assert self._backend is not None
        return self._backend

    def _run_preload(self, task: Preload) -> None:
        name = task.info.id if task.info else (task.model or "default")
        flag = threading.Event()
        with self._cv:
            self._downloads[name] = flag
        stop = lambda: flag.is_set() or self._stopping  # noqa: E731
        try:
            backend = self._switch_to(task.model)
            if not backend.loaded:
                self.send({"event": "progress", "stage": "load", "progress": 0.0})
                backend.load(self.send, stop)
                self.send({"event": "progress", "stage": "load", "progress": 1.0})
            self.send({"event": "model_ready", "model": name})
            self._report_loaded()
        except Cancelled:
            self.send({"event": "model_error", "model": name, "error": "cancelled", "cancelled": True})
        except Exception as exc:
            self.send({"event": "model_error", "model": name, "error": str(exc)})
        finally:
            with self._cv:
                self._downloads.pop(name, None)

    def _run_align(self, task: AlignJob) -> None:
        from .pipeline import align_saved

        def ev(event: dict[str, Any]) -> None:
            self.send({"id": task.id, **event})
            if event.get("event") == "progress" and event.get("stage") != "download":
                self._report_loaded()  # the aligner loads on the first segment

        try:
            # Only the aligner is needed: keep whatever backend is in memory rather than switching
            # (and unloading) for the transcript's model; the ASR weights are never loaded here.
            backend = self._backend or self._switch_to(None)
            transcript = align_saved(
                backend, task.transcript, task.source, task.output,
                on_progress=ev, should_cancel=lambda: task.cancelled or self._stopping,
            )  # fmt: skip
        except Cancelled:
            self.send({"event": "align_error", "id": task.id, "message": "cancelled", "cancelled": True})
            return
        except Exception as exc:
            self.send({"event": "align_error", "id": task.id, "message": str(exc) or type(exc).__name__})
            return
        self.send({
            "event": "aligned", "id": task.id, "transcript": str(task.output),
            "cue_timing": transcript.cue_timing, "notices": [asdict(n) for n in transcript.notices],
        })  # fmt: skip

    def _run_job(self, job: Job) -> None:
        downloading: list[dict[str, Any]] = []  # the model download in progress, if any

        def ev(event: dict[str, Any]) -> None:
            self.send({"id": job.id, **event})
            if event.get("event") == "progress":
                if event.get("stage") == "download" and (event.get("progress") or 0) < 1:
                    downloading[:] = [event]
                else:
                    downloading.clear()
                    self._report_loaded()  # e.g. the aligner, which loads mid-job on the first srt/vtt chunk

        def stop() -> bool:
            return job.cancelled or self._stopping

        started = time.monotonic()
        try:
            targets = {f: out_path(job.input, f, job.output_dir) for f in job.formats}
            if not job.overwrite:
                existing = [str(p) for p in targets.values() if p.exists()]
                if existing:
                    raise FileExistsError(f"output exists (use overwrite): {', '.join(existing)}")
            if stop():
                raise Cancelled(0.0)

            ev({"event": "progress", "stage": "decode", "progress": 0.0})
            audio = load_audio(job.input, stop)
            backend = self._switch_to(job.model)
            if not backend.loaded:
                ev({"event": "progress", "stage": "load", "progress": 0.0})
                backend.load(ev, stop)
                ev({"event": "progress", "stage": "load", "progress": 1.0})

            def on_chunk(chunk: ChunkResult, total: int) -> None:
                ev({
                    "event": "segment", "index": chunk.index + 1, "total_chunks": total,
                    "start": round(chunk.start, 2), "end": round(chunk.end, 2),
                    "text": chunk.text.strip(), "language": chunk.language,
                })  # fmt: skip

            request = TranscribeRequest(
                language=job.language,
                context=job.context,
                want_cues=job.align or bool(CUE_FORMATS & set(job.formats)),
                on_progress=ev,
            )
            transcript = transcribe_audio(
                backend, audio, request, interleave_align=True, on_chunk=on_chunk, should_cancel=stop
            )
            opts = ExportOptions(timestamps=job.timestamps, title=job.input.stem, source=job.input.name)
            rendered = {fmt: render(fmt, transcript, opts) for fmt in targets}
            master = to_json(transcript, opts) if job.transcript_path else None
            if stop():
                raise Cancelled(transcript.duration)
            done: dict[str, Any] = {}
            if job.transcript_path is not None and master is not None:
                job.transcript_path.parent.mkdir(parents=True, exist_ok=True)
                done["transcript"] = str(write_text(master, job.transcript_path))
                job.written.append(job.transcript_path)
            outputs: dict[str, str] = {}
            for fmt, path in targets.items():
                path.parent.mkdir(parents=True, exist_ok=True)
                outputs[fmt] = str(write_text(rendered[fmt], path))
                job.written.append(path)

            from .cli import segments_payload

            ev({
                "event": "file_done", "outputs": outputs,
                "elapsed": round(time.monotonic() - started, 2),
                "language": transcript.language, "duration": round(transcript.duration, 2),
                "model": transcript.model, "cue_timing": transcript.cue_timing,
                "warnings": transcript.warnings, "notices": [asdict(n) for n in transcript.notices],
                "segments": segments_payload(transcript), **done,
            })  # fmt: skip
        except Cancelled as stopped:
            for path in job.written:
                path.unlink(missing_ok=True)
            if downloading:  # tell the Models window too: the download it shows has stopped
                dl = downloading[0]
                known = models.find(str(dl.get("model_id") or dl.get("model") or ""))
                self.send({"event": "model_error", "model": known.id if known else dl.get("model"),
                           "error": "cancelled", "cancelled": True})  # fmt: skip
            ev({"event": "file_stopped", "stopped_at": round(stopped.stopped_at, 2)})
        except Exception as exc:
            for path in job.written:
                path.unlink(missing_ok=True)
            ev({"event": "file_error", "error": str(exc) or type(exc).__name__})


def serve(
    idle_unload: float = DEFAULT_IDLE_UNLOAD,
    stdin: Iterable[str] | None = None,
    stdout: TextIO | None = None,
    factory: BackendFactory | None = None,
) -> int:
    """Run the worker until `shutdown`, stdin EOF or SIGTERM. Returns the exit code (0).

    `stdin`, `stdout` and `factory` exist for tests; by default the real stdin is read and
    fd 1 is re-pointed at stderr so only this module's events reach the original stdout.
    """
    if idle_unload < 0:
        raise ValueError("idle_unload must be >= 0")
    if stdout is None:
        out = os.fdopen(os.dup(1), "w", encoding="utf-8")
        os.dup2(2, 1)
        sys.stdout = sys.stderr
        os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
        os.environ.setdefault("TQDM_DISABLE", "1")
    else:
        out = stdout
    server = Server(out, idle_unload, factory or _default_factory)

    if threading.current_thread() is threading.main_thread():
        signal.signal(signal.SIGTERM, lambda *_: server.shutdown())
        signal.signal(signal.SIGINT, lambda *_: server.shutdown())
    reader = threading.Thread(target=server.read, args=(stdin if stdin is not None else sys.stdin,), daemon=True)
    reader.start()
    server.work()
    return 0
