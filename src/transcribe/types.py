"""Backend-neutral data model shared by backends, exporters and the CLI.

Every backend returns a `Transcript`; exporters only ever read `Transcript`.
This is the seam that keeps new models (Whisper, Parakeet, ...) pluggable.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Callable, Optional

# Progress events are plain dicts so they serialize straight to NDJSON:
#   {"event": "...", "stage": "...", "progress": 0.0-1.0, ...}
ProgressCallback = Callable[[dict[str, Any]], None]


@dataclass
class Word:
    text: str
    start: float
    end: float


@dataclass
class Segment:
    """A timed span of text, in seconds from the start of the audio."""

    text: str
    start: float
    end: float
    speaker: Optional[str] = None


class Cancelled(Exception):
    """Raised by a cancellable step (download, decode, chunk loop) when the caller asked to stop.

    `stopped_at` is how many seconds of audio were fully transcribed when it stopped.
    """

    def __init__(self, stopped_at: float = 0.0) -> None:
        super().__init__("cancelled")
        self.stopped_at = stopped_at


# Polled between steps; returns True when the current job should stop.
CancelCheck = Callable[[], bool]


@dataclass
class ChunkResult:
    """One independently transcribed span of the audio (about 30 s for Qwen3-ASR)."""

    index: int  # 0-based position in the chunk list
    start: float
    end: float
    text: str  # as the model produced it (unstripped)
    language: str  # reconciled with the text's script when the language was auto-detected
    raw_language: str  # what the model reported, before reconciliation
    truncated: bool = False


@dataclass
class AlignedChunk:
    """Subtitle cues for one chunk, from the forced aligner or estimated."""

    cues: list["Segment"]
    words: list[Word]
    mode: str  # "aligned" | "estimated"
    estimated_span: Optional[tuple[float, float]] = None
    warnings: list[tuple[str, str, list[tuple[float, float]]]] = field(default_factory=list)


@dataclass
class Notice:
    """A structured warning. `code` is stable for programs; `message` is for people.

    Codes: "truncated" (a chunk hit the token limit), "alignment_failed" (the forced
    aligner errored on a span), "timing_estimated" (subtitle timing was estimated).
    `spans` lists the affected [start, end] ranges in seconds, when known.
    """

    code: str
    message: str
    spans: Optional[list[tuple[float, float]]] = None


@dataclass
class TranscribeRequest:
    """What the caller wants; backends ignore what they cannot do."""

    language: Optional[str] = None  # canonical name ("Chinese") or None for auto-detect
    context: str = ""  # hint terms / names to bias decoding
    want_cues: bool = False  # subtitle-sized timed cues (needed for SRT)
    on_progress: Optional[ProgressCallback] = None


@dataclass
class Transcript:
    text: str
    language: str
    duration: float
    backend: str
    model: str
    # Coarse, paragraph-sized spans (always present). Good for Markdown/txt.
    segments: list[Segment] = field(default_factory=list)
    # Subtitle-sized cues; present when `want_cues` was requested.
    cues: Optional[list[Segment]] = None
    # How `cues` were timed: "aligned" (forced aligner) or "estimated" (proportional split).
    cue_timing: Optional[str] = None
    words: Optional[list[Word]] = None
    # Human-readable warnings; `notices` carries the same information with codes.
    warnings: list[str] = field(default_factory=list)
    notices: list[Notice] = field(default_factory=list)

    def warn(self, code: str, message: str, spans: Optional[list[tuple[float, float]]] = None) -> None:
        self.warnings.append(message)
        rounded = [(round(a, 2), round(b, 2)) for a, b in spans] if spans is not None else None
        self.notices.append(Notice(code, message, rounded))

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Transcript":
        """The inverse of `to_dict` (and of the json exporter). Unknown keys such as "source" are ignored.

        Raises ValueError when a required field is missing or has the wrong shape.
        """
        if not isinstance(d, dict):
            raise ValueError("transcript must be a JSON object")
        try:
            segments = [_segment(s) for s in d.get("segments") or []]
            cues = d.get("cues")
            words = d.get("words")
            notices = [
                Notice(
                    code=str(n["code"]),
                    message=str(n["message"]),
                    spans=[(float(a), float(b)) for a, b in n["spans"]] if n.get("spans") is not None else None,
                )
                for n in d.get("notices") or []
            ]
            return cls(
                text=str(d["text"]),
                language=str(d["language"]),
                duration=float(d["duration"]),
                backend=str(d.get("backend") or ""),
                model=str(d.get("model") or ""),
                segments=segments,
                cues=[_segment(c) for c in cues] if cues is not None else None,
                cue_timing=d.get("cue_timing"),
                words=[Word(str(w["text"]), float(w["start"]), float(w["end"])) for w in words]
                if words is not None
                else None,
                warnings=[str(w) for w in d.get("warnings") or []],
                notices=notices,
            )
        except KeyError as exc:
            raise ValueError(f"transcript is missing {exc.args[0]!r}") from None
        except (TypeError, AttributeError) as exc:
            raise ValueError(f"transcript has an unexpected shape: {exc}") from None


def _segment(d: dict[str, Any]) -> Segment:
    speaker = d.get("speaker")
    return Segment(str(d["text"]), float(d["start"]), float(d["end"]), str(speaker) if speaker is not None else None)
