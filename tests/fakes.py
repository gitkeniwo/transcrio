"""A model-free backend for protocol tests: 30 s chunks, scripted delays, observable load/unload."""

from __future__ import annotations

import os
import sys
import threading
import time

from transcribe.backends.base import Backend, BackendInfo
from transcribe.types import AlignedChunk, Cancelled, ChunkResult, Segment, Word

SR = 16_000


class FakeBackend(Backend):
    info = BackendInfo(
        name="fake",
        description="fake",
        default_model="fake/default",
        model_aliases={"a": "fake/a", "b": "fake/b"},
    )

    # Class-level knobs and log, reset by `reset()`.
    log: list[str] = []
    align_log: list[str] = []  # one "align:<start>-<end>:<clip length>" per align_chunk call
    chunk_delay = 0.0
    gate: threading.Event | None = None  # when set, transcribe_chunk blocks until it is released
    download_on_load = False
    download_gate: threading.Event | None = None  # when set, the fake download pauses at 50% until released
    aligner_repo: str | None = None  # when set, the first align_chunk "loads" this aligner repo
    noisy = False  # print to stdout from inside the model, as a careless library would
    aligns = False  # when set, align_chunk returns "aligned" cues and words instead of estimating
    align_gate: threading.Event | None = None  # when set, align_chunk blocks until it is released

    @classmethod
    def reset(cls) -> None:
        cls.log = []
        cls.align_log = []
        cls.chunk_delay = 0.0
        cls.gate = None
        cls.download_on_load = False
        cls.download_gate = None
        cls.aligner_repo = None
        cls.noisy = False
        cls.aligns = False
        cls.align_gate = None

    def __init__(self, model: str | None = None) -> None:
        super().__init__(model)
        self._loaded = False
        self._aligner = False

    @property
    def loaded(self) -> bool:
        return self._loaded

    def load(self, on_progress=None, should_cancel=None) -> None:
        if self._loaded:
            return
        if self.download_on_load and on_progress:
            for done in (0, 50, 100):
                if should_cancel and should_cancel():
                    raise Cancelled()
                on_progress({"event": "progress", "stage": "download", "progress": done / 100,
                             "model": self.model_id, "downloaded_bytes": done, "total_bytes": 100})  # fmt: skip
                if done == 50 and self.download_gate is not None:
                    self.download_gate.wait(10)
        if self.noisy:
            print("library says hello")
            os.write(1, b"raw fd write\n")
        self._loaded = True
        self.log.append(f"load:{self.model_id}")

    def unload(self) -> None:
        self._aligner = False
        if self._loaded:
            self._loaded = False
            self.log.append(f"unload:{self.model_id}")

    def loaded_repos(self) -> list[str]:
        repos = [self.model_id] if self._loaded else []
        return repos + ([self.aligner_repo] if self._aligner and self.aligner_repo else [])

    def align_chunk(self, audio, chunk, language, request, emit, should_cancel=None):
        self._aligner = True
        self.align_log.append(f"align:{chunk.start:g}-{chunk.end:g}:{len(audio) / SR:g}s")
        if self.align_gate is not None:
            # Held until released or cancelled, so a test's cancel lands while the chunk runs.
            deadline = time.monotonic() + 10
            while not self.align_gate.wait(0.01) and not (should_cancel and should_cancel()) and time.monotonic() < deadline:
                pass
        if not self.aligns:
            return super().align_chunk(audio, chunk, language, request, emit, should_cancel)
        text = chunk.text.strip()
        words = [Word(w, chunk.start + 0.1 * (i + 1), chunk.start + 0.1 * (i + 2)) for i, w in enumerate(text.split())]
        return AlignedChunk(cues=[Segment(text, words[0].start, words[-1].end)], words=words, mode="aligned")

    def split(self, audio):
        step = 30 * SR
        return [(audio[i : i + step], i / SR) for i in range(0, max(len(audio), 1), step)]

    def transcribe_chunk(self, audio, offset, index, request) -> ChunkResult:
        if self.noisy:
            print("chunk noise")
        if self.gate is not None:
            self.gate.wait(10)
        time.sleep(self.chunk_delay)
        return ChunkResult(
            index=index, start=offset, end=offset + len(audio) / SR,
            text=f"text {index + 1}", language="English", raw_language="English",
        )  # fmt: skip
