"""The shared transcription pipeline: chunk by chunk, with streaming, per-chunk alignment and cancel.

Batch mode (`transcribe FILE...`) and the `serve` worker both run `transcribe_audio`. The model
is driven one chunk at a time (chunks are independent), which lets the caller

  * receive each chunk's text as soon as it is ready (`on_chunk`),
  * have the forced aligner run right after each chunk (`interleave_align`), and
  * stop between two chunks (`should_cancel`), losing at most the chunk in flight.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Callable

import numpy as np

from .backends.base import Backend
from .types import (
    AlignedChunk,
    Cancelled,
    CancelCheck,
    ChunkResult,
    ProgressCallback,
    Transcript,
    TranscribeRequest,
)

SAMPLE_RATE = 16_000


def transcribe_audio(
    backend: Backend,
    audio: np.ndarray,
    request: TranscribeRequest,
    *,
    interleave_align: bool = False,
    on_chunk: Callable[[ChunkResult, int], None] | None = None,
    should_cancel: CancelCheck | None = None,
) -> Transcript:
    """Transcribe `audio` with an already loaded `backend`.

    `on_chunk(result, total_chunks)` fires after each chunk is transcribed. With
    `interleave_align` each chunk is aligned right after it (progress `stage="align"` carries
    `chunk` and `total_chunks`); otherwise alignment runs after the last chunk, which keeps
    the batch CLI's progress shape (transcribe 0-100%, then align 0-100%).
    Raises `Cancelled(stopped_at)` when `should_cancel()` turns true between steps.
    """
    emit: ProgressCallback = request.on_progress or (lambda _e: None)
    cancelled = should_cancel or (lambda: False)
    chunks = backend.split(audio)
    total = len(chunks)
    duration = len(audio) / SAMPLE_RATE
    results: list[ChunkResult] = []
    aligned: dict[int, AlignedChunk] = {}
    processed = 0.0

    def stop() -> None:
        raise Cancelled(processed)

    def progress(stage: str, value: float, chunk: int | None) -> None:
        emit({"event": "progress", "stage": stage, "progress": value, "chunk": chunk, "total_chunks": total})

    def align(i: int, done: int, denominator: int) -> None:
        if cancelled():
            stop()
        progress("align", done / max(denominator, 1), i + 1)
        r = results[i]
        lang = request.language or r.language or _first_language(results)
        # Cut the clip from the whole audio by the chunk's times, as the single-pass CLI always did.
        clip = audio[int(r.start * SAMPLE_RATE) : int(r.end * SAMPLE_RATE)]
        aligned[i] = backend.align_chunk(clip, r, lang, request, emit, should_cancel)

    progress("transcribe", 0.0, None)
    for i, (piece, offset) in enumerate(chunks):
        if cancelled():
            stop()
        seconds = len(piece) / SAMPLE_RATE
        progress("transcribe", min(processed / duration, 1.0) if duration > 0 else 0.0, i + 1)
        result = backend.transcribe_chunk(piece, offset, i, request)
        results.append(result)
        processed += seconds
        progress("transcribe", min(processed / duration, 1.0) if duration > 0 else 0.0, i + 1)
        if on_chunk:
            on_chunk(result, total)
        if request.want_cues and interleave_align and result.text.strip():
            align(i, len(aligned), total)

    if request.want_cues and not interleave_align:
        live = [i for i, r in enumerate(results) if r.text.strip()]
        for n, i in enumerate(live):
            align(i, n, len(live))

    transcript = backend.assemble(results, duration, request)
    if request.want_cues:
        _apply_cues(transcript, [aligned[i] for i in sorted(aligned)])
        progress("align", 1.0, total)
    return transcript


def align_transcript(
    backend: Backend,
    audio: np.ndarray,
    transcript: Transcript,
    *,
    on_progress: ProgressCallback | None = None,
    should_cancel: CancelCheck | None = None,
) -> Transcript:
    """Re-time the subtitle cues of an existing `transcript` with the forced aligner, in place.

    Each segment (one per transcribed chunk) is aligned against its clip of `audio`, as the
    transcription pass would have done, so the text is kept and only cues, words and cue timing
    change. Old timing notices ("timing_estimated", "alignment_failed") are replaced by whatever
    this pass reports. Progress goes out as `stage="align"`; raises `Cancelled` between segments.
    """
    emit: ProgressCallback = on_progress or (lambda _e: None)
    cancelled = should_cancel or (lambda: False)
    live = [s for s in transcript.segments if s.text.strip()]
    if not live:
        raise ValueError("nothing to align: the transcript has no text")
    request = TranscribeRequest(language=transcript.language, want_cues=True, on_progress=emit)
    parts: list[AlignedChunk] = []
    for n, seg in enumerate(live):
        if cancelled():
            raise Cancelled(0.0)
        emit({"event": "progress", "stage": "align", "progress": n / len(live), "chunk": n + 1,
              "total_chunks": len(live)})  # fmt: skip
        chunk = ChunkResult(index=n, start=seg.start, end=seg.end, text=seg.text,
                            language=transcript.language, raw_language=transcript.language)  # fmt: skip
        clip = audio[int(seg.start * SAMPLE_RATE) : int(seg.end * SAMPLE_RATE)]
        parts.append(backend.align_chunk(clip, chunk, transcript.language, request, emit, should_cancel))
    stale = {"timing_estimated", "alignment_failed"}
    dropped = {n.message for n in transcript.notices if n.code in stale}
    transcript.notices = [n for n in transcript.notices if n.code not in stale]
    transcript.warnings = [w for w in transcript.warnings if w not in dropped]
    _apply_cues(transcript, parts)
    emit({"event": "progress", "stage": "align", "progress": 1.0, "chunk": len(live), "total_chunks": len(live)})
    return transcript


def align_saved(
    backend: Backend,
    transcript_path: Path,
    source: Path,
    output: Path | None = None,
    *,
    on_progress: ProgressCallback | None = None,
    should_cancel: CancelCheck | None = None,
) -> Transcript:
    """Align a saved transcript JSON against its `source` audio and write it to `output`.

    `output` defaults to `transcript_path` (replaced atomically). Keys the transcript carries
    beyond the data model (such as "source") are kept. Raises ValueError when the transcript is
    invalid, its language has no forced aligner, or the source's length doesn't match it.
    """
    from .audio import load_audio
    from .exporters import load_transcript, write_text

    emit: ProgressCallback = on_progress or (lambda _e: None)
    transcript, raw = load_transcript(transcript_path)
    aligned_languages = backend.info.aligned_languages
    if aligned_languages and transcript.language not in aligned_languages:
        raise ValueError(f"no forced aligner for {transcript.language}")
    emit({"event": "progress", "stage": "decode", "progress": 0.0})
    audio = load_audio(source, should_cancel)
    seconds = len(audio) / SAMPLE_RATE
    if abs(seconds - transcript.duration) > max(2.0, 0.02 * transcript.duration):
        raise ValueError(
            f"{source.name} is {seconds:.1f} s long but the transcript is {transcript.duration:.1f} s; "
            "is it the right source file?"
        )
    align_transcript(backend, audio, transcript, on_progress=emit, should_cancel=should_cancel)
    target = Path(output) if output is not None else Path(transcript_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    write_text(json.dumps({**raw, **transcript.to_dict()}, ensure_ascii=False, indent=2) + "\n", target)
    return transcript


def _first_language(results: list[ChunkResult]) -> str:
    return next((r.language for r in results if r.language), "unknown")


def _apply_cues(transcript: Transcript, parts: list[AlignedChunk]) -> None:
    cues, words, modes, estimated = [], [], set(), []
    for part in parts:
        cues.extend(part.cues)
        words.extend(part.words)
        modes.add(part.mode)
        if part.estimated_span:
            estimated.append(part.estimated_span)
        for code, message, spans in part.warnings:
            transcript.warn(code, message, spans)
    transcript.cues = cues
    transcript.words = words or None
    transcript.cue_timing = modes.pop() if len(modes) == 1 else ("mixed" if modes else None)
    if transcript.cue_timing in ("estimated", "mixed"):
        transcript.warn(
            "timing_estimated",
            "subtitle timing is estimated for part of the audio (language without forced aligner)",
            estimated,
        )
