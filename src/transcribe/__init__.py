"""Local transcription with pluggable ASR backends."""

from .types import Segment, Transcript, TranscribeRequest, Word

__version__ = "0.2.0"
__all__ = ["Segment", "Transcript", "TranscribeRequest", "Word", "__version__"]
