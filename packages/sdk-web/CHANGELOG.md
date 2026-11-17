# Değişiklik günlüğü

Paket npm'e yayınlanmadı (`@feralin` organizasyonu yok, `BLOCKED_EXTERNAL`); bugün `/sdk/feralin.iife.js` ile sunulur. Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## Yayınlanmamış

- Kurulum eşleştirme kodu: `new Feralin({ ..., installCode })` panelin "Kurulumu doğrula" ekranındaki tek kullanımlık kodu izin sonrası ilk olaya `fr_install_code` olarak ekler; biçimi geçersiz kod yok sayılır (16 Kasım 2026).

## 0.1.0 (yayınlanmadı)

- UTP v1 çekirdeği: `initialize`, `track`, `identify`, `reset`, `setConsent`, `flush`; ULID olay kimliği, `localStorage` kuyruğu (yoksa bellek), batch gönderimi `POST /v1/batch` (3 Kasım 2026).
- İzin ve atıf düzeltmeleri: izin kararı olmadan olay üretilmez, `fr_click` yalnız reklam izniyle taşınır, URL'den yalnız izin listesindeki `utm_*` okunur (3 Kasım 2026).
- App Banner betiği (`banner`): mobil web sayfasında Smart Link'e götüren şerit; çerez yazmaz, olay göndermez (5 Kasım 2026).
- Çekirdek dayanıklılığı: üstel geri çekilmeye jitter, güvenlik bulgularının düzeltmeleri (6 Kasım 2026).
- `@feralin/web/replay` (yalnız tıklama, kaydırma ve görünüm etkileşimi; DOM kaydı, metin ve form değeri yok, maskeleme kapatılamaz) ve `@feralin/web/flags` (özellik bayrakları ve deneyler) alt modülleri (9 Kasım 2026).
- `trackRevenue` → `feralin_purchase` istemci beyanı; doğrulanmış gelir yalnız sunucuda (10 Kasım 2026).
- `@feralin/web/auto`: tek sayfalı uygulamada `page_view`, dış bağlantı, dosya indirme, 404 ve (varsayılan kapalı) site içi arama olayları; sorgu dizgisi olaylara girmez (12 Kasım 2026).
- `@feralin/web/errors`: `window` hata ve `unhandledrejection` → `fr_error`, parmak izi, örnekleme ve hız sınırı (12 Kasım 2026).
- Sekme güvenli kuyruk: kuyruk her işlemde depodan okunur; bir sekme diğerinin gönderilmemiş olayını silmez, onaylanan olayı yeniden göndermez, aynı `event_id` iki kez eklenmez (12 Kasım 2026).
- Kimlik yöntemleri (UTP §8.2): `group` → `fr_group`, `setUserProperties` → `fr_user_properties`, `setGlobalProperties` ve `clearGlobalProperties`; kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer istemcide düşer. React, Vue, Angular ve Tauri tutamağı da aynı yöntemleri taşır (13 Kasım 2026).
