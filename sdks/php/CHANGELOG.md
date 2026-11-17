# Değişiklikler

## Yayınlanmamış

- `trackRevenue` → `feralin_purchase` (`Revenue`): Web/Node/Python/Go/.NET ile aynı alan adları ve doğrulama; `verified` gönderilmez, geçersiz girdide `null`.
- `captureError` → `fr_error` (`ErrorCapture`, `ErrorLimiter`): Android SDK ile aynı gövde; temizlenmiş mesaj, parmak izi, üst çerçeve, en çok 5 konum (dosya taban adı, satır, işlev), ham yığın izi ve dizin yolu yok; 60 sn'de 20 olay, parmak izi başına 3; `appVersion` ve `errorSampleRate` seçenekleri. PHPUnit ile sınandı (16 Kasım 2026).

## 0.1.0

- İlk sürüm. Kod yazıldı, PHP bulunmayan makinede ÇALIŞTIRILMADI. Henüz Packagist'e yayınlanmadı.
- Kimlik yöntemleri (UTP §8.2): `group` → `fr_group`, `setUserProperties` → `fr_user_properties`, `setGlobalProperties` ve `clearGlobalProperties` (`ProfileRules`); istemci tarafı anahtar, değer ve kişisel veri süzgeci. PHPUnit ve gerçek toplayıcı e2e WSL'de koşar (13 Kasım 2026).
