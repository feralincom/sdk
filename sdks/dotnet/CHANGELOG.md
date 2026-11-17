# Değişiklikler

## Yayınlanmamış

- Hata yakalama (X4): `CaptureError` → `fr_error`, `ErrorOrigin`, `ErrorRules`; `FeralinOptions.AppVersion` ve `ErrorSampleRate`. Mesaj PII temizliği, satırsız `Ad.Alanı.Tür.Yöntem` çerçeveleri, FNV-1a 64 parmak izi, süreç başına 20 ve parmak izi başına 3 olay sınırı; birim testli (16 Kasım 2026).
- `FeralinOptions.InstallCode`: geçerli kurulum eşleştirme kodu ilk olaya `fr_install_code` olarak bir kez eklenir (16 Kasım 2026).

- UTP §8.2 kimlik yöntemleri: `Group` (`fr_group`), `SetUserProperties` (`fr_user_properties`), `SetGlobalProperties` ve `ClearGlobalProperties`. Kişisel veriye benzeyen anahtar, doğrulama alanı ve sözleşme dışı değer istemcide düşer; global özellikler `fr_` olmayan olaylara eklenir. Birim testli, gerçek toplayıcıyla `run.mjs dotnet` (13 Kasım 2026).

## 0.1.0

- İlk sürüm: `Feralin.Sdk` ve `Feralin.Sdk.AspNetCore`; consent passthrough, idempotent batch, üstel geri çekilme. Henüz NuGet'e yayınlanmadı.
