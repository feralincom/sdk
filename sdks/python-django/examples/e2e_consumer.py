"""Gerçek services/collect tüketicisi: scripts/sdk-e2e/run.mjs python-django tarafından temiz sanal ortamda çalıştırılır.
İstekler Django'nun gerçek ara katman zincirinden geçer; denetim satırları outbox_check.go ile PostgreSQL üzerinde doğrulanır."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request

import django
from django.conf import settings

COLLECT_URL = os.environ["FERALIN_E2E_COLLECT_URL"]
PROJECT_KEY = os.environ["FERALIN_E2E_PROJECT_KEY"]
CHECKS = os.environ["FERALIN_E2E_CHECKS"]


def consent_from_header(request):
    from feralin import Consent

    return Consent(analytics=request.headers.get("X-Izin") == "evet", advertising=request.headers.get("X-Reklam") == "evet")


settings.configure(
    SECRET_KEY="e2e",
    ALLOWED_HOSTS=["*"],
    ROOT_URLCONF=__name__,
    MIDDLEWARE=["feralin_django.FeralinMiddleware"],
    FERALIN={"PROJECT_KEY": PROJECT_KEY, "COLLECT_URL": COLLECT_URL, "CONSENT_RESOLVER": consent_from_header, "CLIENT_OPTIONS": {"flush_interval": 0}},
)
django.setup()

from django.http import JsonResponse  # noqa: E402
from django.test import Client as DjangoClient, override_settings  # noqa: E402
from django.urls import path  # noqa: E402
from feralin.errors import TemporaryError  # noqa: E402
from feralin.events import idempotency_key_for  # noqa: E402
from feralin.transport import urllib_transport  # noqa: E402
from feralin_django import reset_pool  # noqa: E402


def olay(request):
    body = json.loads(request.body)
    event = request.feralin.track(body["name"], body.get("properties"))
    result = request.feralin.flush()
    return JsonResponse({"event": event, "status": result.status, "accepted": result.accepted, "rejected": result.rejected, "retained": result.retained, "sent": result.sent, "batch_id": result.batch_id})


urlpatterns = [path("olay", olay)]


def must(condition: bool, message: str) -> None:
    if not condition:
        sys.exit("KALDI: " + message)


def expect(line: str) -> None:
    with open(CHECKS, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def report(name: str, detail: object) -> None:
    print("  OK %s: %s" % (name, json.dumps(detail, ensure_ascii=False)))


def post(name, properties=None, analytics=False, advertising=False, extra_headers=None):
    headers = {"X-Izin": "evet" if analytics else "hayir", "X-Reklam": "evet" if advertising else "hayir", "Referer": "https://ref.example.test/?a=GIZLI", **(extra_headers or {})}
    response = DjangoClient().post("/olay?token=GIZLI", data=json.dumps({"name": name, "properties": properties}), content_type="application/json", headers=headers)
    must(response.status_code == 200, "uygulama yanıtı %d" % response.status_code)
    return response.json()


# 202 + outbox satırı + fr_click reklam izniyle
out = post("order_completed", {"order_id": "ord_dj_1", "fr_click": "clk_dj_1"}, analytics=True, advertising=True)
must(out["status"] == 202 and out["accepted"] == 1, "202 bekleniyordu")
expect("frclick %s" % out["batch_id"])
expect("once %s" % out["event"]["event_id"])
expect("platform python:%s" % out["event"]["event_id"])
report("202-outbox-frclick", {"status": out["status"], "batch_id": out["batch_id"]})

# Reklam izni yok: fr_click çıkarılır
out = post("order_completed", {"order_id": "ord_dj_2", "fr_click": "clk_dj_2"}, analytics=True)
must("fr_click" not in out["event"]["properties"], "fr_click çıkarılmalıydı")
must(out["status"] == 202, "202 bekleniyordu")
expect("nofrclick %s" % out["batch_id"])
report("frclick-izinsiz-cikarildi", {"status": out["status"]})

# Saldırgan başlık: şema sınırını aşan referrer ve bozuk Host batch'i düşürmez
out = post("order_completed", {"order_id": "ord_dj_uzun"}, analytics=True, extra_headers={"Referer": "https://" + "r" * 3000 + ".example.test/"})
must(out["status"] == 202 and out["accepted"] == 1 and "referrer" not in out["event"]["context"], "uzun referrer batch'i düşürmemeliydi")
expect("once %s" % out["event"]["event_id"])
out = post("order_completed", {"order_id": "ord_dj_host"}, analytics=True, extra_headers={"Host": "a b"})
must(out["status"] == 202 and out["accepted"] == 1 and "page_url" not in out["event"]["context"], "bozuk Host batch'i düşürmemeliydi")
expect("once %s" % out["event"]["event_id"])
report("saldirgan-baslik-202", {"status": out["status"]})

# İzinsiz: SDK olay üretmez
out = post("order_completed")
must(out["event"] is None and out["sent"] == 0, "izinsiz olay üretilmemeliydi")
report("izinsiz-sdk-uretmez", {"sent": 0})

# İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
event_id = ("01JCDJ%020d" % time.time_ns())[:26]
body = json.dumps({"events": [{"event_id": event_id, "event_name": "denied_event", "occurred_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "platform": "python", "schema_version": 1, "consent": {"analytics": False}}]}).encode()
request = urllib.request.Request(COLLECT_URL + "/v1/batch", data=body, headers={"Content-Type": "application/json", "X-Feralin-Project-Key": PROJECT_KEY, "Idempotency-Key": idempotency_key_for([event_id])})
with urllib.request.urlopen(request, timeout=10) as response:
    denied = json.loads(response.read())
    must(response.status == 202 and denied["accepted"] == 0 and denied["rejected_reasons"]["consent_denied"] == 1, "toplayıcı izinsiz olayı reddetmeliydi")
expect("absent %s" % event_id)
report("izinsiz-toplayici-red", denied["rejected_reasons"])

# Yanlış anahtar: 401, olay atılır, uygulama düşmez
reset_pool()
base = settings.FERALIN
with override_settings(FERALIN={**base, "PROJECT_KEY": "pk_test_wrong_key_000"}):
    out = post("order_completed", {"order_id": "ord_dj_wrong"}, analytics=True)
    must(out["status"] == 401 and out["rejected"] == 1 and out["retained"] == 0, "401 bekleniyordu")
    expect("absent %s" % out["event"]["event_id"])
    report("yanlis-anahtar-401", {"status": out["status"]})
reset_pool()

# Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
keys: list[str] = []


def lossy(url, data, headers, timeout):
    keys.append(headers["Idempotency-Key"])
    response = urllib_transport(url, data, headers, timeout)
    if len(keys) == 1:
        raise TemporaryError("yanıt yolda kayboldu", status=0)
    return response


with override_settings(FERALIN={**base, "CLIENT_OPTIONS": {"flush_interval": 0, "transport": lossy}}):
    lost = post("order_completed", {"order_id": "ord_dj_retry"}, analytics=True)
    must(lost["status"] == 0 and lost["retained"] == 1, "yanıt kaybı kuyrukta tutulmalıydı")
    following = post("order_shipped", {"order_id": "ord_dj_retry"}, analytics=True)
    must(following["status"] == 202 and following["retained"] == 0, "tekrar 202 vermeliydi")
    must(len(keys) == 3 and keys[0] == keys[1], "aynı anahtar bekleniyordu")
    expect("once %s" % lost["event"]["event_id"])
    expect("once %s" % following["event"]["event_id"])
    report("idempotency-tekrar", {"key": keys[0]})
reset_pool()

print("django tüketici: tüm senaryolar geçti")
