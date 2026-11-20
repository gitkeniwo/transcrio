"""The backend contract. Implement this to add a new ASR engine."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field

import numpy as np

from ..segmenting import estimate_cues
from ..types import (
    AlignedChunk,
    CancelCheck,
    ChunkResult,
    ProgressCallback,
    Segment,
    Transcript,
    TranscribeRequest,
)


@dataclass(frozen=True)
class ModelInfo:
    """Static facts about one downloadable model. Status (on disk, loaded) is computed elsewhere."""

    id: str  # short id used by the CLI and GUI, e.g. "1.7b"; unique across backends
    repo: str  # Hugging Face repo id
    kind: str  # "asr" | "aligner"
    name: str
    params: str  # "1.7B"
    size_bytes: int  # full download size
    ram_gb: float  # approximate peak memory while transcribing (measured)
    languages: tuple[str, ...]  # languages it recognizes (aligners: languages it aligns)
    aligned_languages: tuple[str, ...]  # languages with precise subtitle timing
    license: str
    url: str
    notes: str = ""


@dataclass(frozen=True)
class BackendInfo:
    name: str  # registry key, e.g. "qwen3-mlx"
    description: str
    default_model: str
    model_aliases: dict[str, str] = field(default_factory=dict)  # "1.7b" -> HF repo id
    # Languages for which word-level timing is precise; others get estimated cues.
    aligned_languages: frozenset[str] = frozenset()
    models: tuple[ModelInfo, ...] = ()


class Backend(ABC):
    """One loaded model. Construct once, call `transcribe` for many files.

    Contract:
      * `audio` is mono float32 PCM at 16 kHz (see `transcribe.audio`).
      * Always fill `Transcript.segments` (paragraph-sized, timed).
      * When `request.want_cues` is set, also fill `cues` and `cue_timing`.
      * Report progress through `request.on_progress` with `stage="transcribe"`
        and `progress` in [0, 1]; never print to stdout.

    The pipeline (`transcribe.pipeline`) drives a backend chunk by chunk so it can stream
    results, align each chunk as it finishes and stop between chunks. A backend gets that
    by overriding `split`, `transcribe_chunk`, `assemble` and `align_chunk`; the defaults
    treat the whole audio as one chunk and call `transcribe_whole`.
    """

    info: BackendInfo

    def __init__(self, model: str | None = None) -> None:
        self.model_id = self.resolve_model(model)

    @classmethod
    def resolve_model(cls, model: str | None) -> str:
        if not model:
            return cls.info.default_model
        return cls.info.model_aliases.get(model.lower(), model)

    @abstractmethod
    def load(
        self, on_progress: ProgressCallback | None = None, should_cancel: CancelCheck | None = None
    ) -> None:
        """Load weights. Safe to call more than once. If weights must be downloaded first,
        report it through `on_progress` with `stage="download"` (see `transcribe.download`)
        and stop with `Cancelled` when `should_cancel()` turns true."""

    def unload(self) -> None:
        """Drop the weights so the memory can be reused. Safe when nothing is loaded."""

    @property
    def loaded(self) -> bool:
        return False

    def loaded_repos(self) -> list[str]:
        """Repo ids of every model this backend currently holds in memory."""
        return [self.model_id] if self.loaded else []

    def transcribe(self, audio: np.ndarray, request: TranscribeRequest) -> Transcript:
        """Whole-file convenience: run the chunk pipeline without streaming or cancelling."""
        from ..pipeline import transcribe_audio

        return transcribe_audio(self, audio, request)

    # -- chunk API (see class docstring) --------------------------------------------------

    def split(self, audio: np.ndarray) -> list[tuple[np.ndarray, float]]:
        """Cut `audio` into independent (chunk, offset_seconds) pieces."""
        return [(audio, 0.0)]

    def transcribe_chunk(
        self, audio: np.ndarray, offset: float, index: int, request: TranscribeRequest
    ) -> ChunkResult:
        """Transcribe one piece from `split`. Default: `transcribe_whole` on the piece."""
        t = self.transcribe_whole(audio, request)
        return ChunkResult(
            index=index, start=offset, end=offset + len(audio) / 16_000, text=t.text,
            language=t.language, raw_language=t.language,
        )  # fmt: skip

    def transcribe_whole(self, audio: np.ndarray, request: TranscribeRequest) -> Transcript:
        """For simple engines that cannot chunk: transcribe `audio` in one call."""
        raise NotImplementedError(f"{self.info.name} implements neither transcribe_whole nor transcribe_chunk")

    def assemble(self, chunks: list[ChunkResult], duration: float, request: TranscribeRequest) -> Transcript:
        """Join the chunk results into a `Transcript` (segments only; cues come from `align_chunk`)."""
        language = next((c.language for c in chunks if c.language), "unknown")
        segments = [Segment(c.text.strip(), c.start, c.end) for c in chunks if c.text.strip()]
        return Transcript(
            text=" ".join(s.text for s in segments),
            language=language,
            duration=duration,
            backend=self.info.name,
            model=self.model_id,
            segments=segments,
        )

    def align_chunk(
        self,
        audio: np.ndarray,
        chunk: ChunkResult,
        language: str,
        request: TranscribeRequest,
        emit: ProgressCallback,
        should_cancel: CancelCheck | None = None,
    ) -> AlignedChunk:
        """Subtitle cues for one non-empty chunk. Default: estimated from the text."""
        text = chunk.text.strip()
        return AlignedChunk(
            cues=estimate_cues([Segment(text, chunk.start, chunk.end)], language),
            words=[],
            mode="estimated",
            estimated_span=(chunk.start, chunk.end),
        )
