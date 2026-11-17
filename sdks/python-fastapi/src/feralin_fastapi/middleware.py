"""Saf ASGI ara katmanı: FastAPI ve Starlette ile çalışır, yanıt akışına dokunmaz. Her HTTP isteğine `request.state.feralin`
ekler. Olay üretimi ağa çıkmaz, arka plan iş parçacığı gönderir. Uygulama kapanırken (lifespan) kuyruk gönderilir.

Örnek::

    app = FastAPI()
    app.add_middleware(
        FeralinMiddleware,
        project_key=os.environ["FERALIN_PROJECT_KEY"],   # yalnız pk_ anahtarı
        collect_url="https://collect.example.com",
        resolve_consent=izin_cozumleyici,                # Request -> feralin.Consent; sync veya async; yoksa izin yok
    )

    @app.post("/siparis")
    def siparis(feralin: RequestFeralin = Depends(get_feralin)):
        feralin.track("order_completed", {"order_id": "ord_1"})
"""

from __future__ import annotations

import asyncio
import inspect
import logging
from typing import Any, Callable

from feralin import Consent, Context
from starlette.requests import HTTPConnection, Request

from ._core import ConsentClientPool, RequestFeralin, clean_context, consent_or_none, resolve_safely

_log = logging.getLogger("feralin")

_NOOP = RequestFeralin(pool=None, consent=Consent())


async def _resolve(resolver: Callable[[Any], Any] | None, connection: HTTPConnection) -> Any:
    value = resolve_safely(resolver, connection)
    if inspect.isawaitable(value):
        try:
            return await value
        except Exception as exc:  # noqa: BLE001 - uygulama kodu her hatayı atabilir, istek düşmemeli
            _log.warning("feralin: çözümleyici hata verdi: %s", type(exc).__name__)
            return None
    return value


class FeralinMiddleware:
    def __init__(
        self,
        app: Any,
        *,
        project_key: str | None = None,
        collect_url: str | None = None,
        pool: ConsentClientPool | None = None,
        resolve_consent: Callable[[Any], Any] | None = None,
        resolve_user_id: Callable[[Any], Any] | None = None,
        resolve_anonymous_id: Callable[[Any], Any] | None = None,
        resolve_session_id: Callable[[Any], Any] | None = None,
        include_context: bool = True,
        **client_options: Any,
    ) -> None:
        self.app = app
        if pool is None:
            if not project_key or not collect_url:
                raise ValueError("project_key ve collect_url zorunlu (veya pool verin)")
            pool = ConsentClientPool(project_key, collect_url, **client_options)
        self.pool = pool
        self.resolve_consent = resolve_consent
        self.resolve_user_id = resolve_user_id
        self.resolve_anonymous_id = resolve_anonymous_id
        self.resolve_session_id = resolve_session_id
        self.include_context = include_context

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] == "http":
            scope.setdefault("state", {})["feralin"] = await self._bind(Request(scope))
        elif scope["type"] == "lifespan":
            receive = self._closing_receive(receive)
        await self.app(scope, receive, send)

    def _closing_receive(self, receive: Any) -> Any:
        async def wrapped() -> Any:
            message = await receive()
            if message.get("type") == "lifespan.shutdown":
                # Ağ çağrısı olay döngüsünü kilitlemesin.
                await asyncio.to_thread(self.pool.close)
            return message

        return wrapped

    async def _bind(self, request: Request) -> RequestFeralin:
        consent = consent_or_none(await _resolve(self.resolve_consent, request))
        context = self._context(request) if self.include_context and consent.analytics else None
        return RequestFeralin(
            pool=self.pool,
            consent=consent,
            user_id=await _resolve(self.resolve_user_id, request),
            anonymous_id=await _resolve(self.resolve_anonymous_id, request),
            session_id=await _resolve(self.resolve_session_id, request),
            context=context,
        )

    @staticmethod
    def _context(request: Request) -> Context | None:
        try:
            url = request.url
            scheme, host, path = url.scheme, url.netloc, url.path
        except ValueError:
            # Starlette adresi Host başlığından kurar; `Host: [x` urlsplit'te hata verir. Bağlam gitmez, istek etkilenmez.
            scheme = host = path = None
        return clean_context(scheme, host, path, request.headers.get("referer"), request.headers.get("accept-language"))


def get_feralin(request: Request) -> RequestFeralin:
    """FastAPI bağımlılığı: `feralin: RequestFeralin = Depends(get_feralin)`. Ara katman yoksa olay üretmeyen yüzey döner."""
    return getattr(request.state, "feralin", _NOOP)
