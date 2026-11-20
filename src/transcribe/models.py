"""The model catalog: what can be downloaded, what is on disk, and how to fetch or remove it.

Static facts (`ModelInfo`) live with each backend; this module adds the state read from the
Hugging Face cache. Status is `not_downloaded`, `partial` (some bytes on disk, but not a usable
model, e.g. after a cancelled download) or `downloaded`. `bytes_on_disk` counts the blob files
once; the snapshot symlinks that point at them are not counted again.

huggingface_hub 2.x keeps xet-backed files in a cache-wide store, `<hub>/blobs/<xx>/<hash>`, and
makes each repo's `blobs/<etag>` a symlink into it, so one copy can serve several repos. Sizes
follow those links, and `remove` deletes a store file once no other repo links to it.
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
from dataclasses import asdict
from pathlib import Path
from typing import Any

from . import backends
from .backends.base import ModelInfo
from .download import ensure_model
from .types import CancelCheck, ProgressCallback


def hub_cache() -> Path:
    """The Hugging Face hub cache directory, resolved from the environment at call time."""
    for var in ("HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"):
        if os.environ.get(var):
            return Path(os.environ[var]).expanduser()
    home = os.environ.get("HF_HOME")
    base = Path(home).expanduser() if home else Path.home() / ".cache" / "huggingface"
    return base / "hub"


def repo_dir(repo: str) -> Path:
    return hub_cache() / ("models--" + repo.replace("/", "--"))


def catalog() -> list[ModelInfo]:
    """Every model of every registered backend, in registry order."""
    out: list[ModelInfo] = []
    for name in backends.names():
        out.extend(backends.get_class(name).info.models)
    return out


def find(spec: str) -> ModelInfo | None:
    """Look a model up by catalog id ("1.7b"), repo id, or backend alias."""
    key = spec.strip().lower()
    for info in catalog():
        if key in (info.id.lower(), info.repo.lower()):
            return info
    for name in backends.names():
        repo = backends.get_class(name).info.model_aliases.get(key)
        if repo:
            return find(repo)
    return None


def _blob_files(repo: str) -> list[Path]:
    """The real files behind a repo's blobs/, each once.

    A blob is either a regular file, or (xet-backed downloads) a symlink into a hub-level
    blobs/xx/ store. Following those links and de-duplicating keeps the count to real bytes.
    """
    blobs = repo_dir(repo) / "blobs"
    if not blobs.is_dir():
        return []
    seen: dict[Path, Path] = {}
    entries = list(blobs.iterdir())
    names = {e.name for e in entries}
    for entry in entries:
        # A resumed download can leave "<hash>.<id>.incomplete" behind once "<hash>" is whole.
        if entry.name.endswith(".incomplete") and entry.name.split(".")[0] in names:
            continue
        real = entry.resolve() if entry.is_symlink() else entry
        if real.is_file():
            seen.setdefault(real, entry)
        elif entry.is_symlink() or not entry.is_dir():
            seen.setdefault(entry, entry)  # dangling link: shows up, size 0
    return list(seen)


def bytes_on_disk(repo: str) -> int:
    return sum(p.stat().st_size for p in _blob_files(repo) if p.exists())


def _snapshot(repo: str) -> Path | None:
    root = repo_dir(repo)
    ref = root / "refs" / "main"
    snaps = root / "snapshots"
    if ref.is_file() and (snaps / ref.read_text().strip()).is_dir():
        return snaps / ref.read_text().strip()
    candidates = sorted(snaps.iterdir()) if snaps.is_dir() else []
    return candidates[-1] if candidates else None


def _complete(repo: str) -> bool:
    """True when the cached snapshot has everything the loaders read (config + all weights)."""
    snap = _snapshot(repo)
    if snap is None or any(p.name.endswith(".incomplete") for p in _blob_files(repo)):
        return False
    if not (snap / "config.json").exists():
        return False
    index = snap / "model.safetensors.index.json"
    if index.exists():
        try:
            shards = set(json.loads(index.read_text())["weight_map"].values())
        except (OSError, ValueError, KeyError):
            return False
        return bool(shards) and all((snap / s).exists() for s in shards)
    return (snap / "model.safetensors").exists()


def status(repo: str) -> tuple[str, int]:
    """(`not_downloaded` | `partial` | `downloaded`, bytes_on_disk) for a repo."""
    size = bytes_on_disk(repo)
    if size == 0 and not repo_dir(repo).exists():
        return "not_downloaded", 0
    if _complete(repo):
        return "downloaded", size
    return ("partial" if size > 0 else "not_downloaded"), size


def describe(info: ModelInfo, loaded: bool = False) -> dict[str, Any]:
    state, size = status(info.repo)
    row = asdict(info)
    for key in ("languages", "aligned_languages"):
        row[key] = list(row[key])
    return {**row, "status": state, "bytes_on_disk": size, "loaded": loaded}


def describe_all(loaded_repos: set[str] | frozenset[str] = frozenset()) -> list[dict[str, Any]]:
    return [describe(m, m.repo in loaded_repos) for m in catalog()]


def download(info: ModelInfo, emit: ProgressCallback, should_cancel: CancelCheck | None = None) -> None:
    """Fetch `info` into the cache, emitting `stage="download"` progress.

    Raises `Cancelled` if stopped (finished files stay and a later call skips them; the file in
    progress is discarded) and
    `RuntimeError` if the model is still not complete afterwards (offline, repo unreachable).
    """
    ensure_model(info.repo, emit, should_cancel)
    if status(info.repo)[0] != "downloaded":
        raise RuntimeError(f"could not download {info.repo} (offline, or the repository is unreachable)")


def remove(info: ModelInfo) -> int:
    """Delete the model's cache directory and the shared-store files only it uses. Returns the bytes freed."""
    root = repo_dir(info.repo)
    store = (hub_cache() / "blobs").resolve()
    files = [p for p in _blob_files(info.repo) if p.is_file()]
    shared = [p for p in files if p.parent.parent == store]
    freed = sum(p.stat().st_size for p in files if p.is_relative_to(root))
    shutil.rmtree(root, ignore_errors=True)
    for target in shared:
        freed += _release_shared(target, root.name)
    return freed


def _linked_from_cache(target: Path) -> bool:
    """True if any repo folder in the cache still has a blob symlink resolving to `target`."""
    for repo in hub_cache().glob("*--*"):
        blobs = repo / "blobs"
        if not blobs.is_dir():
            continue
        for entry in blobs.iterdir():
            if entry.is_symlink() and entry.resolve() == target:
                return True
    return False


def _release_shared(target: Path, repo_folder: str) -> int:
    """Delete one shared-store file if no repo links to it any more; returns the bytes freed.

    Runs under the store's own `<hash>.lock`, the lock huggingface_hub takes to link or publish a
    blob, so a download that is about to reuse the file cannot race the delete. A file that is still
    linked stays; its `<hash>.refs` manifest just loses this repo's lines.
    """
    refs = target.with_name(target.name + ".refs")
    try:
        from filelock import FileLock

        lock: Any = FileLock(str(target.with_name(target.name + ".lock")), timeout=30)
    except ImportError:
        lock = contextlib.nullcontext()
    try:
        with lock:
            if _linked_from_cache(target):
                if refs.is_file():
                    keep = [ln for ln in refs.read_text().splitlines() if not ln.startswith(repo_folder + "/")]
                    refs.write_text("".join(ln + "\n" for ln in keep))
                return 0
            size = target.stat().st_size
            target.unlink()
            refs.unlink(missing_ok=True)
            return size
    except (OSError, TimeoutError):  # filelock.Timeout is a TimeoutError
        return 0
