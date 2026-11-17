"""Feralin UTP v1 server SDK istemcisi.

İlkeler (Web SDK ile tutarlı):
- consent.analytics False ise olay üretilmez; track() sessizce None döner.
- At-least-once: 202 → ack; 4xx (429 hariç) → olaylar atılır; 5xx / 429 / ağ → kuyrukta tutulur ve üstel
  backoff (1 sn → 30 sn) ile yeniden denenir. Aynı batch aynı Idempotency-Key ile gider.
- Yalnız proje public anahtarı (pk_…) kabul edilir; gizli anahtar (sk_…) reddedilir. tenant_id ve verified
  asla gönderilmez; bunları sunucu çözer.
"""

from __future__ import annotations

import json
import logging
import random
import threading
import time
from collections.abc import Mapping
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlsplit

from .error_capture import ERROR_EVENT_NAME, ERROR_ORIGIN_HANDLED, ERROR_ORIGIN_MANUAL, ERROR_ORIGINS, ErrorLimiter, error_properties
from .errors import (
    ClientClosedError,
    ConfigurationError,
    DeliveryError,
    InvalidEventError,
    RejectedError,
    TemporaryError,
)
from .events import (
    ATTRIBUTION_CLICK_PROPERTY,
    MAX_PROPERTIES,
    Consent,
    Context,
    FlushResult,
    UtpEvent,
    format_time,
    idempotency_key_for,
    validate_event_name,
    validate_identifier,
    validate_properties,
)
from .profile import (
    GROUP_EVENT_NAME,
    SYSTEM_EVENT_PREFIX,
    USER_PROPERTIES_EVENT_NAME,
    merge_global_properties,
    sanitize_profile_properties,
    valid_group_id,
)
from .revenue import REVENUE_EVENT_NAME, Receipt, revenue_properties
from .transport import Transport, urllib_transport
from .ulid import ULIDGenerator

SDK_NAME = "feralin-python"
SDK_VERSION = "0.1.0"
PLATFORM = "python"
SCHEMA_VERSION = 1

MAX_BATCH_SIZE = 500
DEFAULT_BATCH_SIZE = 100
DEFAULT_QUEUE_LIMIT = 1000
DEFAULT_FLUSH_INTERVAL = 2.0
DEFAULT_TIMEOUT = 10.0
CLOSE_TIMEOUT = 5.0

_MIN_BACKOFF = 1.0
_MAX_BACKOFF = 30.0

_log = logging.getLogger("feralin")


class Client:
    """UTP v1 toplayıcısına (POST /v1/batch) olay gönderen, iş parçacığı güvenli istemci.

    Örnek::

        client = Client("pk_live_…", "https://collect.example.com", consent=Consent(analytics=True))
        client.track("order_completed", {"order_id": "ord_1"}, user_id="user_42")
        client.close()
    """

    def __init__(
        self,
        project_key: str,
        collect_url: str,
        *,
        consent: Consent | None = None,
        flush_interval: float = DEFAULT_FLUSH_INTERVAL,
        batch_size: int = DEFAULT_BATCH_SIZE,
        queue_limit: int = DEFAULT_QUEUE_LIMIT,
        timeout: float = DEFAULT_TIMEOUT,
        transport: Transport | None = None,
        now: Any = None,
        app_version: str | None = None,
        error_sample_rate: float = 1.0,
    ) -> None:
        key = (project_key or "").strip()
        if key.startswith("sk_"):
            raise ConfigurationError("gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin")
        if not key.startswith("pk_") or len(key) < 8:
            raise ConfigurationError("proje anahtarı pk_ ile başlamalı")
        parts = urlsplit((collect_url or "").strip())
        if parts.scheme not in ("http", "https") or not parts.netloc:
            raise ConfigurationError("collect_url http veya https şemalı mutlak adres olmalı")
        if timeout <= 0:
            raise ConfigurationError("timeout pozitif olmalı")

        self._project_key = key
        self._endpoint = (collect_url.strip().rstrip("/")) + "/v1/batch"
        self._consent = consent if consent is not None else Consent()
        self._flush_interval = float(flush_interval)
        self._batch_size = max(1, min(int(batch_size), MAX_BATCH_SIZE))
        self._queue_limit = max(1, int(queue_limit))
        self._timeout = float(timeout)
        self._transport: Transport = transport or urllib_transport
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._ulid = ULIDGenerator(lambda: int(self._now().timestamp() * 1000))
        # app_version yalnız fr_error olaylarına girer; sınırlayıcı hata fırtınasının toplayıcıyı doldurmasını önler.
        self._app_version = app_version
        self._error_limiter = ErrorLimiter(error_sample_rate)

        self._lock = threading.Lock()  # kuyruk, izin, kimlik, backoff
        self._send_lock = threading.Lock()  # aynı anda tek gönderici (sabit Idempotency-Key)
        self._queue: list[tuple[str, bytes]] = []
        # Sonucu bilinmeyen batch aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda
        # kaybolduysa araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
        self._pinned: list[tuple[str, bytes]] | None = None
        self._user_id: str | None = None
        # Global özellikler: adı fr_ ile başlamayan her olaya track anında eklenir; olayın kendi özelliği önceliklidir.
        self._globals: dict[str, Any] = {}
        self._closed = False
        self._dropped = 0
        self._backoff = 0.0
        self._backoff_until = 0.0

        self._wake = threading.Event()
        self._stop = False
        self._thread: threading.Thread | None = None
        if self._flush_interval > 0:
            self._thread = threading.Thread(target=self._run, name="feralin-flush", daemon=True)
            self._thread.start()

    # ------------------------------------------------------------------ genel API

    def set_consent(self, consent: Consent) -> None:
        """İzin durumunu günceller. analytics False ise bekleyen olaylar atılır ve yeni olay üretilmez."""
        if not isinstance(consent, Consent):
            raise InvalidEventError("consent bir Consent örneği olmalı")
        with self._lock:
            self._consent = consent
            if not consent.analytics:
                self._queue.clear()
                self._pinned = None

    def identify(self, user_id: str | None) -> None:
        """Sonraki olaylar için varsayılan user_id (olay başına user_id öncelidir). None varsayılanı kaldırır."""
        value = validate_identifier(user_id, "user_id")
        with self._lock:
            self._user_id = value

    def set_global_properties(self, properties: Mapping[str, Any]) -> None:
        """Global özellikleri birleştirir: None değer anahtarı siler. Kimlik yöntemleriyle aynı temizlik kuralları uygulanır
        (kişisel veriye benzeyen anahtar, doğrulama alanı, uzun değer düşer); toplam en çok 50 anahtar. Adı `fr_` ile başlamayan
        her olaya eklenir; olayın aynı anahtardaki özelliği globali ezer."""
        with self._lock:
            self._globals = merge_global_properties(self._globals, properties)

    def clear_global_properties(self) -> None:
        """Bütün global özellikleri siler."""
        with self._lock:
            self._globals = {}

    def group(
        self,
        group_id: str,
        traits: Mapping[str, Any] | None = None,
        *,
        user_id: str | None = None,
        anonymous_id: str | None = None,
        session_id: str | None = None,
        occurred_at: datetime | None = None,
    ) -> UtpEvent | None:
        """Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve temizlenmiş özellikler. Grup kimliği
        1-128 karakter olmalı, `@` ve kontrol karakteri içermemelidir; uymazsa olay üretilmez ve None döner. Toplayıcı yalnız
        projenin izin listesindeki özellikleri saklar."""
        if not valid_group_id(group_id):
            _log.warning("feralin: fr_group: geçersiz group_id, olay üretilmedi")
            return None
        props = sanitize_profile_properties(traits)
        props["group_id"] = group_id
        return self.track(GROUP_EVENT_NAME, props, user_id=user_id, anonymous_id=anonymous_id, session_id=session_id, occurred_at=occurred_at)

    def set_user_properties(
        self,
        properties: Mapping[str, Any],
        *,
        user_id: str | None = None,
        anonymous_id: str | None = None,
        session_id: str | None = None,
        occurred_at: datetime | None = None,
    ) -> UtpEvent | None:
        """Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Geçerli özellik kalmazsa olay üretilmez ve None döner.
        Toplayıcı yalnız projenin izin listesindeki anahtarları saklar (liste boşsa olay sayılır, özellik saklanmaz)."""
        props = sanitize_profile_properties(properties)
        if not props:
            _log.warning("feralin: fr_user_properties: geçerli özellik yok, olay üretilmedi")
            return None
        return self.track(USER_PROPERTIES_EVENT_NAME, props, user_id=user_id, anonymous_id=anonymous_id, session_id=session_id, occurred_at=occurred_at)

    def track_revenue(
        self,
        transaction_id: str,
        amount_minor: int,
        currency: str,
        *,
        product_id: str | None = None,
        quantity: int = 1,
        purchase_type: str = "purchase",
        receipt: Receipt | None = None,
        properties: Mapping[str, Any] | None = None,
        user_id: str | None = None,
        anonymous_id: str | None = None,
        session_id: str | None = None,
        occurred_at: datetime | None = None,
        context: Context | None = None,
    ) -> UtpEvent | None:
        """Satın alma ya da abonelik beyanı (`feralin_purchase`). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı
        onaylarsa REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez.
        Sözleşme dışı girdide InvalidEventError fırlatır; izin yoksa None döner."""
        props = revenue_properties(
            transaction_id,
            amount_minor,
            currency,
            product_id=product_id,
            quantity=quantity,
            purchase_type=purchase_type,
            receipt=receipt,
            properties=properties,
        )
        return self.track(
            REVENUE_EVENT_NAME,
            props,
            user_id=user_id,
            anonymous_id=anonymous_id,
            session_id=session_id,
            occurred_at=occurred_at,
            context=context,
        )

    def capture_error(
        self,
        error: BaseException | str,
        *,
        origin: str = ERROR_ORIGIN_HANDLED,
        fatal: bool = False,
        user_id: str | None = None,
        anonymous_id: str | None = None,
        session_id: str | None = None,
        occurred_at: datetime | None = None,
    ) -> UtpEvent | None:
        """Yakalanan bir hatayı `fr_error` olarak bildirir (`except` bloğunda çağrılır). Ham yığın izi gitmez: hata sınıfı adı,
        temizlenmiş mesaj, `modül.işlev` çerçevelerinin özeti olan parmak izi ve en üst çerçeve gider. `origin`: `handled`
        (varsayılan), `manual` ya da `uncaught_exception`; bilinmeyen değer `manual` sayılır. İzin yoksa, sınır (süreç başına 20,
        parmak izi başına 3) ya da örnekleme düşürürse None döner."""
        if origin not in ERROR_ORIGINS:
            origin = ERROR_ORIGIN_MANUAL
        props = error_properties(error, origin, fatal, self._app_version)
        with self._lock:
            analytics = self._consent.analytics
        # İzin yokken sınır sayacı tüketilmez: izin sonradan gelirse hatalar yine raporlanabilsin.
        if not analytics:
            return None
        if not self._error_limiter.allow(props["fingerprint"]):
            _log.debug("feralin: fr_error sınırı ya da örnekleme, olay üretilmedi")
            return None
        return self.track(ERROR_EVENT_NAME, props, user_id=user_id, anonymous_id=anonymous_id, session_id=session_id, occurred_at=occurred_at)

    def track(
        self,
        event_name: str,
        properties: Mapping[str, Any] | None = None,
        *,
        user_id: str | None = None,
        anonymous_id: str | None = None,
        session_id: str | None = None,
        occurred_at: datetime | None = None,
        context: Context | None = None,
    ) -> UtpEvent | None:
        """Olayı doğrular, UTP v1 biçimine çevirir ve kuyruğa ekler; ağ çağrısı yapmaz.

        consent.analytics False ise olay üretilmez ve None döner. Doğrulama hatalarında InvalidEventError
        fırlatır; kapalı istemcide ClientClosedError.
        """
        with self._lock:
            closed, consent, default_user, globals_ = self._closed, self._consent, self._user_id, self._globals
        if closed:
            raise ClientClosedError("istemci kapatıldı")
        if not consent.analytics:
            _log.debug("feralin: izin yok, olay üretilmedi: %s", event_name)
            return None

        name = validate_event_name(event_name)
        props = validate_properties(properties)
        # fr_click yalnız açık reklam ölçümü izniyle gönderilir.
        if props and not consent.advertising:
            props = {key: value for key, value in props.items() if key != ATTRIBUTION_CLICK_PROPERTY}
        # Global özellikler sistem olaylarına (fr_) eklenmez: toplayıcı onların gövdesini kapalı sözleşmeyle denetler.
        if globals_ and not name.startswith(SYSTEM_EVENT_PREFIX):
            merged = dict(props or {})
            for key, value in globals_.items():
                if key not in merged and len(merged) < MAX_PROPERTIES:
                    merged[key] = value
            props = merged or None
        uid = validate_identifier(user_id, "user_id") or default_user
        aid = validate_identifier(anonymous_id, "anonymous_id")
        sid = validate_identifier(session_id, "session_id")
        if context is not None and not isinstance(context, Context):
            raise InvalidEventError("context bir Context örneği olmalı")

        event: UtpEvent = {
            "event_id": self._ulid.new(),
            "event_name": name,
            "occurred_at": format_time(occurred_at if occurred_at is not None else self._now()),
            "platform": PLATFORM,
            "schema_version": SCHEMA_VERSION,
            "sdk": {"name": SDK_NAME, "version": SDK_VERSION},
            "consent": consent.to_dict(),
        }
        if aid:
            event["anonymous_id"] = aid
        if uid:
            event["user_id"] = uid
        if sid:
            event["session_id"] = sid
        if props:
            event["properties"] = props
        if context is not None:
            ctx = context.to_dict()
            if ctx:
                event["context"] = ctx

        # Serileştirme kuyruğa eklemeden önce yapılır; bozuk bir olay batch'i zehirleyemez.
        try:
            raw = json.dumps(event, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
        except (TypeError, ValueError) as exc:
            raise InvalidEventError("olay JSON'a dönüştürülemedi: %s" % (exc,)) from exc

        with self._lock:
            if self._closed:
                raise ClientClosedError("istemci kapatıldı")
            self._queue.append((event["event_id"], raw))
            over = len(self._queue) - self._queue_limit
            if over > 0:
                del self._queue[:over]
                self._dropped += over
                _log.warning("feralin: kuyruk sınırı aşıldı, en eski %d olay atıldı", over)
            full = len(self._queue) >= self._batch_size
        if full and self._thread is not None:
            self._wake.set()
        return event

    def flush(self) -> FlushResult:
        """Kuyruktaki tüm olayları batch'ler hâlinde gönderir (backoff beklemez; açık çağrı niyet sayılır).

        Fırlatmaz: sonuç FlushResult.error içinde döner (RejectedError → olaylar atıldı; TemporaryError →
        olaylar kuyrukta kaldı). Kuyruk boşsa sıfır sonuç döner.
        """
        with self._lock:
            if self._closed:
                raise ClientClosedError("istemci kapatıldı")
        return self._flush(deadline=None)

    def close(self, timeout: float = CLOSE_TIMEOUT) -> FlushResult:
        """Arka plan göndericiyi durdurur ve kalan olayları en fazla `timeout` sn içinde göndermeyi dener.
        Birden çok çağrı güvenlidir; sonraki çağrılar boş sonuç döner."""
        with self._lock:
            if self._closed:
                return FlushResult()
            self._closed = True
        if self._thread is not None:
            self._stop = True
            self._wake.set()
            self._thread.join(timeout=max(timeout, self._timeout + 1.0))
        return self._flush(deadline=time.monotonic() + max(0.0, timeout))

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def __len__(self) -> int:
        with self._lock:
            return len(self._queue)

    def status(self) -> dict[str, Any]:
        """Anlık durum (debug/health amaçlı). Anahtar döndürülmez."""
        with self._lock:
            return {
                "sdk": SDK_NAME,
                "version": SDK_VERSION,
                "queued": len(self._queue),
                "dropped": self._dropped,
                "consent": self._consent.to_dict(),
                "user_id": self._user_id,
                "closed": self._closed,
                "backoff": self._backoff,
                "endpoint": self._endpoint,
            }

    # ------------------------------------------------------------------ iç işleyiş

    def _run(self) -> None:
        # Arka plan gönderici: aralık dolunca veya kuyruk batch boyutuna ulaşınca gönderir, backoff'a uyar.
        while True:
            self._wake.wait(self._flush_interval)
            self._wake.clear()
            if self._stop:
                return
            with self._lock:
                waiting = time.monotonic() < self._backoff_until
            if waiting:
                continue
            try:
                self._flush(deadline=None)
            except Exception:  # noqa: BLE001 - arka plan iş parçacığı ölmesin
                _log.exception("feralin: arka plan gönderim hatası")

    def _flush(self, deadline: float | None) -> FlushResult:
        with self._send_lock:
            sent = accepted = rejected = 0
            batch_id: str | None = None
            status = 0
            error: Exception | None = None
            # Üretici sürekli ekliyorsa döngü sonsuz olmasın: kuyruk sınırı kadar olay + bir tur.
            max_rounds = self._queue_limit // self._batch_size + 2
            for _ in range(max_rounds):
                batch = self._peek()
                if not batch:
                    break
                timeout = self._timeout
                if deadline is not None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        error = TemporaryError("kapanış zaman aşımı; olaylar gönderilemedi", status=0)
                        break
                    timeout = min(timeout, remaining)
                result = self._send(batch, timeout)
                sent += result.sent
                accepted += result.accepted
                rejected += result.rejected
                status = result.status
                if result.batch_id:
                    batch_id = result.batch_id
                if result.error is not None:
                    error = result.error
                    break
            return FlushResult(
                sent=sent,
                accepted=accepted,
                rejected=rejected,
                batch_id=batch_id,
                status=status,
                retained=len(self),
                error=error,
            )

    def _peek(self) -> list[tuple[str, bytes]]:
        with self._lock:
            if self._pinned is not None:
                return self._pinned
            return list(self._queue[: self._batch_size])

    def _ack(self, ids: set[str]) -> None:
        with self._lock:
            self._pinned = None
            self._queue = [item for item in self._queue if item[0] not in ids]

    def _pin(self, batch: list[tuple[str, bytes]]) -> None:
        # İstek sürerken izin geri çekildiyse olaylar çoktan silinmiştir, sabitlenmez.
        with self._lock:
            if self._consent.analytics:
                self._pinned = batch

    def _send(self, batch: list[tuple[str, bytes]], timeout: float) -> FlushResult:
        n = len(batch)
        ids = {item[0] for item in batch}
        # Olaylar zaten serileştirilmiş; gövde metin birleştirme ile kurulur.
        events_json = b",".join(item[1] for item in batch)
        body = (
            b'{"sent_at":' + json.dumps(format_time(self._now())).encode("ascii") + b',"events":[' + events_json + b"]}"
        )
        idempotency_key = idempotency_key_for([item[0] for item in batch])
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, application/problem+json",
            "X-Feralin-Project-Key": self._project_key,
            "Idempotency-Key": idempotency_key,
            "User-Agent": SDK_NAME + "/" + SDK_VERSION,
        }
        try:
            status, raw, resp_headers = self._transport(self._endpoint, body, headers, timeout)
        except TemporaryError as exc:
            self._pin(batch)
            self._note_failure(None)
            return FlushResult(sent=n, retained=n, status=0, error=exc)
        except DeliveryError as exc:
            self._pin(batch)
            self._note_failure(None)
            return FlushResult(sent=n, retained=n, status=exc.status, error=exc)

        if status == 202:
            ack: dict[str, Any] = {}
            try:
                parsed = json.loads(raw.decode("utf-8") or "{}")
                if isinstance(parsed, dict):
                    ack = parsed
            except (UnicodeDecodeError, ValueError):
                ack = {}
            self._ack(ids)
            self._note_success()
            acc = ack.get("accepted")
            rej = ack.get("rejected")
            result = FlushResult(
                sent=n,
                accepted=acc if isinstance(acc, int) else n,
                rejected=rej if isinstance(rej, int) else 0,
                batch_id=ack.get("batch_id") if isinstance(ack.get("batch_id"), str) else None,
                status=status,
            )
            _log.debug("feralin: batch kabul edildi batch_id=%s accepted=%d rejected=%d", result.batch_id, result.accepted, result.rejected)
            return result

        if 400 <= status < 500 and status != 429:
            self._ack(ids)
            summary = _problem_summary(raw)
            _log.warning("feralin: batch kalıcı olarak reddedildi status=%d problem=%s", status, summary)
            return FlushResult(
                sent=n,
                rejected=n,
                status=status,
                error=RejectedError("HTTP %d: %s" % (status, summary), status=status, detail=summary),
            )

        retry_after = _header(resp_headers, "Retry-After")
        self._pin(batch)
        self._note_failure(retry_after)
        return FlushResult(
            sent=n,
            retained=n,
            status=status,
            error=TemporaryError("HTTP %d; olaylar kuyrukta tutuldu" % status, status=status),
        )

    def _note_failure(self, retry_after: str | None) -> None:
        # Üstel backoff 1 sn → 30 sn; Retry-After verilmişse en az o kadar bekle.
        # Yarım jitter: aynı anda yeniden başlayan süreçler toplayıcıya birlikte yüklenmez.
        with self._lock:
            nxt = max(self._backoff * 2, _MIN_BACKOFF)
            floor = 0.0
            if retry_after:
                try:
                    secs = int(retry_after.strip())
                    if secs > 0:
                        floor = min(float(secs), _MAX_BACKOFF)
                        nxt = max(nxt, float(secs))
                except ValueError:
                    pass
            nxt = min(nxt, _MAX_BACKOFF)
            self._backoff = nxt
            self._backoff_until = time.monotonic() + max(floor, nxt * (0.5 + random.random() * 0.5))

    def _note_success(self) -> None:
        with self._lock:
            self._backoff = 0.0
            self._backoff_until = 0.0


def _header(headers: Mapping[str, str], name: str) -> str | None:
    lowered = name.lower()
    for key, value in headers.items():
        if key.lower() == lowered:
            return value
    return None


def _problem_summary(raw: bytes) -> str:
    """RFC 7807 gövdesinden kısa, loglanabilir özet (ham gövde sızdırılmaz)."""
    try:
        problem = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return "problem+json yok"
    if not isinstance(problem, dict):
        return "problem+json yok"
    text = " ".join(str(problem.get(k, "")).strip() for k in ("title", "detail")).strip()
    return text[:200] if text else "problem+json yok"
