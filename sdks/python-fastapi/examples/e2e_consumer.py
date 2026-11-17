"""Gerçek services/collect tüketicisi: scripts/sdk-e2e/run.mjs python-fastapi tarafından temiz sanal ortamda çalıştırılır.
İstekler FastAPI'nin gerçek ASGI zincirinden geçer; denetim satırları outbox_check.go ile PostgreSQL üzerinde doğrulanır."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request

from fastapi import Depends, FastAPI, Request
from fastapi.testclient import TestClient
from feralin import Consent
from feralin.errors import TemporaryError
from feralin.events import idempotency_key_for
from feralin.transport import urllib_transport
from feralin_fastapi import FeralinMiddleware, RequestFeralin, get_feralin

COLLECT_URL = os.environ["FERALIN_E2E_COLLECT_URL"]
PROJECT_KEY = os.environ["FERALIN_E2E_PROJECT_KEY"]
CHECKS = os.environ["FERALIN_E2E_CHECKS"]


def must(condition: bool, message: str) -> None:
    if not condition:
        sys.exit("KALDI: " + message)


def expect(line: str) -> None:
    with open(CHECKS, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def report(name: str, detail: object) -> None:
    print("  OK %s: %s" % (name, json.dumps(detail, ensure_ascii=False)))


def resolver(request: Request) -> Consent:
    return Consent(analytics=request.headers.get("x-izin") == "evet", advertising=request.headers.get("x-reklam") == "evet")


def make_app(key: str = PROJECT_KEY, **options) -> FastAPI:
    app = FastAPI()
    app.add_middleware(FeralinMiddleware, project_key=key, collect_url=COLLECT_URL, flush_interval=0, resolve_consent=resolver, **options)

    @app.post("/olay")
    def olay(body: dict, feralin: RequestFeralin = Depends(get_feralin)):
        event = feralin.track(body["name"], body.get("properties"))
        result = feralin.flush()
        return {"event": event, "status": result.status, "accepted": result.accepted, "rejected": result.rejected, "retained": result.retained, "sent": result.sent, "batch_id": result.batch_id}

    return app


def post(client, name, properties=None, analytics=False, advertising=False, extra_headers=None):
    headers = {"x-izin": "evet" if analytics else "hayir", "x-reklam": "evet" if advertising else "hayir", "referer": "https://ref.example.test/?a=GIZLI", **(extra_headers or {})}
    response = client.post("/olay?token=GIZLI", json={"name": name, "properties": properties}, headers=headers)
    must(response.status_code == 200, "uygulama yanıtı %d" % response.status_code)
    return response.json()


with TestClient(make_app()) as client:
    # 202 + outbox satırı + fr_click reklam izniyle
    out = post(client, "order_completed", {"order_id": "ord_fa_1", "fr_click": "clk_fa_1"}, analytics=True, advertising=True)
    must(out["status"] == 202 and out["accepted"] == 1, "202 bekleniyordu")
    expect("frclick %s" % out["batch_id"])
    expect("once %s" % out["event"]["event_id"])
    expect("platform python:%s" % out["event"]["event_id"])
    report("202-outbox-frclick", {"status": out["status"], "batch_id": out["batch_id"]})

    # Reklam izni yok: fr_click çıkarılır
    out = post(client, "order_completed", {"order_id": "ord_fa_2", "fr_click": "clk_fa_2"}, analytics=True)
    must("fr_click" not in out["event"]["properties"], "fr_click çıkarılmalıydı")
    must(out["status"] == 202, "202 bekleniyordu")
    expect("nofrclick %s" % out["batch_id"])
    report("frclick-izinsiz-cikarildi", {"status": out["status"]})

    # Saldırgan başlık: şema sınırını aşan referrer ve bozuk Host batch'i düşürmez
    out = post(client, "order_completed", {"order_id": "ord_fa_uzun"}, analytics=True, extra_headers={"referer": "https://" + "r" * 3000 + ".example.test/"})
    must(out["status"] == 202 and out["accepted"] == 1 and "referrer" not in out["event"]["context"], "uzun referrer batch'i düşürmemeliydi")
    expect("once %s" % out["event"]["event_id"])
    out = post(client, "order_completed", {"order_id": "ord_fa_host"}, analytics=True, extra_headers={"host": "a b"})
    must(out["status"] == 202 and out["accepted"] == 1, "bozuk Host batch'i düşürmemeliydi")
    expect("once %s" % out["event"]["event_id"])
    report("saldirgan-baslik-202", {"status": out["status"]})

    # İzinsiz: SDK olay üretmez
    out = post(client, "order_completed")
    must(out["event"] is None and out["sent"] == 0, "izinsiz olay üretilmemeliydi")
    report("izinsiz-sdk-uretmez", {"sent": 0})

# İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
event_id = ("01JCFA%020d" % time.time_ns())[:26]
body = json.dumps({"events": [{"event_id": event_id, "event_name": "denied_event", "occurred_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "platform": "python", "schema_version": 1, "consent": {"analytics": False}}]}).encode()
request = urllib.request.Request(COLLECT_URL + "/v1/batch", data=body, headers={"Content-Type": "application/json", "X-Feralin-Project-Key": PROJECT_KEY, "Idempotency-Key": idempotency_key_for([event_id])})
with urllib.request.urlopen(request, timeout=10) as response:
    denied = json.loads(response.read())
    must(response.status == 202 and denied["accepted"] == 0 and denied["rejected_reasons"]["consent_denied"] == 1, "toplayıcı izinsiz olayı reddetmeliydi")
expect("absent %s" % event_id)
report("izinsiz-toplayici-red", denied["rejected_reasons"])

# Yanlış anahtar: 401, olay atılır, uygulama düşmez
with TestClient(make_app("pk_test_wrong_key_000")) as client:
    out = post(client, "order_completed", {"order_id": "ord_fa_wrong"}, analytics=True)
    must(out["status"] == 401 and out["rejected"] == 1 and out["retained"] == 0, "401 bekleniyordu")
    expect("absent %s" % out["event"]["event_id"])
    report("yanlis-anahtar-401", {"status": out["status"]})

# Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
keys: list[str] = []


def lossy(url, data, headers, timeout):
    keys.append(headers["Idempotency-Key"])
    response = urllib_transport(url, data, headers, timeout)
    if len(keys) == 1:
        raise TemporaryError("yanıt yolda kayboldu", status=0)
    return response


with TestClient(make_app(transport=lossy)) as client:
    lost = post(client, "order_completed", {"order_id": "ord_fa_retry"}, analytics=True)
    must(lost["status"] == 0 and lost["retained"] == 1, "yanıt kaybı kuyrukta tutulmalıydı")
    following = post(client, "order_shipped", {"order_id": "ord_fa_retry"}, analytics=True)
    must(following["status"] == 202 and following["retained"] == 0, "tekrar 202 vermeliydi")
    must(len(keys) == 3 and keys[0] == keys[1], "aynı anahtar bekleniyordu")
    expect("once %s" % lost["event"]["event_id"])
    expect("once %s" % following["event"]["event_id"])
    report("idempotency-tekrar", {"key": keys[0]})

print("fastapi tüketici: tüm senaryolar geçti")
