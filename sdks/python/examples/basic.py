"""Örnek: yerel collect servisine (services/collect, varsayılan :8081) tek bir sunucu olayı gönderir.

Çalıştırma (collect açık ve anahtar COLLECT_PROJECT_KEYS içinde tanımlıyken):

    FERALIN_PROJECT_KEY=pk_live_dev0000000000000000000000000001 \
    FERALIN_COLLECT_URL=http://127.0.0.1:8081 \
    PYTHONPATH=sdks/python/src python sdks/python/examples/basic.py
"""

from __future__ import annotations

import logging
import os
import sys

from feralin import Client, Consent, Context, RejectedError, TemporaryError


def main() -> int:
    project_key = os.environ.get("FERALIN_PROJECT_KEY", "")
    collect_url = os.environ.get("FERALIN_COLLECT_URL", "http://127.0.0.1:8081")
    if not project_key:
        print("FERALIN_PROJECT_KEY ortam değişkeni gerekli (pk_ ile başlayan proje anahtarı)", file=sys.stderr)
        return 2

    logging.basicConfig(level=logging.DEBUG, format="%(levelname)s %(name)s: %(message)s")

    with Client(project_key, collect_url, consent=Consent(analytics=True), flush_interval=2.0) as client:
        # Sunucu tarafı sipariş olayı; user_id müşteri uygulamasının kendi kimliğidir, PII değildir.
        event = client.track(
            "order_completed",
            {"order_id": "ord_1001", "amount": 249.90, "currency": "TRY", "items": 3},
            user_id="user_42",
            context=Context(locale="tr-TR", timezone="Europe/Istanbul"),
        )
        if event is None:
            print("izin yok, olay üretilmedi", file=sys.stderr)
            return 1
        print("kuyruğa alındı:", event["event_id"], event["event_name"], event["occurred_at"])

        result = client.flush()
        if result.ok:
            print(
                "gönderildi: batch_id=%s accepted=%d rejected=%d status=%d"
                % (result.batch_id, result.accepted, result.rejected, result.status)
            )
        elif isinstance(result.error, TemporaryError):
            print("geçici hata, kuyrukta %d olay tutuluyor: %s" % (result.retained, result.error))
        elif isinstance(result.error, RejectedError):
            print("toplayıcı reddetti (status=%d): %s" % (result.status, result.error))
        else:
            print("gönderim hatası:", result.error)
    return 0


if __name__ == "__main__":
    sys.exit(main())
