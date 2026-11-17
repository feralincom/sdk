# Değişiklik günlüğü

Paket PyPI'a yayınlanmadı: hesap yok (`BLOCKED_EXTERNAL`). Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## Yayınlanmamış

- Hata yakalama (X4): `Client.capture_error` → `fr_error`; `app_version` ve `error_sample_rate` kurucu seçenekleri, `error_properties`, `scrub_error_message`. Mesaj PII temizliği, satırsız `modül.işlev` çerçeveleri, FNV-1a 64 parmak izi, süreç başına 20 ve parmak izi başına 3 olay sınırı; birim testli (16 Kasım 2026).

## 0.1.0 (yayınlanmadı)

- Sunucu tarafı UTP v1 istemcisi: `Client`, `track`, `identify`, `set_consent`, `flush`, `close`, `status`; yalnız standart kütüphane, tür ipuçları ve `py.typed`, ULID olay kimliği, bellek içi kuyruk, üstel geri çekilme (3 Kasım 2026).
- Gerçek toplayıcıya karşı uçtan uca örnek (`examples/e2e_consumer.py`) ve olay alanı düzeltmeleri (4 Kasım 2026).
- Geri çekilmeye yarım jitter; `Retry-After` alt sınır olarak korunur (6 Kasım 2026).
- `track_revenue` → `feralin_purchase` istemci beyanı; doğrulanmış gelir yalnız sunucuda (10 Kasım 2026).
- Kimlik yöntemleri (UTP §8.2): `group` → `fr_group`, `set_user_properties` → `fr_user_properties`, `set_global_properties` ve `clear_global_properties`; istemci tarafı anahtar, değer ve kişisel veri süzgeci (13 Kasım 2026).
