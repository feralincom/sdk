"""HTTP taşıma katmanı: yalnız urllib. Testler ve özel ağ yığınları için Transport imzasıyla değiştirilebilir."""

from __future__ import annotations

import http.client
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping

from .errors import TemporaryError

# (url, body, headers, timeout_seconds) -> (status, body, response_headers)
Transport = Callable[[str, bytes, Mapping[str, str], float], tuple[int, bytes, Mapping[str, str]]]

MAX_RESPONSE_BODY = 64 * 1024


def urllib_transport(
    url: str, body: bytes, headers: Mapping[str, str], timeout: float
) -> tuple[int, bytes, Mapping[str, str]]:
    """POST isteği yapar. HTTP hata kodları normal yanıt olarak döner; ağ/zaman aşımı TemporaryError fırlatır."""
    request = urllib.request.Request(url, data=body, method="POST", headers=dict(headers))
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 - url yapılandırmadan gelir
            return response.status, response.read(MAX_RESPONSE_BODY), dict(response.headers.items())
    except urllib.error.HTTPError as exc:
        payload = exc.read(MAX_RESPONSE_BODY) if exc.fp is not None else b""
        return exc.code, payload, dict(exc.headers.items()) if exc.headers is not None else {}
    except (urllib.error.URLError, http.client.HTTPException, TimeoutError, OSError) as exc:
        raise TemporaryError("ağ hatası: %s" % (exc,), status=0) from exc
