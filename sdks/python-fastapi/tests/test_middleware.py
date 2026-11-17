"""Gerçek FastAPI uygulaması ve TestClient; yalnız çekirdeğin transport'u enjekte edilir."""

from __future__ import annotations

import json
import pathlib
import re
import sys
import unittest
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[1]
for path in (ROOT / "src", ROOT.parent / "python" / "src"):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from fastapi import Depends, FastAPI, Request  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from feralin import ConfigurationError, Consent, TemporaryError  # noqa: E402
from feralin_fastapi import ConsentClientPool, FeralinMiddleware, RequestFeralin, clean_context, get_feralin  # noqa: E402

KEY = "pk_test_fastapi_unit_001"
COLLECT = "http://collector.test"

# Kanonik şema; bağlam alanları toplayıcıdaki sınırlarla aynı yerden okunur.
CONTEXT_SCHEMA = json.loads((ROOT.parents[1] / "packages/schemas/utp/v1/event.schema.json").read_text(encoding="utf-8"))["properties"]["context"]["properties"]
# Toplayıcının `format: uri` denetimi Go net/url.Parse'tır; bu desen onun kabul ettiklerinin dar alt kümesidir.
PAGE_URL = re.compile(r"^https?://[A-Za-z0-9._~-]+(:[0-9]+)?(/([A-Za-z0-9._~!$&'()*+,;=:@/-]|%[0-9A-Fa-f]{2})*)?$")


def assert_schema_context(case, context):
    """Bağlam şemadan geçmeli: tek geçersiz alan toplayıcıda tüm batch'i 400 ile düşürür."""
    for field, value in context.items():
        case.assertIn(field, CONTEXT_SCHEMA)
        case.assertLessEqual(len(value), CONTEXT_SCHEMA[field]["maxLength"], field)
    if "page_url" in context:
        case.assertRegex(context["page_url"], PAGE_URL)



class Transport:
    def __init__(self, responses=None):
        self.calls = []
        self.responses = list(responses or [])

    def __call__(self, url, data, headers, timeout):
        self.calls.append({"url": url, "headers": headers, "events": json.loads(data)["events"]})
        response = self.responses.pop(0) if self.responses else None
        if isinstance(response, Exception):
            raise response
        if response is not None:
            return response
        return 202, json.dumps({"batch_id": "b%d" % len(self.calls), "accepted": len(self.calls[-1]["events"]), "rejected": 0}).encode(), {}


def consent_from_header(request: Request) -> Consent:
    return Consent(analytics=request.headers.get("x-izin") == "evet", advertising=request.headers.get("x-reklam") == "evet")


def make_app(transport, **options):
    app = FastAPI()
    options.setdefault("resolve_consent", consent_from_header)
    app.add_middleware(FeralinMiddleware, project_key=KEY, collect_url=COLLECT, flush_interval=0, transport=transport, **options)

    @app.get("/sync/{order_id}")
    def sync_route(order_id: str, feralin: RequestFeralin = Depends(get_feralin)):
        return {"event": feralin.track("order_completed", {"order_id": order_id, "fr_click": "clk_1"})}

    @app.get("/async/{order_id}")
    async def async_route(order_id: str, feralin: RequestFeralin = Depends(get_feralin)):
        return {"event": feralin.track("order_completed", {"order_id": order_id})}

    @app.get("/durum")
    def state_route(request: Request):
        return {"analytics": request.state.feralin.consent.analytics}

    @app.get("/gecersiz")
    def invalid_route(feralin: RequestFeralin = Depends(get_feralin)):
        return {"event": feralin.track("Bad-Name")}

    return app


class MiddlewareTests(unittest.TestCase):
    def test_izin_yokken_olay_uretilmez_istek_basarili(self):
        transport = Transport()
        with TestClient(make_app(transport)) as client:
            response = client.get("/sync/1")
            self.assertEqual(response.status_code, 200)
            self.assertIsNone(response.json()["event"])
        self.assertEqual(transport.calls, [])

    def test_istek_basina_izin_ayri_gider_kapanista_gonderilir(self):
        transport = Transport()
        with TestClient(make_app(transport, resolve_user_id=lambda request: request.headers.get("x-kullanici"))) as client:
            reklamli = client.get("/sync/1?token=GIZLI", headers={"x-izin": "evet", "x-reklam": "evet", "x-kullanici": "user_42", "referer": "https://ref.example.test/a?b=GIZLI", "accept-language": "tr-TR,tr;q=0.9"}).json()["event"]
            reklamsiz = client.get("/sync/2", headers={"x-izin": "evet"}).json()["event"]
            self.assertIsNone(client.get("/sync/3").json()["event"])
            self.assertEqual(transport.calls, [])
        self.assertEqual(reklamli["properties"]["fr_click"], "clk_1")
        self.assertEqual(reklamli["user_id"], "user_42")
        self.assertNotIn("fr_click", reklamsiz["properties"])
        self.assertNotIn("user_id", reklamsiz)
        self.assertEqual(len(transport.calls), 2)
        self.assertEqual(transport.calls[0]["url"], "http://collector.test/v1/batch")
        self.assertEqual(transport.calls[0]["headers"]["X-Feralin-Project-Key"], KEY)
        raw = json.dumps(transport.calls)
        self.assertNotIn("GIZLI", raw)
        self.assertNotIn("verified", raw)
        context = reklamli["context"]
        self.assertEqual(context["page_url"], "http://testserver/sync/1")
        self.assertEqual(context["referrer"], "https://ref.example.test")
        self.assertEqual(context["locale"], "tr-TR")

    def test_async_cozumleyici_ve_async_rota(self):
        async def resolver(request):
            return Consent(analytics=True)

        with TestClient(make_app(Transport(), resolve_consent=resolver)) as client:
            self.assertIsNotNone(client.get("/async/1").json()["event"])
            self.assertEqual(client.get("/durum").json(), {"analytics": True})

    def test_cozumleyici_hatasi_izin_yok_sayilir(self):
        def broken(request):
            raise RuntimeError("CMP yok")

        async def broken_async(request):
            raise RuntimeError("CMP yok")

        for resolver in (broken, broken_async):
            with TestClient(make_app(Transport(), resolve_consent=resolver)) as client:
                with self.assertLogs("feralin", level="WARNING"):
                    response = client.get("/sync/1")
                self.assertEqual(response.status_code, 200)
                self.assertIsNone(response.json()["event"])

    def test_gecersiz_olay_uygulamayi_dusurmez(self):
        with TestClient(make_app(Transport())) as client:
            with self.assertLogs("feralin", level="WARNING"):
                response = client.get("/gecersiz", headers={"x-izin": "evet"})
            self.assertEqual(response.status_code, 200)
            self.assertIsNone(response.json()["event"])

    def test_baglam_kapatilabilir(self):
        with TestClient(make_app(Transport(), include_context=False)) as client:
            event = client.get("/sync/1", headers={"x-izin": "evet"}).json()["event"]
        self.assertNotIn("context", event)

    def test_saldirgan_baslik_batch_dusurmez_istek_etkilenmez(self):
        with TestClient(make_app(Transport())) as client:
            uzun = client.get("/sync/1", headers={"x-izin": "evet", "referer": "https://" + "r" * 3000 + ".example.test/"})
            self.assertEqual(uzun.status_code, 200)
            self.assertNotIn("referrer", uzun.json()["event"]["context"])
            assert_schema_context(self, uzun.json()["event"]["context"])
            # Güncel Starlette geçersiz Host yerine sunucu adresini kullanır; sonuç her durumda şemadan geçmeli.
            for host in ("a b", "a<b>", "h:port", "[bad"):
                response = client.get("/sync/2", headers={"x-izin": "evet", "host": host})
                self.assertEqual(response.status_code, 200, host)
                assert_schema_context(self, response.json()["event"].get("context", {}))
            yuzde = client.get("/sync/yuzde%25", headers={"x-izin": "evet"})
            self.assertEqual(yuzde.json()["event"]["context"]["page_url"], "http://testserver/sync/yuzde%25")

    def test_eski_starlette_ham_host_ile_baglam_gitmez(self):
        # fastapi>=0.100 aralığındaki eski Starlette adresi Host başlığından doğrudan kurar.
        class Patlayan:
            headers = {}

            @property
            def url(self):
                raise ValueError("Invalid IPv6 URL")

        self.assertIsNone(FeralinMiddleware._context(Patlayan()))
        ham = SimpleNamespace(headers={}, url=SimpleNamespace(scheme="http", netloc="a b", path="/x"))
        self.assertIsNone(FeralinMiddleware._context(ham))

    def test_ara_katman_yoksa_bagimlilik_olay_uretmez(self):
        app = FastAPI()

        @app.get("/")
        def route(feralin: RequestFeralin = Depends(get_feralin)):
            return {"event": feralin.track("x_event"), "sent": feralin.flush().sent}

        self.assertEqual(TestClient(app).get("/").json(), {"event": None, "sent": 0})

    def test_gizli_anahtar_ve_eksik_ayar_acilista_reddedilir(self):
        with self.assertRaises(ConfigurationError):
            FeralinMiddleware(None, project_key="sk_live_gizli_0001", collect_url=COLLECT)
        with self.assertRaises(ValueError):
            FeralinMiddleware(None)


class PoolTests(unittest.TestCase):
    def test_401_kuyrugu_atar_ag_hatasi_tutar_ayni_anahtarla_dener(self):
        rejected = Transport([(401, b'{"title":"bad key"}', {})])
        pool = ConsentClientPool(KEY, COLLECT, flush_interval=0, transport=rejected)
        pool.track(Consent(analytics=True), "order_completed")
        result = pool.flush()
        self.assertEqual([result.status, result.rejected, result.retained], [401, 1, 0])
        pool.close()

        flaky = Transport([TemporaryError("ağ yok", status=0)])
        pool = ConsentClientPool(KEY, COLLECT, flush_interval=0, transport=flaky)
        pool.track(Consent(analytics=True), "order_completed")
        lost = pool.flush()
        self.assertEqual([lost.status, lost.retained], [0, 1])
        pool.track(Consent(analytics=True), "order_shipped")
        self.assertEqual(pool.flush().status, 202)
        keys = [call["headers"]["Idempotency-Key"] for call in flaky.calls]
        self.assertEqual(keys[0], keys[1])
        pool.close()


class ContextTests(unittest.TestCase):
    def test_gecersiz_alanlar_gonderilmez(self):
        self.assertIsNone(clean_context("ftp", "h", "/", None, None))
        self.assertIsNone(clean_context(None, None, None, "javascript:alert(1)", "*"))
        context = clean_context("https", "h.example.test", "/ç a", "https://u:p@ref.example.test/x", "en")
        self.assertEqual(context.page_url, "https://h.example.test/%C3%A7%20a")
        self.assertEqual(context.referrer, "https://ref.example.test")

    def test_saldirgan_baglami_semadan_gecer(self):
        uzun_referrer = "https://" + "r" * 3000 + ".example.test/x"
        context = clean_context("https", "h.example.test", "/x", uzun_referrer, "tr")
        self.assertIsNone(context.referrer)
        self.assertEqual(context.page_url, "https://h.example.test/x")
        assert_schema_context(self, context.to_dict())
        for host in ("a b", "a<b>", "h:port", "h:80:90", "[::1", "[zz::1]", "hést", "a%zz", 'a"b'):
            self.assertIsNone(clean_context("http", host, "/x", None, None), host)
            self.assertIsNone(clean_context(None, None, None, "http://%s/x" % host, None), host)
        self.assertEqual(clean_context("http", "[::1]:8080", "/x", None, None).page_url, "http://[::1]:8080/x")
        self.assertEqual(clean_context(None, None, None, "https://[::1]/x", None).referrer, "https://[::1]")
        self.assertEqual(clean_context("http", "h:8080", "/100%", None, None).page_url, "http://h:8080/100%25")
        self.assertEqual(clean_context("http", "h", "/a%20b", None, None).page_url, "http://h/a%20b")
        self.assertIsNone(clean_context(None, None, None, None, "tr\u0000x"))
        self.assertIsNone(clean_context(None, None, None, None, "t r"))


class SharedCoreTests(unittest.TestCase):
    def test_ortak_katman_django_ile_ayni(self):
        here = (ROOT / "src" / "feralin_fastapi" / "_core.py").read_bytes()
        other = (ROOT.parent / "python-django" / "src" / "feralin_django" / "_core.py").read_bytes()
        self.assertEqual(here, other)


if __name__ == "__main__":
    unittest.main()
