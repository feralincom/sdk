"""Test yardımcıları: src/ yolunu ekler ve yanıtları önceden yazılmış sahte /v1/batch sunucusu sağlar."""

from __future__ import annotations

import json
import pathlib
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

SRC = pathlib.Path(__file__).resolve().parents[1] / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

SCHEMA_PATH = pathlib.Path(__file__).resolve().parents[3] / "packages" / "schemas" / "utp" / "v1" / "event.schema.json"

TEST_KEY = "pk_live_0123456789abcdef0123456789abcdef"


class FakeCollector:
    """httptest benzeri yerel HTTP sunucusu. `script` tüketilince 202 ack döner."""

    def __init__(self, script: list[tuple[int, str, dict[str, str]]] | None = None) -> None:
        self.lock = threading.Lock()
        self.requests: list[dict[str, Any]] = []
        self.script = list(script or [])
        self.received = threading.Semaphore(0)
        collector = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802 - http.server adlandırması
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length)
                if self.path != "/v1/batch":
                    self.send_error(404)
                    return
                body = json.loads(raw.decode("utf-8"))
                with collector.lock:
                    collector.requests.append({"headers": {k: v for k, v in self.headers.items()}, "body": body})
                    if collector.script:
                        status, payload, extra = collector.script.pop(0)
                    else:
                        status = 202
                        payload = json.dumps(
                            {"batch_id": "01TESTBATCH0000000000000000", "accepted": len(body.get("events", [])), "rejected": 0}
                        )
                        extra = {}
                data = payload.encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/problem+json" if status >= 400 else "application/json")
                self.send_header("Content-Length", str(len(data)))
                for key, value in extra.items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(data)
                collector.received.release()

            def log_message(self, *args: Any) -> None:  # gürültü yok
                return

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        # Kısa poll aralığı: shutdown() her testte 0,5 sn beklemesin.
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.02), daemon=True)
        self.thread.start()

    @property
    def url(self) -> str:
        host, port = self.server.server_address[:2]
        return "http://%s:%d" % (host, port)

    def count(self) -> int:
        with self.lock:
            return len(self.requests)

    def request(self, index: int) -> dict[str, Any]:
        with self.lock:
            return self.requests[index]

    def wait(self, timeout: float = 3.0) -> bool:
        return self.received.acquire(timeout=timeout)

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
