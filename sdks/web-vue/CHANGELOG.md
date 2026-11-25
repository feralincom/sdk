# Değişiklikler

## 0.2.0 (yayın adayı, 25 Kasım 2026)

Ekleyici sürüm. Eş bağımlılık `@feralin/web` artık `^0.1.0 || ^0.2.0`.

- `FeralinErrorHandler` eklentisi: `app.config.errorHandler` olur, bileşen hatalarını `@feralin/web/errors` üzerinden `fr_error` olarak gönderir (`origin: "uncaught_exception"`, `handled: false`) ve önceden atanmış işleyiciyi aynı argümanlarla çağırır (yoksa `console.error`). İzin, örnekleme, sınır ve PII temizliği Web SDK'nınkidir; sunucuda olay üretmez. `reportFrameworkError` ve `FeralinErrorOptions` dışa aktarılır (17 Kasım 2026).

## 0.1.0 (npm'de yayımlı, 17 Kasım 2026, git b1a7d127)

- İlk sürüm: plugin ve composable, SSR ve Nuxt uyumlu.
- Tutamak kimlik yöntemlerini taşır (UTP §8.2): `group`, `setUserProperties`, `setGlobalProperties`, `clearGlobalProperties`; kurallar `@feralin/web` ile aynıdır (13 Kasım 2026).
- Tutamak `trackRevenue` (`feralin_purchase`, `@feralin/web` ile aynı doğrulama; `verified` gönderilmez, geçersiz ya da serileştirilemeyen girdide `null`) ve `setReferrer` taşır; `RevenueInput` tipi dışa aktarılır.
