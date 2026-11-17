# Değişiklikler

## Yayınlanmamış

- Tutamak `trackRevenue` (`feralin_purchase`, `@feralin/web` ile aynı doğrulama; `verified` gönderilmez, geçersiz ya da serileştirilemeyen girdide `null`) ve `setReferrer` taşır; `RevenueInput` tipi dışa aktarılır.

## 0.1.0

- İlk sürüm: Provider, useFeralin, usePageView, Next.js App Router FeralinScript. Henüz npm'e yayınlanmadı.
- Tutamak kimlik yöntemlerini taşır (UTP §8.2): `group`, `setUserProperties`, `setGlobalProperties`, `clearGlobalProperties`; kurallar `@feralin/web` ile aynıdır (13 Kasım 2026).
