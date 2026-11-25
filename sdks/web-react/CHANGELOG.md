# Değişiklikler

## 0.2.0 (yayın adayı, 25 Kasım 2026)

Ekleyici sürüm. Eş bağımlılık `@feralin/web` artık `^0.1.0 || ^0.2.0`.

- `FeralinErrorBoundary`: alt ağaçtaki çizim ve yaşam döngüsü hatalarını yakalar, `fallback` (düğüm ya da `{ error, reset }` alan işlev) çizer ve `@feralin/web/errors` üzerinden `fr_error` gönderir (`origin: "uncaught_exception"`, `handled: false`). İzin, örnekleme, sınır ve PII temizliği Web SDK'nınkidir; izin yokken sınır sayacı harcanmaz, aynı hata nesnesi bir kez bildirilir. Hata modülü ilk hatada dinamik yüklenir. `reportFrameworkError` ve `FeralinErrorOptions` dışa aktarılır. V8 yığın izinin `Tür: mesaj` başlığı çerçeve sanılmasın diye köprü başlığı çıkarır (npm'deki @feralin/web@0.1.0 mesajında `@` olan başlığı `top_frame` alanına yazıyordu) (17 Kasım 2026).

## 0.1.0 (npm'de yayımlı, 17 Kasım 2026, git b1a7d127)

- İlk sürüm: Provider, useFeralin, usePageView, Next.js App Router FeralinScript.
- Tutamak kimlik yöntemlerini taşır (UTP §8.2): `group`, `setUserProperties`, `setGlobalProperties`, `clearGlobalProperties`; kurallar `@feralin/web` ile aynıdır (13 Kasım 2026).
- Tutamak `trackRevenue` (`feralin_purchase`, `@feralin/web` ile aynı doğrulama; `verified` gönderilmez, geçersiz ya da serileştirilemeyen girdide `null`) ve `setReferrer` taşır; `RevenueInput` tipi dışa aktarılır.
