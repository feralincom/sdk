from __future__ import annotations

import re
import unittest

from _support import TEST_KEY, FakeCollector

from feralin import ERROR_EVENT_NAME, ERROR_ORIGIN_UNCAUGHT, Client, Consent, error_properties, scrub_error_message
from feralin.error_capture import ErrorLimiter, error_fingerprint, fnv1a64

_FINGERPRINT = re.compile(r"^[0-9a-f]{16}$")
_ALLOWED = {"error_type", "message", "fingerprint", "top_frame", "frame_count", "app_version", "handled", "fatal", "origin"}


class PaymentError(Exception):
    pass


def _charge() -> None:
    raise PaymentError(
        "kart reddedildi ali@example.com https://pay.example.com/x?t=1 id 550e8400-e29b-41d4-a716-446655440000 "
        "tel +90 532 123 45 67 oturum ab12cd34ef56gh78ij90kl12mn34"
    )


class ErrorRulesTests(unittest.TestCase):
    def test_fnv_vector_matches_other_sdks(self) -> None:
        # fnv1a64("|") — Go SDK testindeki vektörle aynı.
        self.assertEqual(fnv1a64("|"), "af63f14c8602103b")
        self.assertEqual(error_fingerprint("", [], ""), "af63f14c8602103b")

    def test_scrub(self) -> None:
        self.assertEqual(scrub_error_message("  sürüm 1.4.2   tamam "), "sürüm 1.4.2 tamam")
        self.assertEqual(scrub_error_message("UnsupportedOperationExceptionHandler"), "UnsupportedOperationExceptionHandler")
        self.assertEqual(len(scrub_error_message("ş" * 300)), 200)

    def test_properties_contract(self) -> None:
        try:
            _charge()
        except PaymentError as exc:
            props = error_properties(exc, app_version="2.4.0")
        self.assertEqual(props["error_type"], "PaymentError")
        self.assertRegex(props["fingerprint"], _FINGERPRINT)
        for leak in ("ali@example.com", "pay.example.com", "550e8400", "532 123", "ab12cd34"):
            self.assertNotIn(leak, props["message"])
        for tag in ("[email]", "[url]", "[id]", "[num]", "[token]"):
            self.assertIn(tag, props["message"])
        # En içteki çerçeve önce; yol ve satır yok.
        self.assertEqual(props["top_frame"], "test_error_capture._charge")
        self.assertEqual(props["frame_count"], 2)
        self.assertTrue(props["handled"])
        self.assertFalse(props["fatal"])
        self.assertEqual(props["origin"], "handled")
        self.assertEqual(props["app_version"], "2.4.0")
        self.assertTrue(set(props) <= _ALLOWED)

    def test_without_traceback_uses_message_basis(self) -> None:
        a = error_properties(ValueError("sipariş 123 yok"))
        b = error_properties(ValueError("sipariş 456 yok"))
        self.assertEqual(a["fingerprint"], b["fingerprint"])
        self.assertNotIn("top_frame", a)
        self.assertEqual(a["frame_count"], 0)
        self.assertNotIn("app_version", error_properties(ValueError("x"), app_version="v" * 33))
        self.assertEqual(error_properties("düz metin")["error_type"], "Error")

    def test_limiter(self) -> None:
        limiter = ErrorLimiter(rand=lambda: 0.5)
        self.assertEqual(sum(limiter.allow("%016x" % i) for i in range(40)), 20)
        same = ErrorLimiter()
        self.assertEqual(sum(same.allow("a") for _ in range(5)), 3)
        self.assertFalse(ErrorLimiter(0.25, rand=lambda: 0.5).allow("a"))
        self.assertTrue(ErrorLimiter(0.75, rand=lambda: 0.5).allow("a"))


class ErrorClientTests(unittest.TestCase):
    def setUp(self) -> None:
        self.collector = FakeCollector()
        self.addCleanup(self.collector.close)

    def test_capture_error_consent_and_wire(self) -> None:
        client = Client(TEST_KEY, self.collector.url, flush_interval=0, app_version="2.4.0")
        self.addCleanup(client.close)
        try:
            _charge()
        except PaymentError as exc:
            self.assertIsNone(client.capture_error(exc))
            client.set_consent(Consent(analytics=True))
            event = client.capture_error(exc, user_id="user_42")
        self.assertIsNotNone(event)
        assert event is not None
        self.assertEqual(event["event_name"], ERROR_EVENT_NAME)
        self.assertEqual(event["user_id"], "user_42")
        self.assertTrue(set(event["properties"]) <= _ALLOWED)
        result = client.flush()
        self.assertEqual(result.accepted, 1)
        sent = self.collector.requests[0]["body"]["events"][0]
        self.assertEqual(sent["properties"]["error_type"], "PaymentError")
        self.assertNotIn("stack", sent["properties"])

    def test_origin_and_fingerprint_limit(self) -> None:
        client = Client(TEST_KEY, self.collector.url, flush_interval=0, consent=Consent(analytics=True))
        self.addCleanup(client.close)
        fatal = client.capture_error(RuntimeError("çöktü"), origin=ERROR_ORIGIN_UNCAUGHT, fatal=True)
        assert fatal is not None
        self.assertFalse(fatal["properties"]["handled"])
        self.assertTrue(fatal["properties"]["fatal"])
        unknown = client.capture_error(RuntimeError("başka"), origin="window_onerror")
        assert unknown is not None
        self.assertEqual(unknown["properties"]["origin"], "manual")
        sent = [client.capture_error(KeyError("aynı")) for _ in range(5)]
        self.assertEqual(sum(1 for e in sent if e is not None), 3)


if __name__ == "__main__":
    unittest.main()
