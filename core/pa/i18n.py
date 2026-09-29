"""User-facing text in the configured language: "en" (default) or "ko".

Set once per run from the config; call sites pass both versions, `tr(en, ko)`.
"""

LANGUAGES = ("en", "ko")
_current = "en"


def normalize(language: str) -> str:
    return language if language in LANGUAGES else "en"


def set_language(language: str) -> None:
    global _current
    _current = normalize(language)


def tr(en: str, ko: str) -> str:
    return ko if _current == "ko" else en
