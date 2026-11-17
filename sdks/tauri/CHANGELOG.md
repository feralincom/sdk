# Değişiklikler

## Yayınlanmamış

- Tutamak `trackRevenue` (`feralin_purchase`, `@feralin/web` ile aynı doğrulama; `verified` gönderilmez, geçersiz ya da serileştirilemeyen girdide `null`) ve `setReferrer` taşır; `RevenueInput` tipi dışa aktarılır.
- `createFeralinTauri` artık `FeralinTauriHandle` döner: `captureError`, `handleDeepLink`, `stop`.
- İsteğe bağlı `errors: { captureErrors }`: `@feralin/web/errors` işleviyle pencere hataları ve Promise redleri `fr_error` olur; `captureError` elle bildirir.
- İsteğe bağlı `deepLinks: { schemes, onOpenUrl, getCurrent }` (`@tauri-apps/plugin-deep-link` işlevleri verilir, bağımlılık eklenmez): her adres `deep_link_opened` olur; `fr_click` ve `utm_*` yalnız reklam izniyle (`attribution_source: "app_link"`), aksi hâlde `none`. Ham adres saklanmaz ve gönderilmez.

## 0.1.0

- İlk sürüm. Henüz npm'e yayınlanmadı.
- Tutamak kimlik yöntemlerini taşır (UTP §8.2): `group`, `setUserProperties`, `setGlobalProperties`, `clearGlobalProperties`; kurallar `@feralin/web` ile aynıdır (13 Kasım 2026).
