# Değişiklikler

## Yayınlanmamış

- `captureError(error, options?)` → `fr_error`: hata sınıfı adı, temizlenmiş mesaj (URL, e-posta, UUID, belirteç, uzun sayı; ≤200), FNV-1a 64 parmak izi, `işlev@dosya` üst çerçeve ve en çok beş konum (yalnız dosya taban adı); ham yığın izi ve dizin gitmez. Hata fırtınası sınırı saatte 20 olay, aynı parmak izi için 3, örnekleme `errors.sampleRate`. İzin yoksa sınır sayacı harcanmaz.
- `installCode` seçeneği: biçime uyan kurulum eşleştirme kodu ilk uygun olaya `fr_install_code` olarak bir kez eklenir (`fr_error` ve `fr_ad_revenue` atlanır, toplayıcı orada düşürürdü).

## 0.1.0

- İlk sürüm: consent passthrough, idempotent batch, üstel geri çekilme, ESM ve CommonJS. Henüz npm'e yayınlanmadı.
- Kimlik yöntemleri (UTP §8.2): `group` → `fr_group`, `setUserProperties` → `fr_user_properties` (kimlik `TrackOptions` ile), istemci örneğine bağlı `setGlobalProperties` ve `clearGlobalProperties`; kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer istemcide düşer (13 Kasım 2026).
