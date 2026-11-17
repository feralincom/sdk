"""Python ara katmanlarının ortak katmanı. Bu dosya sdks/python-django ve sdks/python-fastapi altında birebir aynıdır
(`feralin_*` paket adı dışında içe aktarma yoktur); her paketin testi eşitliği denetler.

Çekirdek `feralin.Client` izni istemci düzeyinde tutar. Sunucuda her istek farklı kullanıcıya aittir ve `set_consent`
paylaşılan durumu değiştirir; bu yüzden izin değeri başına ayrı istemci kullanılır (en çok 8 birleşim). Çekirdek değişmez.
"""

from __future__ import annotations

import atexit
import ipaddress
import logging
import re
import threading
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote, urlsplit

from feralin import Client, Consent, Context, FeralinError, FlushResult, UtpEvent

_log = logging.getLogger("feralin")

MAX_URL_LENGTH = 2048
MAX_LOCALE_LENGTH = 16

# İstekten gelen Host ve Referer saldırgan denetimindedir; toplayıcının `format: uri` denetimi (Go net/url) geçersiz adreste
# tüm batch'i 400 ile düşürür, başka kullanıcıların olayları da gider. Yalnız bu dar biçim kabul edilir, gerisi gönderilmez.
_AUTHORITY = re.compile(r"(?P<host>[A-Za-z0-9._~-]+|\[(?P<ipv6>[0-9A-Fa-f:.]+)\])(?::[0-9]{1,5})?")
_STRAY_PERCENT = re.compile(r"%(?![0-9A-Fa-f]{2})")
_LOCALE = re.compile(r"[A-Za-z0-9_-]+")


class ConsentClientPool:
    """İzin değeri başına tembel kurulan istemciler. İzinsiz olay için istemci kurulmaz."""

    def __init__(self, project_key: str, collect_url: str, **client_options: Any) -> None:
        client_options.pop("consent", None)
        self._project_key = project_key
        self._collect_url = collect_url
        self._options = client_options
        self._lock = threading.Lock()
        self._clients: dict[Consent, Client] = {}
        self._closed = False
        # Yapılandırma hatası uygulama açılışında fırlasın (sk_ anahtar, geçersiz adres); istek anında değil.
        Client(project_key, collect_url, flush_interval=0, transport=client_options.get("transport")).close(timeout=0)
        atexit.register(self.close)

    def client_for(self, consent: Consent) -> Client | None:
        if not consent.analytics:
            return None
        with self._lock:
            if self._closed:
                return None
            client = self._clients.get(consent)
            if client is None:
                client = Client(self._project_key, self._collect_url, consent=consent, **self._options)
                self._clients[consent] = client
            return client

    def track(self, consent: Consent, event_name: str, properties: Mapping[str, Any] | None = None, **fields: Any) -> UtpEvent | None:
        """Fırlatmaz: izin yoksa veya girdi geçersizse None döner, geçersiz girdi uyarı olarak loglanır."""
        client = self.client_for(consent)
        if client is None:
            return None
        try:
            return client.track(event_name, properties, **fields)
        except FeralinError as exc:
            _log.warning("feralin: olay üretilemedi: %s", type(exc).__name__)
            return None

    def flush(self) -> FlushResult:
        """Tüm istemcileri gönderir; sayılar toplanır, durum ve batch_id son gönderimindir, hata ilk hatadır."""
        with self._lock:
            clients = list(self._clients.values())
        total = FlushResult()
        for client in clients:
            try:
                total = _merge(total, client.flush())
            except FeralinError as exc:
                _log.warning("feralin: gönderim yapılamadı: %s", type(exc).__name__)
        return total

    def close(self, timeout: float = 5.0) -> None:
        """Kuyrukları göndermeyi dener. Birden çok çağrı güvenlidir; süreç çıkışında da çalışır."""
        with self._lock:
            if self._closed:
                return
            self._closed = True
            clients = list(self._clients.values())
        atexit.unregister(self.close)
        for client in clients:
            client.close(timeout=timeout)


def _merge(a: FlushResult, b: FlushResult) -> FlushResult:
    return FlushResult(
        sent=a.sent + b.sent,
        accepted=a.accepted + b.accepted,
        rejected=a.rejected + b.rejected,
        batch_id=b.batch_id or a.batch_id,
        status=b.status or a.status,
        retained=a.retained + b.retained,
        error=a.error or b.error,
    )


@dataclass(frozen=True)
class RequestFeralin:
    """O isteğe bağlı yüzey: izin, kimlik ve bağlam her olaya otomatik eklenir."""

    pool: ConsentClientPool | None
    consent: Consent
    user_id: str | None = None
    anonymous_id: str | None = None
    session_id: str | None = None
    context: Context | None = None

    def track(self, event_name: str, properties: Mapping[str, Any] | None = None, **fields: Any) -> UtpEvent | None:
        if self.pool is None:
            return None
        merged: dict[str, Any] = {"user_id": self.user_id, "anonymous_id": self.anonymous_id, "session_id": self.session_id, "context": self.context}
        merged.update(fields)
        return self.pool.track(self.consent, event_name, properties, **merged)

    def flush(self) -> FlushResult:
        """Ağa çıkar ve bekler. Normalde arka plan göndericisi yeterlidir; asenkron görünümde iş parçacığına alın."""
        return self.pool.flush() if self.pool is not None else FlushResult()


def clean_context(scheme: str | None, host: str | None, path: str | None, referrer: str | None, accept_language: str | None) -> Context | None:
    """Çekirdek URL temizlemez: sorgu ve parça burada atılır, referrer yalnız origin kalır. Şemaya uymayan alan kırpılmaz,
    gönderilmez: kırpılmış adres yanlış veridir, tek geçersiz alan ise toplayıcıda tüm batch'i 400 ile düşürür.
    IP, User-Agent ve çerez okunmaz."""
    page_url = None
    if scheme in ("http", "https") and host and path is not None and _valid_authority(host):
        # Çerçeveler yolu çözülmüş verir; açıkta kalan % kaçış sanılıp adresi geçersiz kılmasın diye kodlanır.
        encoded = quote(_STRAY_PERCENT.sub("%25", path), safe="/%:@!$&'()*+,;=~-._")
        candidate = "%s://%s%s" % (scheme, host, encoded)
        if len(candidate) <= MAX_URL_LENGTH:
            page_url = candidate
    origin = None
    if referrer:
        try:
            parts = urlsplit(referrer)
            authority = parts.netloc.rsplit("@", 1)[-1]
            if parts.scheme in ("http", "https") and _valid_authority(authority):
                candidate = "%s://%s" % (parts.scheme, authority)
                if len(candidate) <= MAX_URL_LENGTH:
                    origin = candidate
        except ValueError:
            origin = None
    locale = None
    if accept_language:
        first = accept_language.split(",")[0].split(";")[0].strip()
        if len(first) <= MAX_LOCALE_LENGTH and _LOCALE.fullmatch(first):
            locale = first
    if not (page_url or origin or locale):
        return None
    return Context(page_url=page_url, referrer=origin, locale=locale)


def _valid_authority(authority: str) -> bool:
    match = _AUTHORITY.fullmatch(authority)
    if match is None:
        return False
    if match.group("ipv6") is None:
        return True
    try:
        ipaddress.IPv6Address(match.group("ipv6"))
    except ValueError:
        return False
    return True


def resolve_safely(resolver: Any, request: Any) -> Any:
    """Çözümleyici hatası uygulamayı düşürmez; değer yok sayılır (izin için bu 'izin yok' demektir)."""
    if resolver is None:
        return None
    try:
        return resolver(request)
    except Exception as exc:  # noqa: BLE001 - uygulama kodu her hatayı atabilir, istek düşmemeli
        _log.warning("feralin: çözümleyici hata verdi: %s", type(exc).__name__)
        return None


def consent_or_none(value: Any) -> Consent:
    return value if isinstance(value, Consent) else Consent()
