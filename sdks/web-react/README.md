# @feralin/react

`@feralin/web` üstünde React bağdaştırıcısı: `FeralinProvider`, `useFeralin`, `usePageView` ve Next.js App Router için `FeralinScript`. Çekirdek ayrı peer bağımlılığıdır, bu paket yalnız ince katmandır.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (vitest, jsdom, window'suz SSR) | Geçiyor |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs web-react` ile geçti |
| Gerçek Next.js 16 App Router (`next build`, `next start`, Chromium) | Aynı hedefte geçti: iki sayfa, iki `page_view`, tarayıcı hatası yok |
| React 18, Next 13-15 | Peer aralığında, sınanmadı |
| npm yayını | `BLOCKED_EXTERNAL`: `@feralin` organizasyonu yok |

## Kurulum

Yayın olmadığından paket dosyalarından kurulur:

```bash
pnpm --filter @feralin/web build
cd packages/sdk-web && npm pack
cd ../../sdks/web-react && npm pack
npm install ./feralin-web-0.1.0.tgz ./feralin-react-0.1.0.tgz
```

## Kullanım

```tsx
import { FeralinProvider, useFeralin } from "@feralin/react";

function SatinAl() {
  const feralin = useFeralin();
  return <button onClick={() => feralin.track("order_completed", { order_id: "ord_1" })}>Satın al</button>;
}

export function App() {
  return (
    <FeralinProvider projectKey="pk_live_…" collectUrl="https://collect.example.com" consent={{ analytics: true }}>
      <SatinAl />
    </FeralinProvider>
  );
}
```

Next.js App Router: `layout.tsx` sunucu bileşeni kalır. Çekirdek uygulamanın istemci paketine girer, dış betik gerekmez.

```tsx
import { FeralinScript } from "@feralin/react/next";

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="tr">
      <body>
        <FeralinScript projectKey="pk_live_…" collectUrl="https://collect.example.com" />
        {children}
      </body>
    </html>
  );
}
```

`FeralinScript` yol değişiminde `page_view` üretir. Provider'lı kullanımda aynı iş için `usePageView(pathname)` çağrılır.

## İzin

`consent` verilmezse izin bilinmiyor sayılır, olay üretilmez. İzin aracınızdan `useFeralin().setConsent({ analytics: true, advertising: false })` çağırın ya da `consent` özelliğini değiştirin. Reklam izni yoksa `fr_click` çıkarılır. Yalnız public anahtar (`pk_`) kabul edilir; `sk_` ve başka önekler sunucuda ve tarayıcıda reddedilir, boşluklar kırpılır.

## SSR

Sunucuda istemci, zamanlayıcı ve istekler arası durum oluşmaz; hook'lar boş yüzey döner. `active` alanına bağlı içerik basmayın, hydration uyuşmaz. Tarayıcıda proje ve toplayıcı başına tek istemci kurulur; StrictMode ikinci `page_view` üretmez. Bu yüzden anahtar ve adres dışındaki seçeneklerin sonraki değişimi yok sayılır (`consent` hariç).

## Desteklenmeyenler

- Pages Router için ayrı bileşen yoktur; `FeralinProvider` ve `usePageView` kullanılır.
- Hata raporlama ve replay yoktur. `trackRevenue` (`feralin_purchase`) istemci beyanıdır; `verified` gönderilmez, doğrulama sunucudaki makbuz doğrulayıcısınındır.
- Çekirdekten gelen sınırlar: üstel geri çekilme yok (sabit aralıkla dener); yanıt kaybolduktan sonra araya olay girerse `Idempotency-Key` değişir ve kaybolan olay outbox'a ikinci kez yazılır. Düzeltme `packages/sdk-web` içindedir.
