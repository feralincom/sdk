"""Monotonik ULID üretimi (26 karakter Crockford base32). Web SDK ile aynı düzen:
10 karakter zaman (ms) + 16 adet 5 bitlik rastgele basamak (80 bit)."""

from __future__ import annotations

import secrets
import threading
import time
from collections.abc import Callable

CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
_CROCKFORD_SET = frozenset(CROCKFORD)


class ULIDGenerator:
    """Aynı milisaniyede (veya saat geri gittiğinde) son değeri artırarak sıralamayı korur; iş parçacığı güvenlidir."""

    __slots__ = ("_lock", "_now_ms", "_last_ms", "_last_rand")

    def __init__(self, now_ms: Callable[[], int] | None = None) -> None:
        self._lock = threading.Lock()
        self._now_ms = now_ms or (lambda: time.time_ns() // 1_000_000)
        self._last_ms = -1
        self._last_rand: list[int] = [0] * 16

    def new(self) -> str:
        with self._lock:
            ms = self._now_ms()
            if ms > self._last_ms:
                self._fill_random()
            else:
                ms = self._last_ms
                if not self._increment():
                    ms += 1
                    self._fill_random()
            self._last_ms = ms
            out = []
            t = ms
            for _ in range(10):
                out.append(CROCKFORD[t & 31])
                t >>= 5
            out.reverse()
            out.extend(CROCKFORD[v] for v in self._last_rand)
            return "".join(out)

    def _fill_random(self) -> None:
        buf = secrets.token_bytes(16)
        self._last_rand = [b & 31 for b in buf]

    def _increment(self) -> bool:
        # Rastgele kısmı base32 düzeninde bir artırır; tüm basamaklar taşarsa False döner.
        for i in range(15, -1, -1):
            if self._last_rand[i] < 31:
                self._last_rand[i] += 1
                return True
            self._last_rand[i] = 0
        return False


def is_ulid(value: str) -> bool:
    """26 karakterlik Crockford base32 ULID biçim denetimi (ilk karakter en fazla '7')."""
    return (
        isinstance(value, str)
        and len(value) == 26
        and value[0] <= "7"
        and all(ch in _CROCKFORD_SET for ch in value)
    )
