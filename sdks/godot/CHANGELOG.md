# Değişiklik günlüğü

## Yayımlanmamış

- Herkese açık depodan kurulum: `sdks/godot/v0.2.0` etiketinden seyrek klonla yalnız `sdks/godot/addons/feralin` indirilip oyunun `addons/` dizinine kopyalanır. Etiket henüz gönderilmedi (17 Kasım 2026).
- Kurulum eşleştirme kodu: `configure(..., {"install_code": "..."})` izin sonrası kuyruğa giren ilk olaya `fr_install_code` olarak eklenir (16 Kasım 2026).
- İlk gerçek koşu (Godot 4.7.2 headless): `feralin_store.gd` içindeki iki tür çıkarımı ayrıştırma hatası düzeltildi (addon hiç derlenmiyordu).
- `FeralinCrypto.sha256_hex("")` boş girdide `HashingContext.update` hatası veriyordu; boş metin artık doğru özeti döndürür.
- Gerçek toplayıcıya karşı uçtan uca tüketici (`tests/e2e_consumer.gd`, `scripts/sdk-e2e/targets/godot.mjs`).

## 0.2.0

- Kalıcı şifreli çevrimdışı kuyruk (`user://feralin`, AES-256-GCM, Unity ve Android ile aynı `enc1:` satır biçimi; aynı `event_id` ile tekrar gönderim).
- `track_revenue` (`feralin_purchase`, istemci beyanı), `track_ad_revenue` (`fr_ad_revenue`, `revenue_micros`), `group`, `set_user_properties`.
- Oyun olayları (`packages/schemas/utp/v1/game-events.md`).
- `capture_error` (`fr_error`); Godot 4.5+ için `enable_log_error_capture()` (Logger).
- 30 dakikalık otomatik oturum.
- `handle_deep_link` (`deep_link_opened`), Android Play Install Referrer, iOS AdServices `bind_install`.
- `native/`: Android ve iOS yerel köprü kaynakları (derlenmedi).
- Hiçbiri Godot'da çalıştırılmadı.

## 0.1.0

İlk sürüm: bellek kuyruğu, izin kapısı, UTP v1 batch gönderimi.
