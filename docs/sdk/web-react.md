<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# React / Next.js: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/web-react/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/react` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/web-react` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: @feralin npm organizasyonu, 2FA, OIDC trusted publishing) |
| Derleme | `pnpm --filter @feralin/react build` |
| Test | `pnpm --filter @feralin/react test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
pnpm --filter @feralin/web build
cd packages/sdk-web && npm pack
cd ../../sdks/web-react && npm pack
npm install ./feralin-web-0.1.0.tgz ./feralin-react-0.1.0.tgz
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız; çerçeve katmanı #1 üstünde) |
| batch | SUPPORTED (yayınsız; #1 localStorage kuyruğu) |
| consent | SUPPORTED (yayınsız; fr_click reklam izni yoksa çıkarılır) |
| identity | PARTIAL (identify, reset, group, setUserProperties, setGlobalProperties tutamakta, çekirdek @feralin/web; ortak web senaryosu kimlik adımını taşır ama web-react e2e ve vitest bu turda koşmadı) |
| attribution | PARTIAL (#1 ile aynı; utm_* okunur) |
| deeplink | PLANNED |
| revenue | PARTIAL (handle.trackRevenue → çekirdek feralin_purchase; vitest; verified yalnız sunucuda) |
| error | PLANNED |
| replay | PLANNED |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS | vitest 16/16; window'suz react-dom/server SSR dahil. |
| registry | BLOCKED_EXTERNAL | @feralin npm organizasyonu yok. |
| clean_install | PASS | npm pack çıktıları boş dizine kuruldu, ESM ve CommonJS yüklendi. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs web-react: jsdom senaryoları ve gerçek Next.js 16.4.5 App Router (next build, next start, Chromium): 202, outbox, izinsiz red, 401, idempotency, iki page_view. React 18 ve Next 13-15 sınanmadı. |
| documentation | PASS | docs/sdk/web-react.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
