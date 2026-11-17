"""UTP v1 veri tipleri ve istemci tarafı doğrulama (packages/schemas/utp/v1/event.schema.json ile birebir).
tenant_id, project_id ve verified alanları istemciden asla gönderilmez."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, TypedDict

from .errors import InvalidEventError

MAX_EVENT_NAME_LENGTH = 100
MAX_PROPERTIES = 100
MAX_IDENTIFIER_LENGTH = 128
ATTRIBUTION_CLICK_PROPERTY = "fr_click"

_EVENT_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")
_PROPERTY_KEY_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_]{0,63}$")


@dataclass(frozen=True, slots=True)
class Consent:
    """İzin anlık görüntüsü. analytics False ise hiçbir olay üretilmez. Server SDK'da izin müşteri
    uygulamasından geçirilir (passthrough); tüm alanlar açıkça gönderilir."""

    analytics: bool = False
    advertising: bool = False
    personalization: bool = False
    session_replay: bool = False

    def to_dict(self) -> dict[str, bool]:
        return {
            "analytics": self.analytics,
            "advertising": self.advertising,
            "personalization": self.personalization,
            "session_replay": self.session_replay,
        }


@dataclass(frozen=True, slots=True)
class Screen:
    width: int
    height: int


@dataclass(frozen=True, slots=True)
class AppInfo:
    version: str | None = None
    build: str | None = None


@dataclass(frozen=True, slots=True)
class Context:
    """Şemadaki context nesnesi; yalnız dolu alanlar gönderilir."""

    page_url: str | None = None
    page_title: str | None = None
    referrer: str | None = None
    locale: str | None = None
    timezone: str | None = None
    screen: Screen | None = None
    app: AppInfo | None = None

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for key in ("page_url", "page_title", "referrer", "locale", "timezone"):
            value = getattr(self, key)
            if value:
                out[key] = value
        if self.screen is not None:
            out["screen"] = {"width": self.screen.width, "height": self.screen.height}
        if self.app is not None:
            app: dict[str, str] = {}
            if self.app.version:
                app["version"] = self.app.version
            if self.app.build:
                app["build"] = self.app.build
            if app:
                out["app"] = app
        return out


class UtpEvent(TypedDict, total=False):
    """Tel üzerinde giden UTP v1 olayı (şema alan adlarıyla birebir)."""

    event_id: str
    event_name: str
    occurred_at: str
    platform: str
    schema_version: int
    sdk: dict[str, str]
    anonymous_id: str
    user_id: str
    session_id: str
    properties: dict[str, Any]
    consent: dict[str, bool]
    context: dict[str, Any]


@dataclass(frozen=True, slots=True)
class FlushResult:
    """Bir flush() çağrısının toplu sonucu."""

    sent: int = 0
    accepted: int = 0
    rejected: int = 0
    batch_id: str | None = None
    status: int = 0
    retained: int = 0
    error: Exception | None = field(default=None, compare=False)

    @property
    def ok(self) -> bool:
        return self.error is None


def idempotency_key_for(event_ids: list[str]) -> str:
    """Web, Node, .NET, Android ve Flutter SDK'larıyla aynı anahtar: sıralı tüm event_id'lerin FNV-1a 64 özeti ve sayı."""
    ordered = sorted(event_ids)
    value = 0xCBF29CE484222325
    for byte in ",".join(ordered).encode("utf-8"):
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "%016x-%d" % (value, len(ordered))


def validate_event_name(name: Any) -> str:
    if not isinstance(name, str) or not name or len(name) > MAX_EVENT_NAME_LENGTH or not _EVENT_NAME_RE.match(name):
        raise InvalidEventError(
            "event_name snake_case olmalı (^[a-z][a-z0-9_]*$, en fazla 100 karakter)"
        )
    return name


def validate_properties(properties: Any) -> dict[str, Any] | None:
    if properties is None:
        return None
    if not isinstance(properties, dict):
        raise InvalidEventError("properties bir dict olmalı")
    if len(properties) > MAX_PROPERTIES:
        raise InvalidEventError("properties en fazla 100 anahtar içerebilir (%d verildi)" % len(properties))
    for key in properties:
        if not isinstance(key, str) or not _PROPERTY_KEY_RE.match(key):
            # Değer metne yazılmaz: yanlışlıkla e-posta gibi bir değer verilmişse uygulama loguna geçmesin.
            raise InvalidEventError("properties anahtarı ^[a-zA-Z][a-zA-Z0-9_]{0,63} desenine uymalı")
    return dict(properties) if properties else None


def validate_identifier(value: Any, field_name: str) -> str | None:
    if value is None or value == "":
        return None
    if not isinstance(value, str) or len(value) > MAX_IDENTIFIER_LENGTH:
        raise InvalidEventError("%s en fazla 128 karakterlik metin olmalı" % field_name)
    return value


def format_time(moment: datetime) -> str:
    """UTC RFC3339, milisaniye hassasiyeti (ör. 2026-11-03T10:00:00.123Z). Saat dilimi yoksa UTC varsayılır."""
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    moment = moment.astimezone(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (moment.microsecond // 1000)
