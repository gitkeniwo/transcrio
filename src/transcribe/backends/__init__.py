"""Backend registry. Backends are imported lazily so `--help` stays fast."""

from __future__ import annotations

import importlib
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from .base import Backend, BackendInfo

# name -> "module:Class"
_REGISTRY: dict[str, str] = {
    "qwen3-mlx": "transcribe.backends.qwen3_mlx:Qwen3MLXBackend",
}

DEFAULT_BACKEND = "qwen3-mlx"


def names() -> list[str]:
    return list(_REGISTRY)


def get_class(name: str) -> type[Backend]:
    try:
        target = _REGISTRY[name]
    except KeyError:
        raise ValueError(f"unknown backend {name!r}; available: {', '.join(_REGISTRY)}") from None
    module, cls = target.split(":")
    return getattr(importlib.import_module(module), cls)


def create(name: str = DEFAULT_BACKEND, model: str | None = None) -> Backend:
    return get_class(name)(model)


def __getattr__(name: str) -> Any:
    # `Backend`/`BackendInfo` pull in numpy; load them only when asked for (`transcribe export` never is).
    if name in ("Backend", "BackendInfo"):
        from . import base

        return getattr(base, name)
    raise AttributeError(name)


__all__ = ["Backend", "BackendInfo", "DEFAULT_BACKEND", "create", "get_class", "names"]
