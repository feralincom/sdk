"""Gerçek services/collect tüketicisi: scripts/sdk-e2e/run.mjs python tarafından temiz sanal ortamda çalıştırılır.

Paket wheel olarak kurulur; denetim satırları sdks/android/scripts/outbox_check.go ile PostgreSQL üzerinde doğrulanır.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

import feralin
from feralin import Client, Consent
from feralin.errors import RejectedError, TemporaryError
from feralin.events import idempotency_key_for
from feralin.transport import urllib_transport

COLLECT_URL = os.environ["FERALIN_E2E_COLLECT_URL"]
PROJECT_KEY = os.environ["FERALIN_E2E_PROJECT_KEY"]
CHECKS = os.environ["FERALIN_E2E_CHECKS"]
PROFILE_CHECKS = os.environ["FERALIN_E2E_PROFILE_CHECKS"]


def must(condition: bool, message: str) -> None:
    if not condition:
        sys.exit("KALDI: " + message)


def expect(line: str) -> None:
    with open(CHECKS, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def expect_profile(line: str) -> None:
    with open(PROFILE_CHECKS, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def report(name: str, detail: object) -> None:
    print("  OK %s: %s" % (name, json.dumps(detail, ensure_ascii=False)))


def make(key: str = PROJECT_KEY, **kwargs) -> Client:
    return Client(key, COLLECT_URL, flush_interval=0, **kwargs)


print("  kurulu paket: %s" % feralin.__file__)

# 202 + outbox satırı + fr_click reklam izniyle
client = make(consent=Consent(analytics=True, advertising=True))
event = client.track("order_completed", {"order_id": "ord_py_1", "fr_click": "clk_py_1"}, user_id="user_py_1")
result = client.flush()
must(event is not None and result.status == 202 and result.accepted == 1, "202 bekleniyordu")
expect("frclick %s" % result.batch_id)
expect("once %s" % event["event_id"])
report("202-outbox-frclick", {"status": result.status, "batch_id": result.batch_id})

# Reklam izni yok: fr_click çıkarılır
client = make(consent=Consent(analytics=True))
event = client.track("order_completed", {"order_id": "ord_py_2", "fr_click": "clk_py_2"})
must(event is not None and "fr_click" not in event["properties"], "fr_click çıkarılmalıydı")
result = client.flush()
must(result.status == 202, "202 bekleniyordu")
expect("nofrclick %s" % result.batch_id)
report("frclick-izinsiz-cikarildi", {"status": result.status})

# İzinsiz: SDK olay üretmez
client = make()
must(client.track("order_completed") is None and client.flush().sent == 0, "izinsiz olay üretilmemeliydi")
report("izinsiz-sdk-uretmez", {"sent": 0})

# İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
event_id = ("01JCPY%020d" % time.time_ns())[:26]
body = json.dumps(
    {
        "events": [
            {
                "event_id": event_id,
                "event_name": "denied_event",
                "occurred_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "platform": "python",
                "schema_version": 1,
                "consent": {"analytics": False},
            }
        ]
    }
).encode()
request = urllib.request.Request(
    COLLECT_URL + "/v1/batch",
    data=body,
    headers={"Content-Type": "application/json", "X-Feralin-Project-Key": PROJECT_KEY, "Idempotency-Key": idempotency_key_for([event_id])},
)
with urllib.request.urlopen(request, timeout=10) as response:
    denied = json.loads(response.read())
    must(response.status == 202 and denied["accepted"] == 0 and denied["rejected_reasons"]["consent_denied"] == 1, "toplayıcı izinsiz olayı reddetmeliydi")
expect("absent %s" % event_id)
report("izinsiz-toplayici-red", denied["rejected_reasons"])

# Yanlış anahtar: 401, olay atılır, uygulama düşmez
client = make("pk_test_wrong_key_000", consent=Consent(analytics=True))
event = client.track("order_completed", {"order_id": "ord_py_wrong"})
result = client.flush()
must(isinstance(result.error, RejectedError) and result.status == 401 and result.rejected == 1 and len(client) == 0, "401 bekleniyordu")
expect("absent %s" % event["event_id"])
report("yanlis-anahtar-401", {"status": result.status})

# Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
keys: list[str] = []


def lossy(url, data, headers, timeout):
    keys.append(headers["Idempotency-Key"])
    response = urllib_transport(url, data, headers, timeout)
    if len(keys) == 1:
        raise TemporaryError("yanıt yolda kayboldu", status=0)
    return response


client = make(consent=Consent(analytics=True), transport=lossy)
event = client.track("order_completed", {"order_id": "ord_py_retry"})
lost = client.flush()
must(isinstance(lost.error, TemporaryError) and len(client) == 1, "yanıt kaybı kuyrukta tutulmalıydı")
following = client.track("order_shipped", {"order_id": "ord_py_retry"})
result = client.flush()
must(result.ok and result.status == 202 and len(client) == 0, "tekrar 202 vermeliydi")
must(len(keys) == 3 and keys[0] == keys[1], "aynı anahtar bekleniyordu")
expect("once %s" % event["event_id"])
expect("once %s" % following["event_id"])
report("idempotency-tekrar", {"key": keys[0]})

# Kimlik yöntemleri (UTP §8.2): global özellik her olaya, kullanıcı özelliği ve grup ayrı sistem olayı. Toplayıcı izin listesi plan,tier.
client = make(consent=Consent(analytics=True))
client.set_global_properties({"app_release": "e2e"})
tracked = client.track("profile_e2e_page", anonymous_id="anon_py_profile")
props = client.set_user_properties({"plan": "pro", "tier": 2, "secret_note": "x", "email": "kisi@example.com"}, anonymous_id="anon_py_profile")
grouped = client.group("acme-team", {"plan": "team"}, anonymous_id="anon_py_profile")
must(client.group("kisi@example.com") is None, "e-posta biçimli grup kimliği reddedilmeliydi")
must(tracked is not None and props is not None and grouped is not None, "kimlik olayları üretilmeliydi")
must("email" not in props["properties"], "kişisel veri anahtarı istemcide düşmeliydi")
result = client.flush()
must(result.status == 202 and result.accepted == 3, "kimlik olayları 202 ile kabul edilmeliydi")
expect("once %s" % tracked["event_id"])
expect_profile("prop %s app_release=\"e2e\"" % tracked["event_id"])
expect_profile("name fr_user_properties:%s" % props["event_id"])
expect_profile("prop %s plan=\"pro\"" % props["event_id"])
expect_profile("prop %s tier=2" % props["event_id"])
expect_profile("noprop %s secret_note" % props["event_id"])
expect_profile("noprop %s app_release" % props["event_id"])
expect_profile("name fr_group:%s" % grouped["event_id"])
expect_profile("prop %s group_id=\"acme-team\"" % grouped["event_id"])
expect_profile("prop %s plan=\"team\"" % grouped["event_id"])
report("kimlik-yontemleri", {"status": result.status, "accepted": result.accepted})

print("python tüketici: tüm senaryolar geçti")
