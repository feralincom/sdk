# Değişiklik günlüğü

Maven Central'a yayınlanmadı: `com.feralin` namespace doğrulaması ve imza anahtarı yok (`BLOCKED_EXTERNAL`). Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## Yayınlanmamış

- `trackRevenue(Revenue)` → `feralin_purchase`: Web `buildRevenueProperties` ile aynı doğrulama (küçük birimde tam sayı tutar, ISO 4217, adet 0-100000, iptal tutarı 0, makbuz sağlayıcısı ve belirteci); `verified` ve türevleri düşer, geçersiz girdide olay üretilmez (16 Kasım 2026).
- `captureError(Throwable)` → `fr_error`: Android `ErrorEvent` ile aynı alanlar ve mesaj temizliği; parmak izi FNV-1a 64, uygulama çerçeveleri öncelikli; istemci başına 20, parmak izi başına 3 olay sınırı ve `errorSampleRate`. Yeni ayarlar `FeralinConfig(appVersion, errorSampleRate)` (16 Kasım 2026).
- Kimlik kuralları Web/Node ile eşitlendi: dizge ve `group_id` uzunluğu kod noktasıyla sayılır; global haritadaki `null` silme isteği 50 sınırına girmez (16 Kasım 2026).
- Kurulum eşleştirme kodu: `FeralinConfig(installCode = ...)` izin sonrası kuyruğa giren ilk olaya `fr_install_code` olarak eklenir; olay kuyruğa girmezse kod sonrakine kalır (16 Kasım 2026).
- UTP §8.2 kimlik yöntemleri `commonMain` içinde: `group` (`fr_group`), `setUserProperties` (`fr_user_properties`), `setGlobalProperties`, `clearGlobalProperties`. Kişisel veriye benzeyen anahtar, doğrulama alanı ve sözleşme dışı değer düşer; globaller `fr_` olmayan olaylara eklenir. `jvmTest` ile sınandı; Android ve iOS hedeflerinde koşmadı (13 Kasım 2026).

## 0.1.0 (yayınlanmadı)

- `commonMain` içinde ortak UTP v1 istemcisi (Ktor client); `jvmMain` (CIO), `androidMain` (OkHttp) ve `iosMain` (Darwin) yalnız motor, saat, kilit ve rastgele kaynağını verir. Bellek içi kuyruk, istemci düzeyinde izin, `identify` (6 Kasım 2026).
- `iosMain` yazıldı, derlenmedi: Kotlin/Native iOS macOS ister. Atıf ve derin bağlantı köprüsü yok; platform SDK'ları (`sdks/android`, `sdks/swift`) kullanılır.
