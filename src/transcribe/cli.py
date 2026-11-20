"""Command-line interface.

    transcribe FILE... [-f md,srt] [-o DIR] [-l zh] [-m 1.7b] [--timestamps]
    transcribe export TRANSCRIPT.json -f md,srt [-o DIR] [--timestamps] [--title T] [--source NAME]
    transcribe align TRANSCRIPT.json SOURCE [-o OUT.json]
    transcribe backends [--json]
    transcribe doctor [--json]

stdout carries results only (rendered text with --stdout, or a JSON summary
with --json); progress and logs go to stderr. Exit codes: 0 ok, 1 some inputs
failed, 2 usage error, 3 environment problem (e.g. ffmpeg missing), 128+signal
when stopped by SIGINT/SIGTERM (unfinished files are reported as stopped).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import signal
import sys
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any

from . import __version__, backends
from .exporters import CUE_FORMATS, EXPORTERS, ExportOptions, out_path, render, write_text
from .languages import normalize
from .types import Cancelled, TranscribeRequest

# audio, pipeline and the backends' base pull in numpy (and the backends MLX); they are imported
# where they are used so `transcribe export` and `--help` start fast.

EXIT_OK, EXIT_PARTIAL, EXIT_USAGE, EXIT_ENV = 0, 1, 2, 3
SUBCOMMANDS = {"run", "export", "align", "backends", "doctor", "models", "serve"}


class Stopped(BaseException):
    """Raised in the main thread by SIGINT/SIGTERM so the run can report what finished."""

    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def _raise_stopped(signum: int, _frame: Any) -> None:
    raise Stopped(signum)


class Progress:
    """Writes progress to stderr as a one-line bar, NDJSON, or nothing."""

    def __init__(self, mode: str) -> None:
        if mode == "auto":
            mode = "bar" if sys.stderr.isatty() else "none"
        self.mode = mode
        self.file = ""

    def __call__(self, ev: dict[str, Any]) -> None:
        if self.mode == "ndjson":
            print(json.dumps({"file": self.file, **ev}, ensure_ascii=False), file=sys.stderr, flush=True)
        elif self.mode == "bar" and ev.get("event") == "progress":
            pct = int(100 * float(ev.get("progress", 0)))
            print(f"\r{self.file}: {ev.get('stage', '')} {pct:3d}%   ", end="", file=sys.stderr, flush=True)
        elif self.mode == "bar" and ev.get("event") in ("file_done", "file_error"):
            print(file=sys.stderr)

    def log(self, msg: str) -> None:
        if self.mode == "ndjson":
            self({"event": "log", "message": msg})
        elif self.mode != "none":
            print(msg, file=sys.stderr, flush=True)


def segments_payload(transcript: Any) -> list[dict[str, Any]]:
    """`file_done.segments`: one paragraph per transcribed chunk."""
    return [
        {"start": round(s.start, 2), "end": round(s.end, 2), "text": s.text} for s in transcript.segments
    ]


def _formats(value: str) -> list[str]:
    fmts = [f.strip().lower() for f in value.split(",") if f.strip()]
    bad = [f for f in fmts if f not in EXPORTERS]
    if bad or not fmts:
        raise argparse.ArgumentTypeError(f"unknown format(s) {bad}; choose from {', '.join(EXPORTERS)}")
    return list(dict.fromkeys(fmts))


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="transcribe",
        description="Transcribe audio/video files locally (default: Qwen3-ASR on MLX).",
    )
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = p.add_subparsers(dest="command")

    run = sub.add_parser("run", help="transcribe files (default command)")
    run.add_argument("inputs", nargs="+", type=Path, help="audio or video files (anything ffmpeg reads)")
    run.add_argument("-f", "--format", type=_formats, default=["md"], metavar="FMT[,FMT]",
                     help=f"output formats: {', '.join(EXPORTERS)} (default: md)")
    run.add_argument("-o", "--output-dir", type=Path, help="where to write files (default: next to each input)")
    run.add_argument("-l", "--language", help="force language, e.g. zh, en, ja, es, de (default: auto-detect)")
    run.add_argument("-m", "--model", help="model alias (0.6b, 1.7b) or HF repo id / local path")
    run.add_argument("-b", "--backend", default=backends.DEFAULT_BACKEND, choices=backends.names())
    run.add_argument("-t", "--timestamps", action="store_true", help="paragraph timestamps in md/txt")
    run.add_argument("--context", default="", help="hint terms/names to bias recognition, e.g. 'Kubernetes 张三'")
    run.add_argument("--stdout", action="store_true", help="print the (single) rendered format to stdout, write no files")
    run.add_argument("--json", action="store_true", help="print a machine-readable summary to stdout")
    run.add_argument("--overwrite", action="store_true", help="replace existing output files")
    run.add_argument("--progress", choices=["auto", "bar", "ndjson", "none"], default="auto",
                     help="progress on stderr (ndjson is for GUIs/agents)")  # fmt: skip

    ex = sub.add_parser("export", help="render formats from a saved transcript JSON (no model)")
    ex.add_argument("transcript", type=Path, help="a transcript written with -f json")
    ex.add_argument("-f", "--format", type=_formats, default=["md"], metavar="FMT[,FMT]",
                    help=f"output formats: {', '.join(EXPORTERS)} (default: md)")
    ex.add_argument("-o", "--output-dir", type=Path, help="where to write files (default: next to the transcript)")
    ex.add_argument("-t", "--timestamps", action="store_true", help="paragraph timestamps in md/txt")
    ex.add_argument("--title", help="file name stem and md heading (default: the source file's stem)")
    ex.add_argument("--source", help="source file name shown in md and json (default: the transcript's)")  # fmt: skip

    al = sub.add_parser("align", help="re-time a saved transcript's subtitles with the forced aligner")
    al.add_argument("transcript", type=Path, help="a transcript written with -f json")
    al.add_argument("source", type=Path, help="the audio or video file it was transcribed from")
    al.add_argument("-o", "--output", type=Path, help="where to write the aligned JSON (default: replace TRANSCRIPT)")
    al.add_argument("-b", "--backend", default=backends.DEFAULT_BACKEND, choices=backends.names())
    al.add_argument("--progress", choices=["auto", "bar", "ndjson", "none"], default="auto",
                    help="progress on stderr (ndjson is for GUIs/agents)")  # fmt: skip

    for name, helptext in (("backends", "list backends and models"), ("doctor", "check environment")):
        sp = sub.add_parser(name, help=helptext)
        sp.add_argument("--json", action="store_true")

    mp = sub.add_parser("models", help="list, download or remove models")
    mp.add_argument("--json", action="store_true")
    msub = mp.add_subparsers(dest="models_command")
    for name, helptext in (("download", "download a model into the Hugging Face cache"),
                           ("remove", "delete a model from the cache")):  # fmt: skip
        mc = msub.add_parser(name, help=helptext)
        mc.add_argument("model", metavar="ID", help="model id (1.7b, 0.6b, aligner) or repo id")
        mc.add_argument("--json", action="store_true")

    sv = sub.add_parser("serve", help="resident worker: NDJSON jobs on stdin, events on stdout")
    sv.add_argument("--idle-unload", type=float, default=300.0, metavar="SEC",
                    help="unload the model after SEC idle seconds (0 = never; default 300)")  # fmt: skip
    return p


def cmd_run(args: argparse.Namespace) -> int:
    from .audio import FFmpegMissingError, require_ffmpeg

    prog = Progress(args.progress)
    if prog.mode != "bar":
        # Keep stderr clean for machine consumers: hf_hub prints download bars and server
        # notices (e.g. "unauthenticated requests") there.
        os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
        os.environ.setdefault("HF_HUB_VERBOSITY", "error")
        logging.getLogger("huggingface_hub").setLevel(logging.ERROR)
    if args.stdout and (len(args.format) != 1 or len(args.inputs) != 1):
        print("transcribe: --stdout needs exactly one input and one format", file=sys.stderr)
        return EXIT_USAGE
    try:
        require_ffmpeg()
    except FFmpegMissingError as exc:
        print(f"transcribe: {exc}", file=sys.stderr)
        return EXIT_ENV
    if args.output_dir:
        args.output_dir.mkdir(parents=True, exist_ok=True)

    backend = backends.create(args.backend, args.model)
    language = normalize(args.language)
    results: list[dict[str, Any]] = []

    previous = {sig: signal.signal(sig, _raise_stopped) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        _run_files(args, prog, backend, language, results)
    except Stopped as stop:
        _report_stopped(args, prog, results)
        _print_summary(args, results)
        sys.stdout.flush()
        sys.stderr.flush()
        # Skip interpreter shutdown: download worker threads would otherwise keep it alive.
        os._exit(128 + stop.signum)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)

    _print_summary(args, results)
    failed = sum(1 for r in results if r["error"])
    return EXIT_OK if failed == 0 else EXIT_PARTIAL


def _report_stopped(args: argparse.Namespace, prog: Progress, results: list[dict[str, Any]]) -> None:
    """Mark the interrupted file and every file not yet started as stopped."""
    seen = {r["input"] for r in results}
    for src in args.inputs:
        if str(src) not in seen:
            results.append({"input": str(src), "outputs": {}, "error": None})
    for entry in results:
        if entry.get("elapsed") is None and entry["error"] is None:
            # Outputs of an unfinished file would block a retry without --overwrite.
            for path in entry["outputs"].values():
                Path(path).unlink(missing_ok=True)
            entry["outputs"] = {}
            entry["stopped"] = True
            prog.file = entry["input"]
            prog({"event": "file_stopped"})


def _print_summary(args: argparse.Namespace, results: list[dict[str, Any]]) -> None:
    if args.json:
        print(json.dumps({"results": results}, ensure_ascii=False, indent=2))
    elif not args.stdout:
        for r in results:
            for path in r["outputs"].values():
                print(path)


def _run_files(
    args: argparse.Namespace, prog: Progress, backend: Any, language: str | None, results: list[dict[str, Any]]
) -> None:
    from .audio import AudioError, load_audio
    from .pipeline import transcribe_audio

    loaded = False
    for src in args.inputs:
        prog.file = str(src)
        started = time.monotonic()
        entry: dict[str, Any] = {"input": str(src), "outputs": {}, "error": None}
        results.append(entry)
        try:
            targets = {f: out_path(src, f, args.output_dir) for f in args.format}
            if not args.stdout and not args.overwrite:
                existing = [str(p) for p in targets.values() if p.exists()]
                if existing:
                    raise FileExistsError(f"output exists (use --overwrite): {', '.join(existing)}")

            prog({"event": "progress", "stage": "decode", "progress": 0.0})
            audio = load_audio(src)
            if not loaded:
                prog({"event": "progress", "stage": "load", "progress": 0.0})
                backend.load(prog)
                loaded = True

            request = TranscribeRequest(
                language=language,
                context=args.context,
                want_cues=bool(CUE_FORMATS & set(args.format)),
                on_progress=prog,
            )
            transcript = transcribe_audio(backend, audio, request)
            opts = ExportOptions(timestamps=args.timestamps, title=src.stem, source=src.name)

            if args.stdout:
                sys.stdout.write(render(args.format[0], transcript, opts))
            else:
                # Render everything before writing anything, so outputs appear together.
                rendered = {fmt: render(fmt, transcript, opts) for fmt in targets}
                for fmt, path in targets.items():
                    entry["outputs"][fmt] = str(write_text(rendered[fmt], path))

            entry.update(
                language=transcript.language,
                duration=round(transcript.duration, 2),
                elapsed=round(time.monotonic() - started, 2),
                backend=transcript.backend,
                model=transcript.model,
                cue_timing=transcript.cue_timing,
                warnings=transcript.warnings,
                notices=[asdict(n) for n in transcript.notices],
            )
            for w in transcript.warnings:
                prog.log(f"warning: {src.name}: {w}")
            done_keys = ("outputs", "elapsed", "language", "duration", "model", "cue_timing", "warnings", "notices")
            prog({"event": "file_done", **{k: entry[k] for k in done_keys}, "segments": segments_payload(transcript)})
        except (AudioError, FileExistsError, OSError, ValueError, RuntimeError) as exc:
            entry["error"] = str(exc)
            prog({"event": "file_error", "error": str(exc)})
            if prog.mode != "ndjson":
                print(f"transcribe: {src}: {exc}", file=sys.stderr)


def cmd_export(args: argparse.Namespace) -> int:
    from .exporters import export_transcript

    out_dir = args.output_dir or args.transcript.parent
    try:
        result = export_transcript(
            args.transcript, args.format, out_dir, timestamps=args.timestamps, title=args.title, source=args.source
        )
    except (ValueError, OSError) as exc:
        print(f"transcribe: {exc}", file=sys.stderr)
        return EXIT_PARTIAL
    if result.estimated_cues:
        print("transcribe: no subtitle cues in this transcript; srt/vtt timing is estimated", file=sys.stderr)
    for path in result.outputs.values():
        print(path)
    return EXIT_OK


def cmd_align(args: argparse.Namespace) -> int:
    from .audio import AudioError, FFmpegMissingError, require_ffmpeg
    from .pipeline import align_saved

    prog = Progress(args.progress)
    prog.file = str(args.transcript)
    try:
        require_ffmpeg()
    except FFmpegMissingError as exc:
        print(f"transcribe: {exc}", file=sys.stderr)
        return EXIT_ENV
    backend = backends.create(args.backend, None)  # only the aligner is loaded, never the ASR model
    try:
        transcript = align_saved(backend, args.transcript, args.source, args.output, on_progress=prog)
    except (AudioError, OSError, ValueError, RuntimeError) as exc:
        prog({"event": "file_error", "error": str(exc)})
        print(f"transcribe: {exc}", file=sys.stderr)
        return EXIT_PARTIAL
    prog({"event": "file_done"})
    if transcript.cue_timing != "aligned":
        for w in transcript.warnings:
            prog.log(f"warning: {w}")
    print(args.output or args.transcript)
    return EXIT_OK


def cmd_backends(args: argparse.Namespace) -> int:
    rows = []
    for name in backends.names():
        info = backends.get_class(name).info
        rows.append(
            {
                "name": info.name,
                "description": info.description,
                "default_model": info.default_model,
                "model_aliases": info.model_aliases,
                "aligned_languages": sorted(info.aligned_languages),
                "models": [m.id for m in info.models],
                "default": name == backends.DEFAULT_BACKEND,
            }
        )
    if args.json:
        print(json.dumps({"backends": rows}, ensure_ascii=False, indent=2))
    else:
        for r in rows:
            star = " (default)" if r["default"] else ""
            print(f"{r['name']}{star}: {r['description']}")
            print(f"  default model: {r['default_model']}")
            for alias, repo in r["model_aliases"].items():
                print(f"  -m {alias:<6} {repo}")
            print(f"  precise subtitle timing: {', '.join(r['aligned_languages'])}")
    return EXIT_OK


def _gb(n: float) -> str:
    return f"{n / 1e9:.2f} GB"


def cmd_models(args: argparse.Namespace) -> int:
    from . import models

    action = getattr(args, "models_command", None)
    if action is None:
        rows = models.describe_all()
        if args.json:
            print(json.dumps({"models": rows}, ensure_ascii=False, indent=2))
        else:
            print(f"{'ID':8} {'KIND':8} {'STATUS':15} {'ON DISK':>10} {'SIZE':>10} {'RAM':>8}  REPO")
            for r in rows:
                print(f"{r['id']:8} {r['kind']:8} {r['status']:15} {_gb(r['bytes_on_disk']):>10} "
                      f"{_gb(r['size_bytes']):>10} {r['ram_gb']:>5.1f} GB  {r['repo']}")  # fmt: skip
        return EXIT_OK

    info = models.find(args.model)
    if info is None:
        print(f"transcribe: unknown model {args.model!r}; see `transcribe models`", file=sys.stderr)
        return EXIT_USAGE
    if action == "remove":
        freed = models.remove(info)
        if args.json:
            print(json.dumps({"event": "model_removed", "model": info.id, "freed_bytes": freed}))
        else:
            print(f"removed {info.id} ({_gb(freed)} freed)")
        return EXIT_OK

    last = {"t": 0.0}

    def emit(event: dict) -> None:
        if event.get("stage") != "download" or args.json:
            return
        now = time.monotonic()
        if now - last["t"] >= 0.5 or event.get("progress", 0) >= 1:
            last["t"] = now
            print(f"\rdownloading {info.id}: {_gb(event.get('downloaded_bytes', 0))} / "
                  f"{_gb(event.get('total_bytes', 0))}", end="", file=sys.stderr, flush=True)  # fmt: skip

    try:
        models.download(info, emit)
    except Cancelled:
        return 130
    except Exception as exc:
        print(f"transcribe: {exc}", file=sys.stderr)
        return EXIT_ENV
    if not args.json:
        print(file=sys.stderr)
    row = next(r for r in models.describe_all() if r["id"] == info.id)
    print(json.dumps(row, ensure_ascii=False) if args.json else f"{info.id}: {row['status']}")
    return EXIT_OK


def cmd_serve(args: argparse.Namespace) -> int:
    from .serve import serve

    code = serve(idle_unload=args.idle_unload)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)  # non-daemon threads left by third-party libraries must not keep the worker alive


def cmd_doctor(args: argparse.Namespace) -> int:
    import platform

    checks = {
        "ffmpeg": shutil.which("ffmpeg"),
        "ffprobe": shutil.which("ffprobe"),
        "apple_silicon": platform.system() == "Darwin" and platform.machine() == "arm64",
        "hf_cache": os.environ.get("HF_HOME") or str(Path.home() / ".cache" / "huggingface"),
    }
    try:
        import mlx.core as mx

        checks["mlx_device"] = str(mx.default_device())
    except Exception as exc:  # pragma: no cover
        checks["mlx_device"] = None
        checks["mlx_error"] = str(exc)
    ok = bool(checks["ffmpeg"] and checks["apple_silicon"] and checks["mlx_device"])
    if args.json:
        print(json.dumps({"ok": ok, **checks}, indent=2))
    else:
        for k, v in checks.items():
            print(f"{k:14} {v}")
        print("ok" if ok else "problems found")
    return EXIT_OK if ok else EXIT_ENV


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    # `transcribe FILE ...` is shorthand for `transcribe run FILE ...`.
    if argv and argv[0] not in SUBCOMMANDS and argv[0] not in ("-h", "--help", "--version"):
        argv.insert(0, "run")
    args = build_parser().parse_args(argv)
    if args.command is None:
        build_parser().print_help()
        return EXIT_USAGE
    handler = {
        "run": cmd_run, "export": cmd_export, "align": cmd_align, "backends": cmd_backends, "doctor": cmd_doctor,
        "models": cmd_models, "serve": cmd_serve,
    }[args.command]  # fmt: skip
    try:
        return handler(args)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
