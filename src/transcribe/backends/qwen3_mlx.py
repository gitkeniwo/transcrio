"""Qwen3-ASR on Apple Silicon via MLX (https://github.com/moona3k/mlx-qwen3-asr)."""

from __future__ import annotations

import gc
from typing import Any

import numpy as np

from ..download import ensure_model
from ..languages import reconcile_language
from ..segmenting import estimate_cues
from ..types import (
    AlignedChunk,
    Cancelled,
    CancelCheck,
    ChunkResult,
    ProgressCallback,
    Segment,
    Transcript,
    TranscribeRequest,
    Word,
)
from .base import Backend, BackendInfo, ModelInfo

SAMPLE_RATE = 16_000

# Languages supported by Qwen3-ForcedAligner-0.6B (official model card).
ALIGNED_LANGUAGES = frozenset(
    {"Chinese", "English", "Cantonese", "French", "German", "Italian",
     "Japanese", "Korean", "Portuguese", "Russian", "Spanish"}
)  # fmt: skip


# Peak MLX memory (GB) measured on an M-series Mac with mx.get_peak_memory(), bf16 weights, over a
# 70 s English clip (three chunks): from load through the last chunk. ASR alone: 1.7B 8.16,
# 0.6B 3.14. The aligner alone (load + one 28 s chunk) peaks at 3.68; with srt/vtt requested the
# measured totals were 1.7B 8.16 and 0.6B 5.25, so the aligner only adds to the smaller model.
RAM_1_7B, RAM_0_6B, RAM_ALIGNER = 8.2, 3.2, 3.7

# Languages Qwen3-ASR recognizes (config.json `support_languages`, identical for 0.6B and 1.7B).
ASR_LANGUAGES = (
    "Chinese", "English", "Cantonese", "Arabic", "German", "French", "Spanish", "Portuguese",
    "Indonesian", "Italian", "Korean", "Russian", "Thai", "Vietnamese", "Japanese", "Turkish",
    "Hindi", "Malay", "Dutch", "Swedish", "Danish", "Finnish", "Polish", "Czech", "Filipino",
    "Persian", "Greek", "Romanian", "Hungarian", "Macedonian",
)  # fmt: skip
_ALIGNED = tuple(sorted(ALIGNED_LANGUAGES))

ASR_1_7B = ModelInfo(
    id="1.7b", repo="Qwen/Qwen3-ASR-1.7B", kind="asr", name="Qwen3-ASR 1.7B", params="1.7B",
    size_bytes=4_703_055_333, ram_gb=RAM_1_7B, languages=ASR_LANGUAGES, aligned_languages=_ALIGNED,
    license="Apache-2.0", url="https://huggingface.co/Qwen/Qwen3-ASR-1.7B",
    notes="Most accurate; the default.",
)  # fmt: skip
ASR_0_6B = ModelInfo(
    id="0.6b", repo="Qwen/Qwen3-ASR-0.6B", kind="asr", name="Qwen3-ASR 0.6B", params="0.6B",
    size_bytes=1_880_560_703, ram_gb=RAM_0_6B, languages=ASR_LANGUAGES, aligned_languages=_ALIGNED,
    license="Apache-2.0", url="https://huggingface.co/Qwen/Qwen3-ASR-0.6B",
    notes="Faster and smaller; slightly less accurate.",
)  # fmt: skip
ALIGNER = ModelInfo(
    id="aligner", repo="Qwen/Qwen3-ForcedAligner-0.6B", kind="aligner", name="Qwen3 Forced Aligner",
    params="0.6B", size_bytes=1_840_013_484, ram_gb=RAM_ALIGNER, languages=_ALIGNED,
    aligned_languages=_ALIGNED, license="Apache-2.0",
    url="https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B",
    notes="Word-level timing for srt/vtt subtitles.",
)  # fmt: skip


class Qwen3MLXBackend(Backend):
    info = BackendInfo(
        name="qwen3-mlx",
        description="Qwen3-ASR (30 languages + 22 Chinese dialects) on MLX; "
        "word timing via Qwen3-ForcedAligner for 11 languages",
        default_model="Qwen/Qwen3-ASR-1.7B",
        model_aliases={
            "0.6b": "Qwen/Qwen3-ASR-0.6B",
            "1.7b": "Qwen/Qwen3-ASR-1.7B",
        },
        aligned_languages=ALIGNED_LANGUAGES,
        models=(ASR_1_7B, ASR_0_6B, ALIGNER),
    )

    def __init__(self, model: str | None = None) -> None:
        super().__init__(model)
        self._session: Any = None
        self._aligner: Any = None

    @property
    def loaded(self) -> bool:
        return self._session is not None

    def loaded_repos(self) -> list[str]:
        repos = [self.model_id] if self._session is not None else []
        return repos + ([ALIGNER.repo] if self._aligner is not None else [])

    def load(
        self, on_progress: ProgressCallback | None = None, should_cancel: CancelCheck | None = None
    ) -> None:
        if self._session is None:
            from mlx_qwen3_asr import Session

            if on_progress and ensure_model(self.model_id, on_progress, should_cancel):
                on_progress({"event": "progress", "stage": "load", "progress": 0.0})
            self._session = Session(self.model_id)

    def unload(self) -> None:
        self._session = None
        self._aligner = None
        gc.collect()
        import mlx.core as mx

        mx.clear_cache()

    def _get_aligner(self, emit: ProgressCallback, should_cancel: CancelCheck | None) -> Any:
        if self._aligner is None:
            from mlx_qwen3_asr import ForcedAligner
            from mlx_qwen3_asr.forced_aligner import DEFAULT_FORCED_ALIGNER_MODEL

            if ensure_model(DEFAULT_FORCED_ALIGNER_MODEL, emit, should_cancel):
                emit({"event": "progress", "stage": "align", "progress": 0.0})
            self._aligner = ForcedAligner()
        return self._aligner

    # -- chunk API ------------------------------------------------------------------------

    def split(self, audio: np.ndarray) -> list[tuple[np.ndarray, float]]:
        from mlx_qwen3_asr.chunking import split_audio_into_chunks

        return split_audio_into_chunks(audio, sr=SAMPLE_RATE)

    def transcribe_chunk(
        self, audio: np.ndarray, offset: float, index: int, request: TranscribeRequest
    ) -> ChunkResult:
        self.load(request.on_progress)
        # `audio` is one piece from `split` (<= 30 s), so the library does not split it again.
        result = self._session.transcribe(
            audio, language=request.language, context=request.context, return_chunks=True
        )
        c = result.chunks[0]
        raw = c["language"]
        # Auto-detect only: a forced language is the caller's call.
        language = raw if request.language is not None else reconcile_language(raw, c["text"])
        return ChunkResult(
            index=index,
            start=float(offset),
            end=float(offset + float(len(audio) / SAMPLE_RATE)),
            text=c["text"],
            language=language,
            raw_language=raw,
            truncated=bool(result.truncated),
        )

    def assemble(self, chunks: list[ChunkResult], duration: float, request: TranscribeRequest) -> Transcript:
        from mlx_qwen3_asr.tokenizer import canonicalize_language, join_text_parts

        # Same rules as the library's own chunk loop: the first chunk's tag names the file.
        forced = canonicalize_language(request.language)
        detected = forced or "unknown"
        for c in chunks:
            if detected == "unknown":
                detected = c.raw_language
        final = canonicalize_language(detected) or detected
        text = join_text_parts([c.text for c in chunks], final).strip()
        language = final if request.language is not None else reconcile_language(final, text)
        segments = [
            Segment(text=c.text.strip(), start=c.start, end=c.end) for c in chunks if c.text.strip()
        ]
        transcript = Transcript(
            text=text,
            language=language,
            duration=duration,
            backend=self.info.name,
            model=self.model_id,
            segments=segments,
        )
        if any(c.truncated for c in chunks):
            transcript.warn("truncated", "some chunks hit the token limit; text may be cut off")
        return transcript

    def align_chunk(
        self,
        audio: np.ndarray,
        chunk: ChunkResult,
        language: str,
        request: TranscribeRequest,
        emit: ProgressCallback,
        should_cancel: CancelCheck | None = None,
    ) -> AlignedChunk:
        from mlx_qwen3_asr.writers import group_subtitle_segments

        text = chunk.text.strip()
        start, end = chunk.start, chunk.end
        warnings: list[tuple[str, str, list[tuple[float, float]]]] = []
        aligned: list[Word] = []
        if language in ALIGNED_LANGUAGES:
            try:
                aligned = [
                    Word(text=w.text, start=w.start_time + start, end=w.end_time + start)
                    for w in self._get_aligner(emit, should_cancel).align(audio, text, language)
                ]
            except Cancelled:
                raise
            except Exception as exc:  # aligner failure should not lose the transcript
                warnings.append(("alignment_failed", f"alignment failed at {start:.0f}s: {exc}", [(start, end)]))

        if aligned:
            grouped = group_subtitle_segments(
                [{"text": w.text, "start": w.start, "end": w.end} for w in aligned],
                language=language,
                text=text,
            )
            cues = [Segment(text=g["text"], start=g["start"], end=g["end"]) for g in grouped]
            return AlignedChunk(cues=cues, words=aligned, mode="aligned", warnings=warnings)
        return AlignedChunk(
            cues=estimate_cues([Segment(text, start, end)], language),
            words=[],
            mode="estimated",
            estimated_span=(start, end),
            warnings=warnings,
        )
