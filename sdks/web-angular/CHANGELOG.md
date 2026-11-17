# Değişiklikler

## Yayınlanmamış (yayın bekliyor)

Depodadır, npm'deki 0.1.0 içinde yoktur; sonraki sürüm numarasıyla yayımlanacak (0.1.0 yeniden yayımlanamaz).

- `provideFeralinErrorHandler(options?)` ve `FeralinErrorHandler`: uygulamanın `ErrorHandler`'ı olur, hataları `@feralin/web/errors` üzerinden `fr_error` olarak gönderir (`origin: "uncaught_exception"`, `handled: false`) ve `delegate.handleError`'ı (yoksa Angular varsayılanı gibi `console.error`) çağırır. İzin, örnekleme, sınır ve PII temizliği Web SDK'nınkidir; sunucuda olay üretmez. `reportFrameworkError` ve `FeralinErrorOptions` dışa aktarılır (17 Kasım 2026).

## 0.1.0 (npm'de yayımlı, 17 Kasım 2026, git b1a7d127)

- İlk sürüm: `provideFeralin` ve `FeralinService`, Angular SSR güvenli.
- Tutamak kimlik yöntemlerini taşır (UTP §8.2): `group`, `setUserProperties`, `setGlobalProperties`, `clearGlobalProperties`; kurallar `@feralin/web` ile aynıdır (13 Kasım 2026).
- Tutamak `trackRevenue` (`feralin_purchase`, `@feralin/web` ile aynı doğrulama; `verified` gönderilmez, geçersiz ya da serileştirilemeyen girdide `null`) ve `setReferrer` taşır; `RevenueInput` tipi dışa aktarılır.
