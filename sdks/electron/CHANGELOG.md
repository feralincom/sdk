# Değişiklikler

## Yayınlanmamış

- Köprüye `trackRevenue`, `group`, `setUserProperties`, `captureError` kanalları eklendi. Ana süreç girdiyi doğrular: gelir alanları türüyle süzülür ve `@feralin/node` sözleşmesinden geçer; hata özeti yalnız dizge alanlar ve uzunluk sınırıyla alınır, web görünümü `uncaught_exception` ve `fatal` bildiremez. Köken ve çerçeve reddi yeni kanallarda da geçerlidir.
- `createFeralinMain` dönüşüne ana süreç için `captureError` ve `handleDeepLink` eklendi.
- `installCode` seçeneği: kurulum eşleştirme kodu ilk olaya `fr_install_code` olarak bir kez eklenir.
- İsteğe bağlı `deepLinks: { schemes, registerProtocol?, argv? }`: özel şemalar `app.setAsDefaultProtocolClient` ile kaydedilir; `open-url`, `second-instance` ve açılış argv adresleri `deep_link_opened` olur. `fr_click` ve `utm_*` yalnız reklam izniyle; ham adres gönderilmez.

## 0.1.0

- İlk sürüm: ana süreç, preload ve renderer köprüsü. Henüz npm'e yayınlanmadı.
