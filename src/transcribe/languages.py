"""Map user-facing language codes to the canonical names backends use."""

from __future__ import annotations

from typing import Optional

# ISO-639-1 (and a few common aliases) -> canonical English name.
CODES: dict[str, str] = {
    "zh": "Chinese", "cn": "Chinese", "en": "English", "ja": "Japanese", "jp": "Japanese",
    "ko": "Korean", "es": "Spanish", "de": "German", "fr": "French", "it": "Italian",
    "pt": "Portuguese", "ru": "Russian", "yue": "Cantonese", "ar": "Arabic", "nl": "Dutch",
    "pl": "Polish", "tr": "Turkish", "vi": "Vietnamese", "th": "Thai", "id": "Indonesian",
    "ms": "Malay", "hi": "Hindi", "sv": "Swedish", "da": "Danish", "fi": "Finnish",
    "cs": "Czech", "el": "Greek", "hu": "Hungarian", "ro": "Romanian", "fa": "Persian",
    "fil": "Filipino", "mk": "Macedonian",
}  # fmt: skip

# Scripts written without spaces between words.
NO_SPACE_LANGUAGES = {"Chinese", "Cantonese", "Japanese", "Thai"}


def normalize(language: Optional[str]) -> Optional[str]:
    """`"zh"` / `"chinese"` / `"Chinese"` -> `"Chinese"`; `None`/`"auto"` -> `None`."""
    if language is None:
        return None
    lang = language.strip()
    if not lang or lang.lower() == "auto":
        return None
    if lang.lower() in CODES:
        return CODES[lang.lower()]
    return lang[:1].upper() + lang[1:].lower()


# Detected languages whose script these checks can contradict. Cantonese and Chinese share
# Han, so a Han-majority text never overrides either; likewise Japanese keeps its kanji.
_SCRIPT_LANGUAGES = {"Chinese": "han", "Cantonese": "han", "Japanese": "kana", "Korean": "hangul"}


def _script_counts(text: str) -> dict[str, int]:
    counts = {"han": 0, "kana": 0, "hangul": 0, "other": 0}
    for ch in text:
        o = ord(ch)
        if 0x3040 <= o <= 0x30FF or 0x31F0 <= o <= 0x31FF:
            counts["kana"] += 1
        elif 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or 0xF900 <= o <= 0xFAFF:
            counts["han"] += 1
        elif 0xAC00 <= o <= 0xD7AF or 0x1100 <= o <= 0x11FF:
            counts["hangul"] += 1
        elif ch.isalpha():
            counts["other"] += 1
    return counts


def reconcile_language(detected: Optional[str], text: str) -> Optional[str]:
    """Fix a detected language that contradicts the transcript's script.

    Qwen3-ASR sometimes tags clearly Chinese speech as "English" while transcribing it
    correctly. The tag drives the aligner and subtitle wrapping, so trust the text when
    most of its letters are CJK and the tag is not a CJK language.
    """
    counts = _script_counts(text)
    letters = sum(counts.values())
    if letters < 4 or detected in _SCRIPT_LANGUAGES:
        return detected
    cjk = counts["han"] + counts["kana"] + counts["hangul"]
    if cjk / letters < 0.5:
        return detected
    if counts["hangul"] >= max(counts["han"], counts["kana"]):
        return "Korean"
    if counts["kana"] > 0:
        return "Japanese"
    return "Chinese"
