from __future__ import annotations

import re
import threading
import unittest

import _support  # noqa: F401 - src/ yolunu ekler

from feralin.ulid import CROCKFORD, ULIDGenerator, is_ulid

ULID_RE = re.compile(r"^[0-7][0-9A-HJKMNP-TV-Z]{25}$")
FIXED_MS = 1_762_164_000_000  # 2026-11-03T10:00:00Z


class ULIDTests(unittest.TestCase):
    def test_format(self) -> None:
        gen = ULIDGenerator()
        for _ in range(1000):
            value = gen.new()
            self.assertRegex(value, ULID_RE)
            self.assertTrue(is_ulid(value))
        for bad in ("", "01ARZ3NDEKTSV4RRFFQ69G5FAV1", "01ARZ3NDEKTSV4RRFFQ69G5FA", "01ARZ3NDEKTSV4RRFFQ69G5FAI", "81ARZ3NDEKTSV4RRFFQ69G5FAV"):
            self.assertFalse(is_ulid(bad), bad)

    def test_timestamp_prefix(self) -> None:
        value = ULIDGenerator(lambda: FIXED_MS).new()
        ms = 0
        for ch in value[:10]:
            ms = ms * 32 + CROCKFORD.index(ch)
        self.assertEqual(ms, FIXED_MS)

    def test_monotonic_within_same_millisecond(self) -> None:
        gen = ULIDGenerator(lambda: FIXED_MS)
        ids = [gen.new() for _ in range(5000)]
        for prev, cur in zip(ids, ids[1:]):
            self.assertLess(prev, cur)
            self.assertEqual(prev[:10], cur[:10])

    def test_monotonic_when_clock_goes_backwards(self) -> None:
        clock = {"ms": FIXED_MS}
        gen = ULIDGenerator(lambda: clock["ms"])
        first = gen.new()
        clock["ms"] -= 10_000
        self.assertGreater(gen.new(), first)

    def test_random_overflow_advances_time(self) -> None:
        gen = ULIDGenerator(lambda: FIXED_MS)
        first = gen.new()
        gen._last_rand = [31] * 16  # rastgele kısım dolu: bir sonraki artış taşar
        nxt = gen.new()
        self.assertGreater(nxt, first)
        self.assertNotEqual(nxt[:10], first[:10])

    def test_concurrent_unique(self) -> None:
        gen = ULIDGenerator()
        results: list[str] = []
        lock = threading.Lock()

        def worker() -> None:
            local = [gen.new() for _ in range(500)]
            with lock:
                results.extend(local)

        threads = [threading.Thread(target=worker) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(results), len(set(results)))


if __name__ == "__main__":
    unittest.main()
