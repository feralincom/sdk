# Değişiklik günlüğü

crates.io'ya yayınlanmadı: hesap ve `feralin` ad doğrulaması yok (`BLOCKED_EXTERNAL`). Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## Yayınlanmamış

- `Client::track_revenue` ve `Revenue` oluşturucusu: `feralin_purchase` olayı; Web SDK `buildRevenueProperties` ile aynı doğrulama (işlem kimliği, küçük birimde tam sayı tutar, ISO 4217, adet, satın alma türü, makbuz); `verified` ve türevleri çağıranın özelliklerinden düşer (16 Kasım 2026).
- `Client::group` (`fr_group`) ve `Client::set_user_properties` (`fr_user_properties`): kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer istemcide düşer; `Identity` ile çağrı başına kimlik (16 Kasım 2026).
- `Client::capture_error` ve `Client::capture_error_report`: `fr_error` olayı; tür adı, PII temizlenmiş mesaj (≤200), FNV-1a 64 parmak izi, süreç başına 20 / parmak izi başına 3 sınırı, `Config::error_sample_rate` ve `Config::app_version`. Rust hataları yığın izi taşımadığı için çerçeve gönderilmez (16 Kasım 2026).
- Testler: `tests/signals.rs` (9 test) ve `capture` modül testleri; `cargo test` ile 52 test geçti.

## 0.1.0 (yayınlanmadı)

- `feralin` crate: sunucu, CLI ve masaüstü için UTP v1 istemcisi; `ureq` 3 + `rustls` HTTP, kendi gönderim iş parçacığı (tokio gerektirmez), bellek içi kuyruk, istemci düzeyinde izin, `identify` (6 Kasım 2026).
- `tauri-plugin-feralin`: Tauri 2 eklentisi ve izin tanımları (6 Kasım 2026).
- Kod ve testler yazıldı; bu sürüm kaydı yazıldığında hiç derlenmedi ve koşmadı (`capabilities.yaml` `lifecycle: IMPLEMENTING`).
