# Değişiklik günlüğü

Paket Packagist'e yayınlanmadı: hesap ve herkese açık depo yok, `feralin/feralin-php` de yayınlanmadı (`BLOCKED_EXTERNAL`). Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## Yayınlanmamış

- `RequestFeralin` ve `Feralin` facade: `trackRevenue`, `group`, `setUserProperties`, `captureError` ince geçişleri (isteğin izni ve kimliği eklenir); Orchestra Testbench ile sınandı (16 Kasım 2026).

## 0.1.0 (yayınlanmadı)

- `feralin/feralin-php` üstünde Laravel entegrasyonu: servis sağlayıcı ve yayımlanabilir `config/feralin.php`, `FeralinContext` ara katmanı (istek başına izin ve kimlik çözümleyici), `Feralin` facade (6 Kasım 2026).
