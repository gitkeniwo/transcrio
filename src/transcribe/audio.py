"""Decode any ffmpeg-readable file (mp3, m4a, wav, flac, ogg, mp4, mkv, mov, ...) to 16 kHz mono float32."""

from __future__ import annotations

import json
import shutil
import subprocess
import threading
from pathlib import Path

import numpy as np

from .types import Cancelled, CancelCheck

SAMPLE_RATE = 16_000


class AudioError(RuntimeError):
    pass


class FFmpegMissingError(AudioError):
    pass


def require_ffmpeg() -> str:
    path = shutil.which("ffmpeg")
    if path is None:
        raise FFmpegMissingError("ffmpeg not found on PATH (install with: brew install ffmpeg)")
    return path


def probe_duration(path: Path) -> float | None:
    if shutil.which("ffprobe") is None:
        return None
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
        capture_output=True,
        text=True,
    )
    try:
        return float(json.loads(proc.stdout)["format"]["duration"])
    except (KeyError, ValueError, json.JSONDecodeError):
        return None


def load_audio(path: Path, should_cancel: CancelCheck | None = None) -> np.ndarray:
    """Return the first audio stream of `path` as mono float32 PCM at SAMPLE_RATE.

    With `should_cancel`, ffmpeg is killed and `Cancelled` raised soon after it turns true."""
    ffmpeg = require_ffmpeg()
    if not path.is_file():
        raise AudioError(f"no such file: {path}")
    cmd = [
        ffmpeg, "-nostdin", "-v", "error",
        "-i", str(path),
        "-map", "0:a:0", "-vn",
        "-ac", "1", "-ar", str(SAMPLE_RATE),
        "-f", "f32le", "-",
    ]  # fmt: skip
    proc = _run(cmd, should_cancel)
    if proc.returncode != 0:
        msg = proc.stderr.decode(errors="replace").strip() or "unknown ffmpeg error"
        if "matches no streams" in msg:
            msg = "file has no audio stream"
        raise AudioError(f"ffmpeg failed to decode {path.name}: {msg}")
    audio = np.frombuffer(proc.stdout, dtype=np.float32)
    if audio.size == 0:
        raise AudioError(f"decoded audio is empty: {path.name}")
    return audio


def _run(cmd: list[str], should_cancel: CancelCheck | None) -> subprocess.CompletedProcess:
    if should_cancel is None:
        return subprocess.run(cmd, capture_output=True)
    popen = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    box: list[tuple[bytes, bytes]] = []
    reader = threading.Thread(target=lambda: box.append(popen.communicate()), daemon=True)
    reader.start()
    while reader.is_alive():
        reader.join(0.1)
        if should_cancel():
            popen.kill()
            reader.join()
            raise Cancelled()
    out, err = box[0]
    return subprocess.CompletedProcess(cmd, popen.returncode, out, err)
