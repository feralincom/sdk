<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# React / Next.js: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/web-react/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/react` |
| Sürüm | 0.2.0 |
| Yaşam döngüsü | INSTALL_VERIFIED |
| Kaynak dizin | `sdks/web-react` |
| Registry | npm: **PUBLISHED** (sonraki adım: her paket için npm trusted publishing (OIDC); npm 2FA'yı atlayan anahtarla doğrudan yayını Ocak 2027'de kapatıyor) |
| Derleme | `pnpm --filter @feralin/react build` |
| Test | `pnpm --filter @feralin/react test` |

## Kurulum

```bash
npm install @feralin/web @feralin/react
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
| event | SUPPORTED (çerçeve katmanı #1 üstünde) |
| batch | SUPPORTED (#1 localStorage kuyruğu) |
| consent | SUPPORTED (fr_click reklam izni yoksa çıkarılır) |
| identity | PARTIAL (identify, reset, group, setUserProperties, setGlobalProperties tutamakta, çekirdek @feralin/web; ortak web senaryosu kimlik adımını taşır ama web-react e2e ve vitest bu turda koşmadı) |
| attribution | PARTIAL (#1 ile aynı; utm_* okunur) |
| deeplink | PLANNED |
| revenue | PARTIAL (handle.trackRevenue → çekirdek feralin_purchase; vitest; verified yalnız sunucuda) |
| error | PARTIAL (FeralinErrorBoundary → @feralin/web/errors üzerinden fr_error, origin uncaught_exception; izin, örnekleme, sınır ve PII süzgeci çekirdekten; depoda, yayın bekliyor: npm'deki 0.1.0 içinde yok. vitest ve 17 Kasım 2026 yerel paketle scripts/sdk-e2e/run.mjs web-react: jsdom ve gerçek Next.js 16.4.5 + Chromium, gerçek collect 202, outbox ve ClickHouse'ta tam bir kez, izinsiz hata olay üretmedi. Olay işleyicisi ve Promise hataları sınıra ulaşmaz; React 18 sınanmadı; sembolleştirme yok) |
| replay | PLANNED |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS | vitest 24/24 (17 Kasım 2026, FeralinErrorBoundary dahil); window'suz react-dom/server SSR dahil. |
| registry | PASS | npm'de yayımlandı: @feralin/react@0.1.0 (17 Kasım 2026, git b1a7d127, org @feralin; ilk yayın site sahibinin tek onayıyla, docs/sdk/npm-yayin-adimlari.md B yolu; RELEASE_CANDIDATE dört göz koşulu bu yayında aranmadı). Registry'den geri okuma: latest 0.1.0, dist.integrity sha512-LIAOACxfuQX2… yerel kuru koşu paketinin özetiyle birebir aynı, sahip org @feralin. npm ilk yayında 2 dosyalık 0.0.0-stage yer tutucu sürümünü de oluşturdu; Feralin yayını değildir. |
| clean_install | PASS | npm pack çıktıları boş dizine kuruldu, ESM ve CommonJS yüklendi. Registry'den temiz kurulum: FERALIN_E2E_FROM_REGISTRY=1 scripts/sdk-e2e/run.mjs web-react (17 Kasım 2026): @feralin/web@0.1.0 ve @feralin/react@0.1.0 npmjs.org'dan hem jsdom tüketicisine hem Next.js uygulamasına kuruldu (özetler registry'deki dist.integrity ile aynı). |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs web-react: jsdom senaryoları ve gerçek Next.js 16.4.5 App Router (next build, next start, Chromium): 202, outbox, izinsiz red, 401, idempotency, iki page_view. React 18 ve Next 13-15 sınanmadı. Registry'den kurulan paketlerle: jsdom ve gerçek Next.js (Chromium) senaryoları geçti, outbox'ta 15 satır. ClickHouse'a düşmeyen iki Next.js page_view olayının kökü bulundu: başsız Chromium'un kullanıcı ajanı "HeadlessChrome" Feralin Protect tarafından bot sayılıp karantinaya alınıyordu (doğru davranış, services/collect/internal/protect/classifier.go). Test sıradan Chrome kullanıcı ajanıyla açılacak şekilde düzeltildi (f69e629b); 17 Kasım 2026'da registry'den kurulan paketlerle yeniden koşuldu: outbox 15 satır, ClickHouse'ta Next.js page_view olayları dahil 7 olay tam bir kez, izinsiz 2 olay yok. |
| documentation | PASS | docs/sdk/web-react.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
