"""Django ara katmanı. WSGI ve ASGI altında çalışır; her isteğe `request.feralin` ekler. Olay üretimi ağa çıkmaz, arka plan
iş parçacığı gönderir. Süreç çıkışında kuyruk `atexit` ile gönderilmeye çalışılır.

Ayarlar::

    FERALIN = {
        "PROJECT_KEY": os.environ["FERALIN_PROJECT_KEY"],   # yalnız pk_ anahtarı
        "COLLECT_URL": "https://collect.example.com",
        "CONSENT_RESOLVER": "uygulama.feralin.izin",        # request -> feralin.Consent; yoksa izin yok
        "USER_ID_RESOLVER": "uygulama.feralin.kullanici",   # isteğe bağlı; e-posta veya telefon döndürmeyin
        "ANONYMOUS_ID_RESOLVER": None,
        "SESSION_ID_RESOLVER": None,
        "INCLUDE_CONTEXT": True,                            # yolda kişisel veri varsa kapatın
        "CLIENT_OPTIONS": {},                               # feralin.Client seçenekleri
    }
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from typing import Any

from asgiref.sync import iscoroutinefunction, markcoroutinefunction
from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.http import HttpRequest, HttpResponse
from django.utils.module_loading import import_string

from ._core import ConsentClientPool, RequestFeralin, clean_context, consent_or_none, resolve_safely

_pool: ConsentClientPool | None = None
_pool_lock = threading.Lock()


def _config() -> dict[str, Any]:
    config = getattr(settings, "FERALIN", None)
    if not isinstance(config, dict) or not config.get("PROJECT_KEY") or not config.get("COLLECT_URL"):
        raise ImproperlyConfigured("FERALIN ayarı PROJECT_KEY ve COLLECT_URL içermeli")
    return config


def _callable(value: Any) -> Callable[[HttpRequest], Any] | None:
    return import_string(value) if isinstance(value, str) else value


def get_pool() -> ConsentClientPool:
    """Süreç başına tek havuz. İstek dışı kod (Celery görevi, yönetim komutu) da bunu kullanır: `get_pool().track(consent, ...)`."""
    global _pool
    with _pool_lock:
        if _pool is None:
            config = _config()
            _pool = ConsentClientPool(config["PROJECT_KEY"], config["COLLECT_URL"], **config.get("CLIENT_OPTIONS", {}))
        return _pool


def reset_pool() -> None:
    """Havuzu kapatır; sonraki çağrı ayarlardan yeniden kurar. Testler ve otomatik yeniden yükleme içindir."""
    global _pool
    with _pool_lock:
        pool, _pool = _pool, None
    if pool is not None:
        pool.close()


class FeralinMiddleware:
    sync_capable = True
    async_capable = True

    def __init__(self, get_response: Callable[[HttpRequest], Any]) -> None:
        self.get_response = get_response
        self.is_async = iscoroutinefunction(get_response)
        if self.is_async:
            markcoroutinefunction(self)
        config = _config()
        self.pool = get_pool()
        self.resolve_consent = _callable(config.get("CONSENT_RESOLVER"))
        self.resolve_user_id = _callable(config.get("USER_ID_RESOLVER"))
        self.resolve_anonymous_id = _callable(config.get("ANONYMOUS_ID_RESOLVER"))
        self.resolve_session_id = _callable(config.get("SESSION_ID_RESOLVER"))
        self.include_context = config.get("INCLUDE_CONTEXT", True)

    def __call__(self, request: HttpRequest) -> Any:
        request.feralin = self._bind(request)  # type: ignore[attr-defined]
        return self.__acall__(request) if self.is_async else self.get_response(request)

    async def __acall__(self, request: HttpRequest) -> HttpResponse:
        return await self.get_response(request)

    def _bind(self, request: HttpRequest) -> RequestFeralin:
        consent = consent_or_none(resolve_safely(self.resolve_consent, request))
        context = self._context(request) if self.include_context and consent.analytics else None
        return RequestFeralin(
            pool=self.pool,
            consent=consent,
            user_id=resolve_safely(self.resolve_user_id, request),
            anonymous_id=resolve_safely(self.resolve_anonymous_id, request),
            session_id=resolve_safely(self.resolve_session_id, request),
            context=context,
        )

    @staticmethod
    def _context(request: HttpRequest) -> Any:
        try:
            host = request.get_host()
        except Exception:  # noqa: BLE001 - ALLOWED_HOSTS dışı Host: bağlam gönderilmez, istek Django'nun kendi akışında kalır
            host = None
        return clean_context(request.scheme, host, request.path, request.headers.get("Referer"), request.headers.get("Accept-Language"))
