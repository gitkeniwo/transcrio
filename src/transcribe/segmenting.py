"""Backend-independent helpers for turning coarse segments into subtitle cues."""

from __future__ import annotations

import re

from .languages import NO_SPACE_LANGUAGES
from .types import Segment

# Split after sentence-ending punctuation (CJK and Latin), keeping it attached.
_SENTENCE_END = re.compile(r"(?<=[。！？!?；;…])\s*|(?<=\.)\s+")
_CLAUSE_END = re.compile(r"(?<=[，,、：:])\s*")


def display_width(text: str) -> int:
    """CJK/full-width characters count as 2 cells, like a subtitle renderer would."""
    return sum(2 if ord(ch) > 0x2E80 else 1 for ch in text)


def _split_long(piece: str, max_width: int, no_space: bool) -> list[str]:
    if display_width(piece) <= max_width:
        return [piece]
    # Prefer clause boundaries, then hard wrap.
    parts = [p for p in _CLAUSE_END.split(piece) if p]
    out: list[str] = []
    buf = ""
    joiner = "" if no_space else " "
    for part in parts:
        candidate = f"{buf}{joiner if buf else ''}{part}" if not no_space else buf + part
        if buf and display_width(candidate) > max_width:
            out.append(buf)
            buf = part
        else:
            buf = candidate
    if buf:
        out.append(buf)
    final: list[str] = []
    for chunk in out:
        while display_width(chunk) > max_width:
            if no_space:
                cut, w = 0, 0
                while cut < len(chunk) and w + display_width(chunk[cut]) <= max_width:
                    w += display_width(chunk[cut])
                    cut += 1
                final.append(chunk[:cut])
                chunk = chunk[cut:]
            else:
                words = chunk.split()
                line: list[str] = []
                while words and display_width(" ".join(line + [words[0]])) <= max_width:
                    line.append(words.pop(0))
                if not line:  # single very long word
                    line.append(words.pop(0))
                final.append(" ".join(line))
                chunk = " ".join(words)
        if chunk:
            final.append(chunk)
    return final


def estimate_cues(segments: list[Segment], language: str, max_width: int = 42) -> list[Segment]:
    """Split each segment into sentence/clause cues and spread its time by text width.

    Used when no word-level aligner is available for a language. Timing is
    approximate (good to a few seconds) but keeps subtitles usable.
    """
    no_space = language in NO_SPACE_LANGUAGES
    cues: list[Segment] = []
    for seg in segments:
        sentences = [s.strip() for s in _SENTENCE_END.split(seg.text) if s and s.strip()]
        pieces = [p for s in sentences for p in _split_long(s, max_width, no_space)]
        if not pieces:
            continue
        total = sum(display_width(p) for p in pieces) or 1
        span = seg.end - seg.start
        t = seg.start
        for p in pieces:
            dur = span * display_width(p) / total
            cues.append(Segment(text=p, start=t, end=t + dur, speaker=seg.speaker))
            t += dur
    return cues
