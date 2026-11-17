# Değişiklik günlüğü

Modül henüz etiketlenmedi (`BLOCKED_EXTERNAL`): kalıcı modül yolu `github.com/feralincom/sdk/sdks/go`, sürüm etiketi `sdks/go/v<sürüm>`; herkese açık depoya gönderim ve etiket site sahibinin onayını bekler. Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## Yayınlanmamış

- Modül yolu kalıcı hale geldi: `feralin.dev/sdks/go` yerine `github.com/feralincom/sdk/sdks/go` (herkese açık depo, alt dizin modülü). İçe aktarma satırı değişir; API aynıdır (17 Kasım 2026).
- Hata yakalama (X4): `CaptureError` → `fr_error`; `WithAppVersion`, `WithErrorSampleRate`, `ErrorProperties`, `ScrubErrorMessage`, `ErrorFingerprint`. Mesaj PII temizliği, satırsız `paket.İşlev` çerçeveleri, FNV-1a 64 parmak izi, süreç başına 20 ve parmak izi başına 3 olay sınırı; birim testli (16 Kasım 2026).

## 0.1.0 (yayınlanmadı)

- Sunucu tarafı UTP v1 istemcisi: `NewClient`, `Track`, `Identify`, `SetConsent`, `Flush`, `Close`, `Status`; yalnız standart kütüphane, ULID olay kimliği, bellek içi kuyruk, deterministik `Idempotency-Key`, üstel geri çekilme (3 Kasım 2026).
- Gerçek toplayıcıya karşı uçtan uca örnek (`examples/e2e`) ve olay alanı düzeltmeleri (4 Kasım 2026).
- Proje anahtarı maskeleme: sunucu ya da vekil hata metni anahtarı geri yansıtsa bile günlüğe ve hata değerine maskelenmiş, kırpılmış girer (5 Kasım 2026).
- Geri çekilmeye yarım jitter; `Retry-After` alt sınır olarak korunur (6 Kasım 2026).
- `TrackRevenue` → `feralin_purchase` istemci beyanı; doğrulanmış gelir yalnız sunucuda (10 Kasım 2026).
- Kimlik yöntemleri (UTP §8.2): `Group` → `fr_group`, `SetUserProperties` → `fr_user_properties`, `SetGlobalProperties` ve `ClearGlobalProperties`, `Identity`; istemci tarafı anahtar, değer ve kişisel veri süzgeci (13 Kasım 2026).
