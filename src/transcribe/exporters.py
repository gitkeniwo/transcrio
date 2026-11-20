"""Render a `Transcript` to text formats. Exporters never touch backends."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .segmenting import estimate_cues
from .types import Segment, Transcript


@dataclass(frozen=True)
class ExportOptions:
    timestamps: bool = False  # paragraph timestamps in txt/md
    title: str | None = None
    source: str | None = None


def _clock(seconds: float, sep: str = ",", millis: bool = True) -> str:
    ms = max(0, round(seconds * 1000))
    h, rem = divmod(ms, 3_600_000)
    m, rem = divmod(rem, 60_000)
    s, ms = divmod(rem, 1000)
    return f"{h:02}:{m:02}:{s:02}{sep}{ms:03}" if millis else f"{h:02}:{m:02}:{s:02}"


def _paragraphs(t: Transcript) -> list[Segment]:
    return t.segments or [Segment(text=t.text, start=0.0, end=t.duration)]


def _cues(t: Transcript) -> list[Segment]:
    return t.cues if t.cues is not None else estimate_cues(_paragraphs(t), t.language)


def to_txt(t: Transcript, opts: ExportOptions) -> str:
    if opts.timestamps:
        lines = [f"[{_clock(p.start, millis=False)}] {p.text}" for p in _paragraphs(t)]
    else:
        lines = [p.text for p in _paragraphs(t)]
    return "\n\n".join(lines) + "\n"


def to_md(t: Transcript, opts: ExportOptions) -> str:
    head = [f"# {opts.title}" if opts.title else "# Transcript", ""]
    meta = []
    if opts.source:
        meta.append(f"- Source: `{opts.source}`")
    meta += [
        f"- Duration: {_clock(t.duration, millis=False)}",
        f"- Language: {t.language}",
        f"- Model: {t.model}",
    ]
    body = []
    for p in _paragraphs(t):
        body.append(f"**[{_clock(p.start, millis=False)}]** {p.text}" if opts.timestamps else p.text)
    return "\n".join(head + meta + ["", "---", "", ""]) + "\n\n".join(body) + "\n"


def to_srt(t: Transcript, opts: ExportOptions) -> str:
    blocks = [
        f"{i}\n{_clock(c.start)} --> {_clock(c.end)}\n{c.text}"
        for i, c in enumerate(_cues(t), 1)
    ]
    return "\n\n".join(blocks) + "\n"


def to_vtt(t: Transcript, opts: ExportOptions) -> str:
    blocks = [f"{_clock(c.start, '.')} --> {_clock(c.end, '.')}\n{c.text}" for c in _cues(t)]
    return "WEBVTT\n\n" + "\n\n".join(blocks) + "\n"


def to_json(t: Transcript, opts: ExportOptions) -> str:
    data = t.to_dict()
    if opts.source:
        data["source"] = opts.source
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


EXPORTERS: dict[str, Callable[[Transcript, ExportOptions], str]] = {
    "md": to_md,
    "txt": to_txt,
    "srt": to_srt,
    "vtt": to_vtt,
    "json": to_json,
}

# Formats that need subtitle cues from the backend for good timing.
CUE_FORMATS = {"srt", "vtt"}


def render(fmt: str, t: Transcript, opts: ExportOptions) -> str:
    return EXPORTERS[fmt](t, opts)


def write(fmt: str, t: Transcript, opts: ExportOptions, path: Path) -> Path:
    return write_text(render(fmt, t, opts), path)


def write_text(text: str, path: Path) -> Path:
    """Write atomically: a stopped or crashed run never leaves a half-written output behind."""
    tmp = path.with_name(f".{path.name}.part")
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)
    return path


@dataclass
class ExportResult:
    outputs: dict[str, Path]  # format -> written file
    estimated_cues: bool  # srt/vtt was asked for but the transcript has no cues, so timing was estimated


def load_transcript(path: Path) -> tuple[Transcript, dict]:
    """Read a transcript JSON (the json format / the library's master copy). Returns it and the raw dict.

    Raises ValueError for unreadable or invalid files.
    """
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        raise ValueError(f"cannot read {path}: {exc.strerror or exc}") from None
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"{path} is not valid JSON: {exc}") from None
    try:
        return Transcript.from_dict(raw), raw
    except ValueError as exc:
        raise ValueError(f"{path}: {exc}") from None


def export_transcript(
    path: Path,
    formats: list[str],
    out_dir: Path,
    *,
    timestamps: bool = False,
    title: str | None = None,
    source: str | None = None,
) -> ExportResult:
    """Render `formats` from a saved transcript into `out_dir` as `<title>.<fmt>`, overwriting.

    `title` defaults to the stem of the transcript's "source" (the original input file), else to the
    transcript file's own stem; `source` defaults to its "source". No model is involved.
    """
    bad = [f for f in formats if f not in EXPORTERS]
    if bad:
        raise ValueError(f"unknown format(s) {bad}; choose from {', '.join(EXPORTERS)}")
    transcript, raw = load_transcript(path)
    if source is None and isinstance(raw.get("source"), str) and raw["source"]:
        source = raw["source"]
    if not title:
        title = Path(source).stem if source else Path(path).stem
    opts = ExportOptions(timestamps=timestamps, title=title, source=source)
    rendered = {fmt: render(fmt, transcript, opts) for fmt in dict.fromkeys(formats)}
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    name = title.replace("/", "_").replace("\0", "")
    outputs = {fmt: write_text(text, out_dir / f"{name}.{fmt}") for fmt, text in rendered.items()}
    return ExportResult(outputs, estimated_cues=bool(CUE_FORMATS & set(rendered)) and transcript.cues is None)


def out_path(src: Path, fmt: str, out_dir: Path | None) -> Path:
    """Where `fmt` output for `src` goes: `out_dir` if given, else next to the input."""
    return (out_dir or src.parent) / f"{src.stem}.{fmt}"
