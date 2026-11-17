from __future__ import annotations

import unittest

from _support import TEST_KEY, FakeCollector

from feralin import Client, Consent, GROUP_EVENT_NAME, MAX_PROFILE_PROPERTIES, USER_PROPERTIES_EVENT_NAME, is_pii_like_key, sanitize_profile_properties


class ProfileRulesTests(unittest.TestCase):
    def test_pii_like_keys(self) -> None:
        for key in ("email", "userEmail", "email_address", "phone", "phoneNumber", "mobile", "ip", "userIP", "ipv4", "ip_address",
                    "first_name", "lastName", "fullname", "surname", "ad_soyad", "soyadi", "name", "userName", "displayName",
                    "isim", "ad", "home_address", "tckn", "ssn", "password", "birthdate", "dob", "iban", "eposta", "telefon_no"):
            self.assertTrue(is_pii_like_key(key), key)
        for key in ("plan", "tier", "zip_code", "hotel", "membership", "ad_network", "plan_name", "company_size"):
            self.assertFalse(is_pii_like_key(key), key)

    def test_sanitize_drops_invalid(self) -> None:
        props = sanitize_profile_properties({
            "plan": "pro",
            "tier": 2,
            "ratio": 0.5,
            "beta": True,
            "verified": True,
            "receipt": "x",
            "email": "a@b.co",
            "note": "iletişim a@b.co",
            "long": "x" * 257,
            "ok_long": "x" * 256,
            "nested": {"a": 1},
            "items": [1, 2],
            "nothing": None,
            "nan": float("nan"),
            "ctrl": "a\nb",
            "1bad": "x",
        })
        self.assertEqual(props, {"plan": "pro", "tier": 2, "ratio": 0.5, "beta": True, "ok_long": "x" * 256})

    def test_sanitize_limit(self) -> None:
        props = sanitize_profile_properties({"k%d" % i: i for i in range(60)})
        self.assertEqual(len(props), MAX_PROFILE_PROPERTIES)


class ProfileClientTests(unittest.TestCase):
    def setUp(self) -> None:
        self.collector = FakeCollector()
        self.addCleanup(self.collector.close)
        self.client = Client(TEST_KEY, self.collector.url, consent=Consent(analytics=True), flush_interval=0)
        self.addCleanup(self.client.close, 1.0)

    def wire(self) -> list[dict]:
        self.assertTrue(self.client.flush().ok)
        return self.collector.request(self.collector.count() - 1)["body"]["events"]

    def test_group_event(self) -> None:
        event = self.client.group("acme-team", {"plan": "team", "email": "x@y.co", "group_id": "baska"}, user_id="u1")
        self.assertIsNotNone(event)
        wire = self.wire()[0]
        self.assertEqual(wire["event_name"], GROUP_EVENT_NAME)
        self.assertEqual(wire["user_id"], "u1")
        self.assertEqual(wire["properties"], {"plan": "team", "group_id": "acme-team"})

    def test_invalid_group_id_produces_no_event(self) -> None:
        for bad in ("", "   ", "a" * 129, "ali@example.com", "a\tb", None, 5):
            self.assertIsNone(self.client.group(bad))  # type: ignore[arg-type]
        self.assertEqual(len(self.client), 0)
        self.assertIsNotNone(self.client.group("g" * 128))

    def test_user_properties(self) -> None:
        self.assertIsNone(self.client.set_user_properties({"email": "a@b.co", "verified": True}))
        self.assertEqual(len(self.client), 0)
        event = self.client.set_user_properties({"plan": "pro", "tier": 2, "phone": "555"}, anonymous_id="anon_1")
        self.assertIsNotNone(event)
        wire = self.wire()[0]
        self.assertEqual(wire["event_name"], USER_PROPERTIES_EVENT_NAME)
        self.assertEqual(wire["anonymous_id"], "anon_1")
        self.assertEqual(wire["properties"], {"plan": "pro", "tier": 2})

    def test_global_properties(self) -> None:
        self.client.set_global_properties({"app_release": "e2e", "plan": "free", "email": "a@b.co"})
        self.client.track("page_view", {"plan": "pro"})
        self.client.track("checkout")
        self.client.set_user_properties({"tier": 1})
        self.client.group("acme")
        self.client.set_global_properties({"plan": None})
        self.client.track("after_remove")
        self.client.clear_global_properties()
        self.client.track("after_clear")
        events = self.wire()
        self.assertEqual(events[0]["properties"], {"plan": "pro", "app_release": "e2e"})
        self.assertEqual(events[1]["properties"], {"app_release": "e2e", "plan": "free"})
        # fr_ sistem olaylarına global eklenmez.
        self.assertEqual(events[2]["properties"], {"tier": 1})
        self.assertEqual(events[3]["properties"], {"group_id": "acme"})
        self.assertEqual(events[4]["properties"], {"app_release": "e2e"})
        self.assertNotIn("properties", events[5])

    def test_global_limit(self) -> None:
        self.client.set_global_properties({"g%d" % i: i for i in range(40)})
        self.client.set_global_properties({"h%d" % i: i for i in range(40)})
        self.client.set_global_properties({"g0": "yeni"})
        self.client.track("page_view")
        props = self.wire()[0]["properties"]
        self.assertEqual(len(props), MAX_PROFILE_PROPERTIES)
        self.assertEqual(props["g0"], "yeni")
        self.assertIn("h9", props)
        self.assertNotIn("h10", props)


if __name__ == "__main__":
    unittest.main()
