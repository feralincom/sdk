"""`fr_error` sözleşmesi (X4): hata türü adı, temizlenmiş kısa mesaj, normalize edilmiş çerçevelerin özeti olan parmak izi ve en üst
çerçeve. Ham yığın izi, dosya yolu, satır numarası ve kullanıcı verisi GİTMEZ. Kurallar Android (ErrorEvent.kt), React Native
(signals.ts) ve Web SDK ile aynıdır; toplayıcı mesajı ayrıca temizler ve izin listesi dışı alanı düşürür."""

from __future__ import annotations

import random
import re
import sys
import threading
from collections.abc import Callable
from types import TracebackType
from typing import Any

ERROR_EVENT_NAME = "fr_error"
ERROR_ORIGIN_HANDLED = "handled"
ERROR_ORIGIN_MANUAL = "manual"
ERROR_ORIGIN_UNCAUGHT = "uncaught_exception"
ERROR_ORIGINS = (ERROR_ORIGIN_HANDLED, ERROR_ORIGIN_MANUAL, ERROR_ORIGIN_UNCAUGHT)

ERROR_MAX_MESSAGE = 200
_MAX_TYPE = 64
_MAX_FRAME = 160
_MAX_APP_VERSION = 32
_FINGERPRINT_FRAMES = 5
_MAX_STACK = 64

_URL_RE = re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s\"'<>]+", re.IGNORECASE)
_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_UUID_RE = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.IGNORECASE)
_TOKEN_RE = re.compile(r"\b[A-Za-z0-9_\-+/=]{24,}\b")
_NUMBER_RE = re.compile(r"\+?\d[\d\s\-().]{5,}\d")
_DIGITS_RE = re.compile(r"\d+")
_SPACE_RE = re.compile(r"\s+")

# Çerçeve sistemi: standart kütüphane ve SDK'nın kendisi; uygulama çerçevesi varsa parmak izine girmez.
_STDLIB = frozenset(getattr(sys, "stdlib_module_names", ())) | {"builtins"}


def scrub_error_message(message: str) -> str:
    """Mesajdan URL, e-posta, UUID, rakam içeren uzun belirteç ve en az 7 haneli sayı dizilerini çıkarır; 200 karaktere kırpar."""
    text = _URL_RE.sub("[url]", message)
    text = _EMAIL_RE.sub("[email]", text)
    text = _UUID_RE.sub("[id]", text)
    text = _TOKEN_RE.sub(lambda m: "[token]" if any(ch.isdigit() for ch in m.group(0)) else m.group(0), text)
    text = _NUMBER_RE.sub(lambda m: "[num]" if sum(ch.isdigit() for ch in m.group(0)) >= 7 else m.group(0), text)
    return _SPACE_RE.sub(" ", text).strip()[:ERROR_MAX_MESSAGE]


def fnv1a64(text: str) -> str:
    """FNV-1a 64 (UTF-8 baytları üzerinde): 16 küçük harf onaltılı; Web, React Native ve Go SDK ile aynı özet."""
    value = 0xCBF29CE484222325
    for byte in text.encode("utf-8"):
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % value


def error_fingerprint(error_type: str, frames: list[str], message: str) -> str:
    """`tür|temel` özeti; temel ilk beş çerçevedir, çerçeve yoksa rakam dizileri `#` yapılmış mesajdır."""
    basis = "|".join(frames[:_FINGERPRINT_FRAMES]) if frames else _DIGITS_RE.sub("#", message)
    return fnv1a64("%s|%s" % (error_type, basis))


def _is_framework(module: str) -> bool:
    root = module.split(".", 1)[0]
    return root in _STDLIB or root == "feralin"


def normalize_frames(tb: TracebackType | None) -> list[str]:
    """Traceback'i `modül.işlev` çerçevelerine çevirir, en içteki önce. Dosya yolu ve satır gitmez; uygulama çerçevesi varsa standart
    kütüphane ve SDK çerçeveleri atılır."""
    entries: list[tuple[str, str]] = []
    while tb is not None and len(entries) < _MAX_STACK:
        frame = tb.tb_frame
        module = str(frame.f_globals.get("__name__") or "unknown")
        code = frame.f_code
        name = getattr(code, "co_qualname", None) or code.co_name
        entries.append((module, ("%s.%s" % (module, name))[:_MAX_FRAME]))
        tb = tb.tb_next
    entries.reverse()
    app = [label for module, label in entries if not _is_framework(module)]
    return app if app else [label for _, label in entries]


def error_properties(error: BaseException | str, origin: str = ERROR_ORIGIN_HANDLED, fatal: bool = False, app_version: str | None = None) -> dict[str, Any]:
    """`fr_error` gövdesini kurar: sözleşme alanlarının tamamı. `app_version` ≤ 32 karakterse eklenir."""
    if isinstance(error, BaseException):
        error_type = (type(error).__name__ or "Error")[:_MAX_TYPE]
        raw_message = str(error)
        frames = normalize_frames(error.__traceback__)
    else:
        error_type = "Error"
        raw_message = str(error)
        frames = []
    message = scrub_error_message(raw_message)
    props: dict[str, Any] = {"error_type": error_type, "fingerprint": error_fingerprint(error_type, frames, message)}
    if message:
        props["message"] = message
    if frames:
        props["top_frame"] = frames[0][:_MAX_FRAME]
    props["frame_count"] = min(len(frames), 1000)
    if app_version and len(app_version) <= _MAX_APP_VERSION:
        props["app_version"] = app_version
    props["handled"] = origin in (ERROR_ORIGIN_HANDLED, ERROR_ORIGIN_MANUAL)
    props["fatal"] = bool(fatal)
    props["origin"] = origin
    return props


class ErrorLimiter:
    """Hata fırtınası sınırı: süreç başına en çok `max_events` olay, aynı parmak izi için en çok `max_per_fingerprint`; örnekleme
    `sample_rate` (0..1) ile."""

    def __init__(
        self,
        sample_rate: float = 1.0,
        max_events: int = 20,
        max_per_fingerprint: int = 3,
        rand: Callable[[], float] = random.random,
    ) -> None:
        rate = float(sample_rate)
        self._sample_rate = 0.0 if rate != rate else min(1.0, max(0.0, rate))
        self._max_events = max_events
        self._max_per_fingerprint = max_per_fingerprint
        self._random = rand
        self._total = 0
        self._per_fingerprint: dict[str, int] = {}
        self._lock = threading.Lock()

    def allow(self, fingerprint: str) -> bool:
        with self._lock:
            if self._total >= self._max_events:
                return False
            if self._sample_rate < 1.0 and self._random() >= self._sample_rate:
                return False
            seen = self._per_fingerprint.get(fingerprint, 0)
            if seen >= self._max_per_fingerprint:
                return False
            self._per_fingerprint[fingerprint] = seen + 1
            self._total += 1
            return True
