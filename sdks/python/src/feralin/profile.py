"""UTP §8.2 kimlik yöntemleri: group (`fr_group`), set_user_properties (`fr_user_properties`) ve global özellikler.

Kurallar bütün SDK'larda ve toplayıcıda (services/collect/internal/httpapi/profile_filter.go) aynıdır:
- Anahtar ^[a-zA-Z][a-zA-Z0-9_]{0,63}$; çağrı başına en çok 50 özellik.
- Değer dizge (en çok 256 karakter, kontrol karakteri yok, e-posta biçiminde değil), sonlu sayı ya da bool; nesne, liste ve None düşer.
- Doğrulama alanları (verified, receipt vb.) düşer: istemci doğrulama beyan edemez.
- Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) düşer.
Toplayıcı ayrıca projenin izin listesini uygular; liste boşsa olay sayılır ama özellik saklanmaz.
"""

from __future__ import annotations

import logging
import math
import re
from collections.abc import Mapping
from typing import Any

GROUP_EVENT_NAME = "fr_group"
USER_PROPERTIES_EVENT_NAME = "fr_user_properties"
SYSTEM_EVENT_PREFIX = "fr_"

MAX_PROFILE_PROPERTIES = 50
MAX_PROFILE_VALUE_LENGTH = 256
MAX_GROUP_ID_LENGTH = 128

_KEY_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_]{0,63}$")
_EMAIL_RE = re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+")

RESERVED_PROFILE_KEYS = frozenset({"verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"})

# Toplayıcıdaki piiTokens, piiFragments ve piiExact listeleriyle birebir.
_PII_TOKENS = frozenset(
    {
        "email", "mail", "phone", "tel", "telephone", "mobile", "msisdn", "gsm",
        "ip", "ipv4", "ipv6", "ssn", "tckn", "passport", "password", "iban",
        "address", "adres", "eposta", "telefon", "soyad", "surname", "firstname",
        "lastname", "fullname", "birthdate", "birthday", "dob",
    }
)
_PII_FRAGMENTS = ("email", "phonenumber", "ipaddress", "firstname", "lastname", "fullname", "surname", "soyad", "eposta", "telefon", "password", "birthdate")
_PII_EXACT = frozenset({"name", "username", "displayname", "isim", "ad"})

_log = logging.getLogger("feralin")


def _key_tokens(key: str) -> list[str]:
    """Anahtarı sözcüklere böler: küçük harf ya da rakamdan sonra gelen büyük harf yeni sözcük başlatır."""
    out: list[str] = []
    for index, char in enumerate(key):
        if index > 0 and char.isupper() and (key[index - 1].islower() or key[index - 1].isdigit()):
            out.append("_")
        out.append(char.lower())
    return [token for token in "".join(out).split("_") if token]


def is_pii_like_key(key: str) -> bool:
    """Anahtar kişisel veriye benziyor mu (toplayıcıdaki isPIILikeKey ile aynı kural)."""
    tokens = _key_tokens(key)
    if any(token in _PII_TOKENS for token in tokens):
        return True
    joined = "".join(tokens)
    if joined in _PII_EXACT:
        return True
    return any(fragment in joined for fragment in _PII_FRAGMENTS)


def _has_control(text: str) -> bool:
    return any(ord(char) < 0x20 or 0x7F <= ord(char) <= 0x9F for char in text)


def _valid_value(value: Any) -> bool:
    if isinstance(value, bool):
        return True
    if isinstance(value, (int, float)):
        return math.isfinite(value)
    if isinstance(value, str):
        return len(value) <= MAX_PROFILE_VALUE_LENGTH and not _has_control(value) and _EMAIL_RE.search(value) is None
    return False


def _valid_key(key: Any) -> bool:
    return isinstance(key, str) and bool(_KEY_RE.match(key)) and key not in RESERVED_PROFILE_KEYS and not is_pii_like_key(key)


def sanitize_profile_properties(properties: Mapping[str, Any] | None) -> dict[str, Any]:
    """Özellikleri sözleşmeye indirger; geçersiz anahtar ve değer sessizce düşer (uyarı loglanır, değer yazılmaz)."""
    out: dict[str, Any] = {}
    if not isinstance(properties, Mapping):
        return out
    dropped = 0
    for key, value in properties.items():
        if len(out) >= MAX_PROFILE_PROPERTIES:
            dropped += 1
            continue
        if not _valid_key(key) or not _valid_value(value):
            dropped += 1
            continue
        out[key] = value
    if dropped:
        _log.warning("feralin: %d özellik sözleşmeye uymadığı için düştü (anahtar biçimi, kişisel veri, değer türü ya da sınır)", dropped)
    return out


def valid_group_id(group_id: Any) -> bool:
    """Grup kimliği 1-128 karakter, boşluktan ibaret değil; `@` ve kontrol karakteri içermez."""
    return (
        isinstance(group_id, str)
        and group_id.strip() != ""
        and len(group_id) <= MAX_GROUP_ID_LENGTH
        and "@" not in group_id
        and not _has_control(group_id)
    )


def merge_global_properties(current: dict[str, Any], update: Mapping[str, Any] | None) -> dict[str, Any]:
    """Global haritaya birleştirir: None değer anahtarı siler; toplam en çok 50 anahtar, fazlası yok sayılır."""
    merged = dict(current)
    if not isinstance(update, Mapping):
        return merged
    additions: dict[str, Any] = {}
    for key, value in update.items():
        if value is None:
            if isinstance(key, str):
                merged.pop(key, None)
            continue
        additions[key] = value
    for key, value in sanitize_profile_properties(additions).items():
        if key not in merged and len(merged) >= MAX_PROFILE_PROPERTIES:
            _log.warning("feralin: global özellik sınırı (%d) dolu, yeni anahtar yok sayıldı", MAX_PROFILE_PROPERTIES)
            continue
        merged[key] = value
    return merged
