from __future__ import annotations

import json
import re
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone

from _support import SCHEMA_PATH, TEST_KEY, FakeCollector

from feralin import (
    AppInfo,
    Client,
    ClientClosedError,
    ConfigurationError,
    Consent,
    Context,
    InvalidEventError,
    REVENUE_EVENT_NAME,
    Receipt,
    RejectedError,
    TemporaryError,
    is_ulid,
)
from feralin.client import MAX_BATCH_SIZE, SDK_VERSION
from feralin.events import idempotency_key_for

OCCURRED_AT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")


def assert_wire_event(test: unittest.TestCase, wire: dict) -> None:
    """Tel üzerindeki olayın UTP v1 kurallarına uyduğunu elle denetler (jsonschema bağımlılığı yok)."""
    for key in ("event_id", "event_name", "occurred_at", "platform", "schema_version", "consent"):
        test.assertIn(key, wire, "zorunlu alan eksik: %s" % key)
    for forbidden in ("tenant_id", "project_id", "verified", "source_ip", "ip"):
        test.assertNotIn(forbidden, wire, "istemciden gönderilmemesi gereken alan var: %s" % forbidden)
    test.assertTrue(is_ulid(wire["event_id"]), wire["event_id"])
    test.assertEqual(wire["platform"], "python")
    test.assertEqual(wire["schema_version"], 1)
    test.assertEqual(wire["sdk"], {"name": "feralin-python", "version": SDK_VERSION})
    test.assertRegex(wire["occurred_at"], OCCURRED_AT_RE)
    datetime.strptime(wire["occurred_at"], "%Y-%m-%dT%H:%M:%S.%fZ")
    test.assertIs(wire["consent"]["analytics"], True)
    if SCHEMA_PATH.exists():
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        allowed = set(schema["properties"])
        for key in wire:
            test.assertIn(key, allowed, "şemada olmayan alan gönderildi: %s" % key)
        for key in schema["required"]:
            test.assertIn(key, wire, "şemanın zorunlu alanı eksik: %s" % key)


class ClientTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.collector = FakeCollector()
        self.addCleanup(self.collector.close)
        self.clients: list[Client] = []

    def tearDown(self) -> None:
        for client in self.clients:
            client.close(timeout=1.0)

    def make_client(self, script=None, **kwargs) -> Client:
        if script is not None:
            self.collector.script = list(script)
        kwargs.setdefault("consent", Consent(analytics=True))
        kwargs.setdefault("flush_interval", 0)  # arka plan kapalı; testler flush/close ile kontrol eder
        client = Client(TEST_KEY, self.collector.url, **kwargs)
        self.clients.append(client)
        return client


class ConfigurationTests(ClientTestCase):
    def test_rejects_secret_and_non_pk_keys(self) -> None:
        with self.assertRaisesRegex(ConfigurationError, "gizli anahtar"):
            Client("sk_live_abcdefgh", self.collector.url)
        with self.assertRaisesRegex(ConfigurationError, "pk_"):
            Client("dev_key_change_me_0001", self.collector.url)
        with self.assertRaises(ConfigurationError):
            Client("", self.collector.url)

    def test_rejects_bad_collect_url(self) -> None:
        with self.assertRaises(ConfigurationError):
            Client(TEST_KEY, "collect.example.test")
        with self.assertRaises(ConfigurationError):
            Client(TEST_KEY, "ftp://collect.example.test")

    def test_endpoint_built_from_root(self) -> None:
        client = Client(TEST_KEY, "https://collect.example.test/", flush_interval=0)
        self.clients.append(client)
        self.assertEqual(client.status()["endpoint"], "https://collect.example.test/v1/batch")
        self.assertNotIn("pk_", json.dumps(client.status()))


class TrackFlushTests(ClientTestCase):
    def test_track_flush_accepted(self) -> None:
        client = self.make_client()
        client.identify("user_42")
        event = client.track(
            "order_completed",
            {"order_id": "ord_1", "amount": 12.5, "items": 2},
            anonymous_id="anon_1",
            session_id="ses_1",
            context=Context(locale="tr-TR", timezone="Europe/Istanbul", app=AppInfo(version="1.2.3")),
        )
        self.assertIsNotNone(event)
        assert event is not None
        self.assertEqual(event["user_id"], "user_42")
        self.assertEqual(len(client), 1)

        result = client.flush()
        self.assertTrue(result.ok, result.error)
        self.assertEqual((result.status, result.sent, result.accepted, result.rejected), (202, 1, 1, 0))
        self.assertEqual(result.batch_id, "01TESTBATCH0000000000000000")
        self.assertEqual(len(client), 0)
        self.assertEqual(self.collector.count(), 1)

        request = self.collector.request(0)
        self.assertEqual(request["headers"]["X-Feralin-Project-Key"], TEST_KEY)
        self.assertEqual(request["headers"]["Idempotency-Key"], idempotency_key_for([event["event_id"]]))
        self.assertEqual(request["headers"]["Content-Type"], "application/json")
        self.assertIn("sent_at", request["body"])
        self.assertRegex(request["body"]["sent_at"], OCCURRED_AT_RE)
        events = request["body"]["events"]
        self.assertEqual(len(events), 1)
        wire = events[0]
        assert_wire_event(self, wire)
        self.assertEqual(wire["user_id"], "user_42")
        self.assertEqual(wire["anonymous_id"], "anon_1")
        self.assertEqual(wire["session_id"], "ses_1")
        self.assertEqual(wire["properties"], {"order_id": "ord_1", "amount": 12.5, "items": 2})
        self.assertEqual(wire["context"], {"locale": "tr-TR", "timezone": "Europe/Istanbul", "app": {"version": "1.2.3"}})
        self.assertEqual(wire["event_id"], event["event_id"])

    def test_track_revenue_contract(self) -> None:
        """F5-E04-T01: feralin_purchase sözleşmesi; verified düşer, geçersiz girdi fırlatır, tel üzerinde şemaya uyar."""
        client = self.make_client()
        event = client.track_revenue(
            "ord_1",
            4999,
            "TRY",
            product_id="pro",
            purchase_type="subscription_start",
            receipt=Receipt(provider="stripe", token="tok_1"),
            properties={"verified": True, "receipt_digest": "x", "plan": "pro"},
            user_id="user_42",
        )
        assert event is not None
        self.assertEqual(event["event_name"], REVENUE_EVENT_NAME)
        self.assertEqual(event["user_id"], "user_42")
        props = event["properties"]
        self.assertEqual(props["transaction_id"], "ord_1")
        self.assertEqual(props["amount_minor"], 4999)
        self.assertEqual(props["currency"], "TRY")
        self.assertEqual(props["quantity"], 1)
        self.assertEqual(props["purchase_type"], "subscription_start")
        self.assertEqual(props["receipt"], {"provider": "stripe", "token": "tok_1"})
        self.assertEqual(props["plan"], "pro")
        self.assertNotIn("verified", props)
        self.assertNotIn("receipt_digest", props)
        self.assertNotIn("verified", event)
        client.flush()
        assert_wire_event(self, self.collector.request(0)["body"]["events"][0])
        for bad in (
            dict(transaction_id="", amount_minor=1, currency="TRY"),
            dict(transaction_id="t", amount_minor=49.99, currency="TRY"),
            dict(transaction_id="t", amount_minor=True, currency="TRY"),
            dict(transaction_id="t", amount_minor=-1, currency="TRY"),
            dict(transaction_id="t", amount_minor=1, currency="try"),
            dict(transaction_id="t", amount_minor=1, currency="TRY", quantity=-1),
            dict(transaction_id="t", amount_minor=1, currency="TRY", purchase_type="gift"),
            dict(transaction_id="t", amount_minor=1, currency="TRY", receipt=Receipt("paypal", "x")),
            dict(transaction_id="t", amount_minor=1, currency="TRY", purchase_type="subscription_cancel"),
        ):
            with self.assertRaises(InvalidEventError, msg=str(bad)):
                client.track_revenue(**bad)
        self.assertEqual(len(client), 0)

    def test_optional_fields_omitted(self) -> None:
        client = self.make_client()
        event = client.track("signup")
        assert event is not None
        for key in ("user_id", "anonymous_id", "session_id", "properties", "context"):
            self.assertNotIn(key, event)
        client.flush()
        assert_wire_event(self, self.collector.request(0)["body"]["events"][0])

    def test_temporary_failure_keeps_queue_and_idempotency_key(self) -> None:
        client = self.make_client(
            script=[
                (503, json.dumps({"type": "urn:feralin:collect:problem:outbox", "title": "Outbox yazılamadı"}), {"Retry-After": "5"}),
                (429, json.dumps({"title": "Çok fazla istek"}), {"Retry-After": "1"}),
            ]
        )
        event = client.track("signup")
        assert event is not None

        result = client.flush()
        self.assertIsInstance(result.error, TemporaryError)
        self.assertEqual((result.status, result.retained, len(client)), (503, 1, 1))
        self.assertEqual(client.status()["backoff"], 5.0)

        result = client.flush()
        self.assertIsInstance(result.error, TemporaryError)
        self.assertEqual((result.status, len(client)), (429, 1))
        self.assertEqual(client.status()["backoff"], 10.0)

        result = client.flush()
        self.assertTrue(result.ok, result.error)
        self.assertEqual((result.status, len(client)), (202, 0))
        self.assertEqual(client.status()["backoff"], 0.0)

        self.assertEqual(self.collector.count(), 3)
        expected = idempotency_key_for([event["event_id"]])
        for i in range(3):
            self.assertEqual(self.collector.request(i)["headers"]["Idempotency-Key"], expected, "istek %d" % i)

    def test_idempotency_key_matches_other_sdks(self) -> None:
        self.assertEqual(idempotency_key_for(["01JC0000000000000000000002", "01JC0000000000000000000001"]), "8f95d6b736d56c98-2")

    def test_fr_click_requires_advertising_consent(self) -> None:
        client = self.make_client()
        event = client.track("order_completed", {"fr_click": "clk", "order_id": "o1"})
        assert event is not None
        self.assertEqual(event["properties"], {"order_id": "o1"})
        client.set_consent(Consent(analytics=True, advertising=True))
        event = client.track("order_completed", {"fr_click": "clk"})
        assert event is not None
        self.assertEqual(event["properties"]["fr_click"], "clk")

    def test_pinned_batch_keeps_content_across_retries(self) -> None:
        client = self.make_client(script=[(503, "{}", {})])
        first = client.track("first_event")
        assert first is not None
        self.assertIsInstance(client.flush().error, TemporaryError)
        second = client.track("second_event")
        assert second is not None
        self.assertTrue(client.flush().ok)
        self.assertEqual(self.collector.count(), 3)
        key = idempotency_key_for([first["event_id"]])
        self.assertEqual(self.collector.request(0)["headers"]["Idempotency-Key"], key)
        self.assertEqual(self.collector.request(1)["headers"]["Idempotency-Key"], key)
        self.assertEqual(self.collector.request(2)["headers"]["Idempotency-Key"], idempotency_key_for([second["event_id"]]))

    def test_network_error_keeps_queue(self) -> None:
        client = self.make_client()
        self.collector.close()  # sunucu kapalı → bağlantı hatası
        client.track("ping")
        result = client.flush()
        self.assertIsInstance(result.error, TemporaryError)
        self.assertEqual((result.status, len(client)), (0, 1))
        self.assertEqual(client.status()["backoff"], 1.0)
        client.set_consent(Consent(analytics=False))  # tearDown'daki close kapalı sunucuya yeniden denemesin

    def test_permanent_rejection_drops_events(self) -> None:
        client = self.make_client(
            script=[(400, json.dumps({"type": "urn:feralin:collect:problem:schema", "title": "Şema ihlali", "detail": "events[0]"}), {})]
        )
        client.track("client_valid_but_server_rejects")
        result = client.flush()
        self.assertIsInstance(result.error, RejectedError)
        self.assertIn("Şema ihlali", str(result.error))
        self.assertEqual((result.status, result.rejected, len(client)), (400, 1, 0))
        self.assertTrue(client.flush().ok)
        self.assertEqual(self.collector.count(), 1, "atılan olay yeniden gönderilmemeli")

    def test_consent_gate(self) -> None:
        client = self.make_client(consent=Consent(analytics=False))
        self.assertIsNone(client.track("page_view"))
        self.assertEqual(len(client), 0)

        client.set_consent(Consent(analytics=True))
        event = client.track("page_view")
        assert event is not None
        self.assertEqual(event["consent"], {"analytics": True, "advertising": False, "personalization": False, "session_replay": False})
        self.assertEqual(len(client), 1)

        client.set_consent(Consent(analytics=False))
        self.assertEqual(len(client), 0, "izin geri çekilince kuyruk temizlenmeli")
        self.assertTrue(client.flush().ok)
        self.assertEqual(self.collector.count(), 0, "izin yokken sunucuya istek gitmemeli")

    def test_validation(self) -> None:
        client = self.make_client()
        bad_names = ["", "orderCompleted", "1_event", "a" * 101, "has-dash", None]
        for name in bad_names:
            with self.assertRaises(InvalidEventError, msg=repr(name)):
                client.track(name)  # type: ignore[arg-type]
        with self.assertRaises(InvalidEventError):
            client.track("ok", {"1bad": 1})
        with self.assertRaises(InvalidEventError):
            client.track("ok", {"bad-key": 1})
        with self.assertRaises(InvalidEventError):
            client.track("ok", {"a" + "b" * 64: 1})
        with self.assertRaises(InvalidEventError):
            client.track("ok", {"k%d" % i: i for i in range(101)})
        with self.assertRaises(InvalidEventError):
            client.track("ok", user_id="u" * 129)
        with self.assertRaises(InvalidEventError):
            client.track("ok", {"obj": object()})  # JSON'a dönüşmez
        with self.assertRaises(InvalidEventError):
            client.track("ok", {"nan": float("nan")})
        with self.assertRaises(InvalidEventError):
            client.identify("u" * 129)
        self.assertEqual(len(client), 0, "geçersiz olaylar kuyruğa girmemeli")

        self.assertIsNotNone(client.track("ok", {"k%d" % i: i for i in range(100)}))
        self.assertIsNotNone(client.track("fr_system_event_9", {"Camel_Key9": "x"}))
        self.assertEqual(len(client), 2)

    def test_queue_limit_drops_oldest(self) -> None:
        client = self.make_client(queue_limit=3, batch_size=10)
        ids = []
        for _ in range(5):
            event = client.track("e")
            assert event is not None
            ids.append(event["event_id"])
        self.assertEqual((len(client), client.status()["dropped"]), (3, 2))
        self.assertTrue(client.flush().ok)
        got = [e["event_id"] for e in self.collector.request(0)["body"]["events"]]
        self.assertEqual(got, ids[2:])

    def test_batch_splitting(self) -> None:
        client = self.make_client(batch_size=2, queue_limit=100)
        for _ in range(5):
            client.track("e")
        result = client.flush()
        self.assertTrue(result.ok, result.error)
        self.assertEqual((result.sent, result.accepted, len(client)), (5, 5, 0))
        self.assertEqual(self.collector.count(), 3)
        first = self.collector.request(0)
        self.assertEqual(len(first["body"]["events"]), 2)
        self.assertEqual(first["headers"]["Idempotency-Key"], idempotency_key_for([e["event_id"] for e in first["body"]["events"]]))
        self.assertEqual(len(self.collector.request(2)["body"]["events"]), 1)

    def test_background_flush(self) -> None:
        client = self.make_client(flush_interval=0.02)
        client.track("bg")
        self.assertTrue(self.collector.wait(3.0), "arka plan gönderici 3 sn içinde istek yapmadı")
        deadline = time.monotonic() + 2.0
        while len(client) and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertEqual(len(client), 0)

    def test_background_flush_respects_backoff(self) -> None:
        client = self.make_client(script=[(503, json.dumps({"title": "down"}), {})], flush_interval=0.01)
        client.track("bg")
        self.assertTrue(self.collector.wait(3.0))
        time.sleep(0.15)
        self.assertEqual(self.collector.count(), 1, "backoff sırasında yeniden deneme olmamalı")
        self.assertEqual(len(client), 1)

    def test_backoff_wait_has_half_jitter_and_respects_retry_after(self) -> None:
        client = self.make_client(flush_interval=3600)
        waits = []
        for _ in range(50):
            client._backoff = 0.0
            before = time.monotonic()
            client._note_failure(None)
            waits.append(client._backoff_until - before)
            self.assertEqual(client._backoff, 1.0)
        self.assertGreaterEqual(min(waits), 0.5)
        self.assertLessEqual(max(waits), 1.1)
        self.assertGreater(len({round(wait, 3) for wait in waits}), 1, "bekleme dağılmalı")
        client._backoff = 0.0
        before = time.monotonic()
        client._note_failure("20")
        self.assertGreaterEqual(client._backoff_until - before, 20.0)

    def test_close_flushes_and_blocks_track(self) -> None:
        client = self.make_client(flush_interval=3600)  # arka plan pratikte hiç çalışmasın
        for _ in range(3):
            client.track("e")
        result = client.close()
        self.assertTrue(result.ok, result.error)
        self.assertEqual(self.collector.count(), 1)
        self.assertEqual(len(self.collector.request(0)["body"]["events"]), 3)
        self.assertEqual(len(client), 0)
        self.assertTrue(client.status()["closed"])
        with self.assertRaises(ClientClosedError):
            client.track("late")
        with self.assertRaises(ClientClosedError):
            client.flush()
        self.assertTrue(client.close().ok, "ikinci close hatasız olmalı")

    def test_close_reports_undelivered(self) -> None:
        client = self.make_client(script=[(503, json.dumps({"title": "down"}), {})])
        client.track("e")
        result = client.close(timeout=1.0)
        self.assertIsInstance(result.error, TemporaryError)
        self.assertEqual(result.retained, 1)

    def test_context_manager_flushes(self) -> None:
        with self.make_client() as client:
            client.track("ctx")
        self.assertEqual(self.collector.count(), 1)

    def test_concurrent_track(self) -> None:
        client = self.make_client(queue_limit=5000, batch_size=MAX_BATCH_SIZE)

        def worker() -> None:
            for _ in range(100):
                client.track("c")

        threads = [threading.Thread(target=worker) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(client), 800)
        result = client.flush()
        self.assertTrue(result.ok, result.error)
        self.assertEqual((result.accepted, len(client), self.collector.count()), (800, 0, 2))
        seen = set()
        for i in range(2):
            for e in self.collector.request(i)["body"]["events"]:
                self.assertNotIn(e["event_id"], seen)
                seen.add(e["event_id"])

    def test_occurred_at_uses_injected_clock(self) -> None:
        fixed = datetime(2026, 11, 3, 10, 0, 0, 123456, tzinfo=timezone(timedelta(hours=3)))
        client = self.make_client(now=lambda: fixed)
        event = client.track("clock")
        assert event is not None
        self.assertEqual(event["occurred_at"], "2026-11-03T07:00:00.123Z")
        explicit = datetime(2026, 1, 2, 3, 4, 5)  # saat dilimi yok → UTC varsayılır
        event = client.track("clock", occurred_at=explicit)
        assert event is not None
        self.assertEqual(event["occurred_at"], "2026-01-02T03:04:05.000Z")


if __name__ == "__main__":
    unittest.main()
