# Değişiklikler

## 0.1.1 (yayın adayı, 25 Kasım 2026)

- Eş bağımlılık `@feralin/node` artık `^0.1.0 || ^0.2.0`: kalıcı kuyruklu `@feralin/node@0.2.0` ile birlikte kurulabilir. Kod değişmedi.

## 0.1.0 (npm'de yayımlı, 17 Kasım 2026, git b1a7d127)

- Köprüye `trackRevenue`, `group`, `setUserProperties`, `captureError` kanalları eklendi. Ana süreç girdiyi doğrular: gelir alanları türüyle süzülür ve `@feralin/node` sözleşmesinden geçer; hata özeti yalnız dizge alanlar ve uzunluk sınırıyla alınır, web görünümü `uncaught_exception` ve `fatal` bildiremez. Köken ve çerçeve reddi yeni kanallarda da geçerlidir.
- `createFeralinMain` dönüşüne ana süreç için `captureError` ve `handleDeepLink` eklendi.
- `installCode` seçeneği: kurulum eşleştirme kodu ilk olaya `fr_install_code` olarak bir kez eklenir.
- İsteğe bağlı `deepLinks: { schemes, registerProtocol?, argv? }`: özel şemalar `app.setAsDefaultProtocolClient` ile kaydedilir; `open-url`, `second-instance` ve açılış argv adresleri `deep_link_opened` olur. `fr_click` ve `utm_*` yalnız reklam izniyle; ham adres gönderilmez.

- İlk sürüm: ana süreç, preload ve renderer köprüsü.
