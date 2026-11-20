"""Fetch Hugging Face model weights up front so the download can report progress.

Engines download lazily inside their own load calls, which gives no progress. Calling
`ensure_model` first fills the HF cache while emitting `stage="download"` events; the
engine then finds everything cached and loads without touching the network again.
"""

from __future__ import annotations

import io
import threading
import time
from pathlib import Path
from typing import Any

from .types import Cancelled, CancelCheck, ProgressCallback

# What mlx-qwen3-asr fetches (load_models._resolve_path); keep in sync so nothing is left over.
MODEL_PATTERNS = ["*.json", "*.safetensors", "*.txt", "*.model"]
EMIT_INTERVAL = 0.5  # seconds between download events


def ensure_model(
    repo_id: str,
    emit: ProgressCallback,
    should_cancel: CancelCheck | None = None,
    allow_patterns: list[str] = MODEL_PATTERNS,
) -> bool:
    """Download what is missing of `repo_id`, emitting progress. Returns True if anything downloaded.

    Progress covers the whole model: `total_bytes` is its full size and `downloaded_bytes` starts
    at what is already cached, so a resumed download picks up where the last one stopped.

    Best effort: when offline or the repo can't be listed, it returns False and lets the engine's
    own loader handle (or report) the problem. When `should_cancel()` turns true mid-download the
    transfer process is killed within about 0.1 s and `Cancelled` is raised. Files that finished
    stay in the cache and are not fetched again; the file in progress is thrown away, because
    huggingface_hub writes it to a per-process `<etag>.<id>.incomplete` name that no later
    download reuses.
    """
    if Path(repo_id).exists():
        return False
    from huggingface_hub import snapshot_download

    counter = _ByteCounter(repo_id, emit)
    try:
        plan = snapshot_download(repo_id, allow_patterns=allow_patterns, dry_run=True, tqdm_class=counter.tqdm_class())
    except Exception:
        return False
    missing = sum(f.file_size or 0 for f in plan if f.will_download)
    if missing <= 0:
        return False
    counter.total = sum(f.file_size or 0 for f in plan)
    counter.cached = counter.total - missing

    counter.emit(force=True)
    try:
        _run_child(repo_id, allow_patterns, counter, should_cancel)
    except Cancelled:
        _drop_incomplete(repo_id)
        raise
    counter.done()
    return True


def _drop_incomplete(repo_id: str) -> None:
    """Delete the `.incomplete` files a killed transfer leaves in the repo's blobs/.

    They can never be resumed (the name is unique to the killed process), so they would only
    waste disk and make `bytes_on_disk` count bytes no download will use.
    """
    from .models import repo_dir

    blobs = repo_dir(repo_id) / "blobs"
    for path in blobs.glob("*.incomplete") if blobs.is_dir() else ():
        path.unlink(missing_ok=True)


def _run_child(repo_id: str, patterns: list[str], counter: "_ByteCounter", should_cancel: CancelCheck | None) -> None:
    """Run the transfer in a child process so a cancel can really kill it.

    hf-xet reports progress from its own thread, which swallows exceptions, so a cancel can't be
    raised out of the progress callback; killing the process is the only reliable stop. The child
    writes one JSON line per progress tick to its stdout.
    """
    import json
    import subprocess
    import sys

    proc = subprocess.Popen(
        [sys.executable, "-m", "transcribe.download", repo_id, json.dumps(patterns)],
        stdout=subprocess.PIPE,
        stderr=None,
        text=True,
    )
    error: list[str] = []

    def pump() -> None:
        assert proc.stdout
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if "error" in msg:
                error.append(msg["error"])
            else:
                counter.add(msg["kind"], msg["n"])

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    try:
        while proc.poll() is None:
            if should_cancel and should_cancel():
                proc.kill()
                proc.wait()
                raise Cancelled()
            time.sleep(0.1)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    reader.join(timeout=2)
    if proc.returncode != 0:
        raise RuntimeError(error[0] if error else f"download exited with code {proc.returncode}")


class _ByteCounter:
    """Turns huggingface_hub's progress bars into download events.

    huggingface_hub reports network bytes ("Downloading bytes", about every 0.1 s) and bytes
    written to disk ("Reconstructing ...", in ~100 MB bursts). Progress follows whichever is
    ahead, on top of the `cached` bytes already on disk, held below 100% until `done` confirms
    the files are in place.
    """

    def __init__(self, repo_id: str, emit: ProgressCallback) -> None:
        self.repo_id = repo_id
        self.total = 0
        self.cached = 0
        self.counts = {"received": 0, "written": 0}
        self._emit = emit
        self._lock = threading.Lock()
        self._last = 0.0

    def add(self, kind: str, n: float) -> None:
        with self._lock:
            self.counts[kind] += int(n or 0)
        self.emit()

    def emit(self, force: bool = False, finished: bool = False) -> None:
        now = time.monotonic()
        with self._lock:
            if not force and now - self._last < EMIT_INTERVAL:
                return
            self._last = now
            done = self.total if finished else min(self.cached + max(self.counts.values()), self.total - 1)
        from .models import find

        known = find(self.repo_id)
        self._emit(
            {
                "event": "progress",
                "stage": "download",
                "progress": round(done / self.total, 4),
                "model": self.repo_id,
                "model_id": known.id if known else None,
                "downloaded_bytes": done,
                "total_bytes": self.total,
            }
        )

    def done(self) -> None:
        self.emit(force=True, finished=True)

    def tqdm_class(self) -> type:
        from tqdm.auto import tqdm

        counter = self

        class _Bar(tqdm):  # type: ignore[misc]
            """A working tqdm that draws into a discarded buffer and feeds the byte counts."""

            def __init__(self, *args: Any, **kwargs: Any) -> None:
                kwargs.pop("name", None)
                kwargs["file"] = io.StringIO()
                kwargs["disable"] = False
                super().__init__(*args, **kwargs)
                desc = str(kwargs.get("desc", ""))
                self._kind = (
                    "written" if desc.startswith("Reconstructing")
                    else "received" if desc.startswith("Downloading bytes")
                    else None
                )  # fmt: skip

            def update(self, n: float | None = 1) -> bool | None:
                if self._kind:
                    counter.add(self._kind, n or 0)
                return super().update(n)

        return _Bar


def _child_main(repo_id: str, patterns: list[str]) -> int:
    """Child process: download and print `{"kind","n"}` lines for each progress tick."""
    import json
    import os
    import sys

    out = os.fdopen(os.dup(1), "w")
    os.dup2(2, 1)  # keep third-party prints off the progress channel
    sys.stdout = sys.stderr

    from huggingface_hub import snapshot_download
    from tqdm.auto import tqdm

    class _Bar(tqdm):  # type: ignore[misc]
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            kwargs.pop("name", None)
            kwargs["file"] = io.StringIO()
            kwargs["disable"] = False
            super().__init__(*args, **kwargs)
            desc = str(kwargs.get("desc", ""))
            self._kind = (
                "written" if desc.startswith("Reconstructing")
                else "received" if desc.startswith("Downloading bytes")
                else None
            )  # fmt: skip

        def update(self, n: float | None = 1) -> bool | None:
            if self._kind and n:
                out.write(json.dumps({"kind": self._kind, "n": int(n)}) + "\n")
                out.flush()
            return super().update(n)

    try:
        snapshot_download(repo_id, allow_patterns=patterns, tqdm_class=_Bar)
    except Exception as exc:
        out.write(json.dumps({"error": f"{type(exc).__name__}: {exc}"}) + "\n")
        out.flush()
        return 1
    return 0


if __name__ == "__main__":
    import json
    import sys

    raise SystemExit(_child_main(sys.argv[1], json.loads(sys.argv[2])))
