# Değişiklikler

## Yayınlanmamış (yayın bekliyor)

Depodadır, npm'deki 0.1.0 içinde yoktur; sonraki sürüm numarasıyla yayımlanacak (0.1.0 yeniden yayımlanamaz).

- İsteğe bağlı kalıcı kuyruk: `storageDirectory`, `storageMaxBytes` (varsayılan 10 MiB), `storageMaxAgeMs` (varsayılan 7 gün, en çok 90 gün). Süreç çökerse olaylar sonraki açılışta aynı batch bileşimi ve aynı `Idempotency-Key` ile gönderilir; her istemci örneği kendi günlük dosyasına yazar, sahipsiz günlük atomik yeniden adlandırmayla devralınır; izin geri çekilince disk de silinir. Sıfır bağımlılık. `getStatus().storage` alanı (17 Kasım 2026).

## 0.1.0 (npm'de yayımlı, 17 Kasım 2026, git b1a7d127)

- İlk sürüm: consent passthrough, idempotent batch, üstel geri çekilme, ESM ve CommonJS.
- Kimlik yöntemleri (UTP §8.2): `group` → `fr_group`, `setUserProperties` → `fr_user_properties` (kimlik `TrackOptions` ile), istemci örneğine bağlı `setGlobalProperties` ve `clearGlobalProperties`; kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer istemcide düşer (13 Kasım 2026).
- `captureError(error, options?)` → `fr_error`: hata sınıfı adı, temizlenmiş mesaj (URL, e-posta, UUID, belirteç, uzun sayı; ≤200), FNV-1a 64 parmak izi, `işlev@dosya` üst çerçeve ve en çok beş konum (yalnız dosya taban adı); ham yığın izi ve dizin gitmez. Hata fırtınası sınırı saatte 20 olay, aynı parmak izi için 3, örnekleme `errors.sampleRate`. İzin yoksa sınır sayacı harcanmaz.
- `installCode` seçeneği: biçime uyan kurulum eşleştirme kodu ilk uygun olaya `fr_install_code` olarak bir kez eklenir (`fr_error` ve `fr_ad_revenue` atlanır, toplayıcı orada düşürürdü).
