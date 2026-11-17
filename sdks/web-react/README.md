# @feralin/react

`@feralin/web` üstünde React bağdaştırıcısı: `FeralinProvider`, `useFeralin`, `usePageView` ve Next.js App Router için `FeralinScript`. Çekirdek ayrı peer bağımlılığıdır, bu paket yalnız ince katmandır.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (vitest, jsdom, window'suz SSR) | Geçiyor |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs web-react` ile geçti |
| Gerçek Next.js 16 App Router (`next build`, `next start`, Chromium) | Aynı hedefte geçti: iki sayfa, iki `page_view`, tarayıcı hatası yok |
| React 18, Next 13-15 | Peer aralığında, sınanmadı |
| npm yayını | npm'de yayımlandı: `@feralin/react@0.1.0` (17 Kasım 2026, `@feralin` organizasyonu); sürüm ve özet registry'den geri okundu |

## Kurulum

Çekirdek peer bağımlılığıdır, iki paket birlikte kurulur:

```bash
npm install @feralin/web @feralin/react
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

## Hata yakalama (`FeralinErrorBoundary`)

> Yayın bekliyor: depoda var, npm'deki `@feralin/react@0.1.0` içinde yok. Sonraki sürümle yayımlanacak.

```tsx
"use client";
import { FeralinErrorBoundary } from "@feralin/react";

export function Checkout() {
  return (
    <FeralinErrorBoundary
      errors={{ appVersion: "1.4.2", sampleRate: 1 }}
      fallback={({ reset }) => <button onClick={reset}>Tekrar dene</button>}
    >
      <CheckoutForm />
    </FeralinErrorBoundary>
  );
}
```

Alt ağaçtaki çizim ve yaşam döngüsü hataları yakalanır, `fallback` çizilir ve `fr_error` gönderilir (`origin: "uncaught_exception"`, `handled: false`, `fatal: false`). Gövde `@feralin/web/errors` modülünden gelir: hata türü, temizlenmiş mesaj (URL, e-posta, belirteç, uzun sayı etiketlenir; ≤200), parmak izi, `işlev@dosya` üst çerçeve ve en çok beş konum (yalnız dosya taban adı). Ham yığın izi ve bileşen yığını gitmez. İzin yoksa olay üretilmez ve sınır sayacı harcanmaz; örnekleme (`sampleRate`) ve sınır (`maxEvents` 20, `maxPerFingerprint` 3, sayfa yüklemesi başına) aynı istemcideki bütün sınırlarca paylaşılır ve ilk hatada okunur. Aynı hata nesnesi bir kez bildirilir. Hata modülü ilk hatada dinamik yüklenir (paketleyici ayrı parçaya ayırır). İstemci en yakın `FeralinProvider`'dan, yoksa ilk kurulan istemciden (ör. `FeralinScript`) alınır; `feralin` özelliğiyle verilebilir. `onError(error, info)` bildirimden sonra çağrılır.

Sınır React'in yakalayabildiği hataları görür: olay işleyicisi, zamanlayıcı ve Promise hataları için `@feralin/web/errors` içindeki `captureErrors` ayrıca kurulabilir. Sunucuda (`react-dom/server`) sınır yalnız alt ağacı çizer, olay göndermez.

## Desteklenmeyenler

- Pages Router için ayrı bileşen yoktur; `FeralinProvider` ve `usePageView` kullanılır.
- Replay yoktur. `trackRevenue` (`feralin_purchase`) istemci beyanıdır; `verified` gönderilmez, doğrulama sunucudaki makbuz doğrulayıcısınındır.
- Çekirdekten gelen sınırlar: üstel geri çekilme yok (sabit aralıkla dener); yanıt kaybolduktan sonra araya olay girerse `Idempotency-Key` değişir ve kaybolan olay outbox'a ikinci kez yazılır. Düzeltme `packages/sdk-web` içindedir.
