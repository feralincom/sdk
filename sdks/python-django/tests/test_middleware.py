"""Gerçek Django istek zinciri (sync ve async); yalnız çekirdeğin transport'u enjekte edilir."""

from __future__ import annotations

import asyncio
import json
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
for path in (ROOT / "src", ROOT.parent / "python" / "src"):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import django  # noqa: E402
from django.conf import settings  # noqa: E402

KEY = "pk_test_django_unit_0001"
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


def consent_from_header(request):
    from feralin import Consent

    return Consent(analytics=request.headers.get("X-Izin") == "evet", advertising=request.headers.get("X-Reklam") == "evet")


def broken_resolver(request):
    raise RuntimeError("CMP yok")


def user_from_header(request):
    return request.headers.get("X-Kullanici")


if not settings.configured:
    settings.configure(
        SECRET_KEY="test",
        ALLOWED_HOSTS=["*"],
        ROOT_URLCONF=__name__,
        MIDDLEWARE=["feralin_django.FeralinMiddleware"],
        FERALIN={"PROJECT_KEY": KEY, "COLLECT_URL": COLLECT},
    )
    django.setup()

from django.http import JsonResponse  # noqa: E402
from django.test import AsyncClient, Client as DjangoClient, override_settings  # noqa: E402
from django.urls import path  # noqa: E402
from feralin import Consent  # noqa: E402
from feralin_django import clean_context, get_pool, reset_pool  # noqa: E402


def order_view(request, order_id):
    event = request.feralin.track("order_completed", {"order_id": order_id, "fr_click": "clk_1"})
    return JsonResponse({"event": event})


async def async_order_view(request, order_id):
    event = request.feralin.track("order_completed", {"order_id": order_id})
    return JsonResponse({"event": event})


def invalid_view(request):
    return JsonResponse({"event": request.feralin.track("Bad-Name")})


urlpatterns = [
    path("siparis/<str:order_id>", order_view),
    path("async/<str:order_id>", async_order_view),
    path("gecersiz", invalid_view),
]


def config(transport, **extra):
    return {
        "PROJECT_KEY": KEY,
        "COLLECT_URL": COLLECT,
        "CONSENT_RESOLVER": consent_from_header,
        "CLIENT_OPTIONS": {"transport": transport, "flush_interval": 0},
        **extra,
    }


class Base(unittest.TestCase):
    def setUp(self):
        reset_pool()
        self.addCleanup(reset_pool)


class MiddlewareTests(Base):
    def test_izin_yokken_olay_uretilmez_istek_basarili(self):
        transport = Transport()
        with override_settings(FERALIN=config(transport)):
            response = DjangoClient().get("/siparis/1")
            self.assertEqual(response.status_code, 200)
            self.assertIsNone(response.json()["event"])
            self.assertEqual(get_pool().flush().sent, 0)
        self.assertEqual(transport.calls, [])

    def test_istek_basina_izin_ayri_gider_paylasilan_durum_bozulmaz(self):
        transport = Transport()
        with override_settings(FERALIN=config(transport, USER_ID_RESOLVER=user_from_header)):
            client = DjangoClient()
            reklamli = client.get("/siparis/1?token=GIZLI", headers={"X-Izin": "evet", "X-Reklam": "evet", "X-Kullanici": "user_42", "Referer": "https://ref.example.test/a?b=GIZLI", "Accept-Language": "tr-TR,tr;q=0.9"}).json()["event"]
            reklamsiz = client.get("/siparis/2", headers={"X-Izin": "evet"}).json()["event"]
            izinsiz = client.get("/siparis/3").json()["event"]
            result = get_pool().flush()
        self.assertEqual(reklamli["properties"]["fr_click"], "clk_1")
        self.assertEqual(reklamli["user_id"], "user_42")
        self.assertEqual(reklamli["consent"]["advertising"], True)
        self.assertNotIn("fr_click", reklamsiz["properties"])
        self.assertNotIn("user_id", reklamsiz)
        self.assertEqual(reklamsiz["consent"]["advertising"], False)
        self.assertIsNone(izinsiz)
        self.assertEqual([result.sent, result.accepted, result.status], [2, 2, 202])
        self.assertEqual(len(transport.calls), 2)
        self.assertEqual(transport.calls[0]["url"], "http://collector.test/v1/batch")
        self.assertEqual(transport.calls[0]["headers"]["X-Feralin-Project-Key"], KEY)
        raw = json.dumps(transport.calls)
        self.assertNotIn("GIZLI", raw)
        self.assertNotIn("verified", raw)
        context = reklamli["context"]
        self.assertEqual(context["page_url"], "http://testserver/siparis/1")
        self.assertEqual(context["referrer"], "https://ref.example.test")
        self.assertEqual(context["locale"], "tr-TR")

    def test_cozumleyici_hatasi_izin_yok_sayilir(self):
        with override_settings(FERALIN=config(Transport(), CONSENT_RESOLVER=broken_resolver)):
            with self.assertLogs("feralin", level="WARNING"):
                response = DjangoClient().get("/siparis/1")
        self.assertEqual(response.status_code, 200)
        self.assertIsNone(response.json()["event"])

    def test_dotted_path_cozumleyici(self):
        with override_settings(FERALIN=config(Transport(), CONSENT_RESOLVER=__name__ + ".consent_from_header")):
            response = DjangoClient().get("/siparis/1", headers={"X-Izin": "evet"})
        self.assertIsNotNone(response.json()["event"])

    def test_gecersiz_olay_uygulamayi_dusurmez(self):
        with override_settings(FERALIN=config(Transport())):
            with self.assertLogs("feralin", level="WARNING"):
                response = DjangoClient().get("/gecersiz", headers={"X-Izin": "evet"})
        self.assertEqual(response.status_code, 200)
        self.assertIsNone(response.json()["event"])

    def test_baglam_kapatilabilir(self):
        with override_settings(FERALIN=config(Transport(), INCLUDE_CONTEXT=False)):
            event = DjangoClient().get("/siparis/1", headers={"X-Izin": "evet"}).json()["event"]
        self.assertNotIn("context", event)

    def test_saldirgan_baslik_batch_dusurmez_istek_etkilenmez(self):
        transport = Transport()
        with override_settings(FERALIN=config(transport)):
            client = DjangoClient()
            uzun = client.get("/siparis/1", headers={"X-Izin": "evet", "Referer": "https://" + "r" * 3000 + ".example.test/"})
            bozuk = client.get("/siparis/2", headers={"X-Izin": "evet", "Host": "a b"})
            yuzde = client.get("/siparis/yuzde%25", headers={"X-Izin": "evet"})
        self.assertEqual([uzun.status_code, bozuk.status_code, yuzde.status_code], [200, 200, 200])
        self.assertNotIn("referrer", uzun.json()["event"]["context"])
        self.assertNotIn("context", bozuk.json()["event"])
        self.assertEqual(yuzde.json()["event"]["context"]["page_url"], "http://testserver/siparis/yuzde%25")
        for response in (uzun, yuzde):
            assert_schema_context(self, response.json()["event"]["context"])

    def test_async_zincir(self):
        transport = Transport()

        async def scenario():
            client = AsyncClient()
            return await client.get("/async/9", headers={"X-Izin": "evet"})

        with override_settings(FERALIN=config(transport)):
            response = asyncio.run(scenario())
            self.assertIsNotNone(response.json()["event"])
            self.assertEqual(get_pool().flush().status, 202)

    def test_eksik_ayar_ve_gizli_anahtar_acilista_reddedilir(self):
        from django.core.exceptions import ImproperlyConfigured
        from feralin import ConfigurationError

        with override_settings(FERALIN={}):
            with self.assertRaises(ImproperlyConfigured):
                DjangoClient().get("/siparis/1")
        reset_pool()
        with override_settings(FERALIN={"PROJECT_KEY": "sk_live_gizli_0001", "COLLECT_URL": COLLECT}):
            with self.assertRaises(ConfigurationError):
                get_pool()


class PoolTests(Base):
    def test_401_kuyrugu_atar_ag_hatasi_tutar_ayni_anahtarla_dener(self):
        from feralin import TemporaryError

        rejected = Transport([(401, b'{"title":"bad key"}', {})])
        with override_settings(FERALIN=config(rejected)):
            pool = get_pool()
            pool.track(Consent(analytics=True), "order_completed")
            result = pool.flush()
            self.assertEqual([result.status, result.rejected, result.retained], [401, 1, 0])
        reset_pool()

        flaky = Transport([TemporaryError("ağ yok", status=0)])
        with override_settings(FERALIN=config(flaky)):
            pool = get_pool()
            pool.track(Consent(analytics=True), "order_completed")
            lost = pool.flush()
            self.assertEqual([lost.status, lost.retained], [0, 1])
            pool.track(Consent(analytics=True), "order_shipped")
            self.assertEqual(pool.flush().status, 202)
        keys = [call["headers"]["Idempotency-Key"] for call in flaky.calls]
        self.assertEqual(keys[0], keys[1])

    def test_izin_degeri_basina_tek_istemci(self):
        with override_settings(FERALIN=config(Transport())):
            pool = get_pool()
            first = pool.client_for(Consent(analytics=True))
            self.assertIs(first, pool.client_for(Consent(analytics=True)))
            self.assertIsNot(first, pool.client_for(Consent(analytics=True, advertising=True)))
            self.assertIsNone(pool.client_for(Consent()))

    def test_kapanis_kuyrugu_gonderir_ve_sonra_olay_uretmez(self):
        transport = Transport()
        with override_settings(FERALIN=config(transport)):
            pool = get_pool()
            pool.track(Consent(analytics=True), "order_completed")
            pool.close()
            pool.close()
            self.assertEqual(len(transport.calls), 1)
            self.assertIsNone(pool.track(Consent(analytics=True), "order_completed"))


class ContextTests(unittest.TestCase):
    def test_gecersiz_alanlar_gonderilmez(self):
        self.assertIsNone(clean_context("ftp", "h", "/", None, None))
        self.assertIsNone(clean_context(None, None, None, "javascript:alert(1)", "*"))
        context = clean_context("https", "h.example.test", "/ç a?x=1#y".split("?")[0], "https://u:p@ref.example.test/x", "en")
        self.assertEqual(context.page_url, "https://h.example.test/%C3%A7%20a")
        self.assertEqual(context.referrer, "https://ref.example.test")
        self.assertEqual(context.locale, "en")
        self.assertIsNone(clean_context("https", "h", "/" + "a" * 3000, None, "x" * 40))

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
    def test_ortak_katman_fastapi_ile_ayni(self):
        here = (ROOT / "src" / "feralin_django" / "_core.py").read_bytes()
        other = (ROOT.parent / "python-fastapi" / "src" / "feralin_fastapi" / "_core.py").read_bytes()
        self.assertEqual(here, other)


if __name__ == "__main__":
    unittest.main()
