# Değişiklik günlüğü

Yayınlanmadı: herkese açık depo, release kanalı ve imza anahtarı yok (`BLOCKED_EXTERNAL`). Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## Yayınlanmamış

- `track_revenue` / `feralin_track_revenue`: `feralin_purchase` olayı; Web SDK `buildRevenueProperties` ile aynı doğrulama (işlem kimliği 1-128, `amount_minor` küçük birimde 0..2^53-1 tam sayı, ISO 4217, adet 0..100000, satın alma türü, iptalde tutar 0, makbuz sağlayıcısı ve belirteci). `verified` ve türevleri çağıranın özelliklerinden düşer, hiçbir zaman gönderilmez.
- `group` / `feralin_group` (`fr_group`) ve `set_user_properties` / `feralin_set_user_properties` (`fr_user_properties`): Go SDK ve toplayıcıyla aynı profil kuralları (en çok 50 anahtar, kişisel veriye benzeyen anahtar ve e-posta biçimli değer düşer, dizge en çok 256 karakter).
- `capture_error` / `feralin_capture_error`: `fr_error` (tür adı, temizlenmiş mesaj, FNV-1a 64 parmak izi, `handled`, `fatal`, `origin`, isteğe bağlı `app_version`); ham yığın izi gitmez. Süreç başına 20, parmak izi başına 3 olay, `error_sample_rate`. C++ istisnası taşınabilir yığın izi taşımadığından çerçeve listesi boştur; çerçeveleri uygulama `ErrorReport::frames` ile verebilir.
- `Options::app_version`, `Options::error_sample_rate`; C API'de `feralin_options` sonuna aynı alanlar (`struct_size` ile geriye uyumlu), `feralin_revenue` yapısı ve `feralin_revenue_init`.
- Yeni başlık `feralin/signals.hpp` (yalnız bu paket; `wire.hpp` ve Unreal kopyası değişmedi) ve `feralin_signals_tests`.

## 0.1.0 (yayınlanmadı)

- C++17 UTP v1 çekirdeği (`track`, `identify`, `set_consent`, `flush`, `close`, `status`), kararlı C API (`feralin.h`) ve CMake paketi (`find_package(feralin)`); dış JSON bağımlılığı yok. HTTP: Windows'ta WinHTTP, öteki sistemlerde libcurl ya da dışarıdan verilen transport. Bellek içi kuyruk, üstel geri çekilme, gerçek toplayıcıya karşı C ve C++ uçtan uca tüketicileri (6 Kasım 2026).
- `restore`: kalıcı depodan okunan önceden serileştirilmiş olay `event_id`'si korunarak kuyruğa geri eklenir; izin yoksa eklenmez, sınır aşılırsa atılan kimlikler bildirilir. Unreal SDK'nın kalıcı kuyruğu için eklendi; bu paketin kendisi kalıcı kuyruk tutmaz (12 Kasım 2026).
