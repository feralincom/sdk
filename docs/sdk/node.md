<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Node.js: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/node/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/node` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/node` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: @feralin npm organizasyonu, 2FA, OIDC trusted publishing) |
| Derleme | `pnpm --filter @feralin/node build` |
| Test | `pnpm --filter @feralin/node test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
# depo kökünde
npm pack ./sdks/node
# uygulamanızın dizininde (DEPO: deponun yolu)
npm install DEPO/feralin-node-0.1.0.tgz
```

## İlk kullanım

```ts
import { FeralinClient } from "@feralin/node";

const feralin = new FeralinClient({
  projectKey: process.env.FERALIN_PROJECT_KEY!, // pk_… anahtarı; kaynak koda yazmayın
  collectUrl: "https://collect.example.com",
});

// İzin kararı son kullanıcınındır; uygulamadan olay başına geçirilir.
feralin.track(
  "order_completed",
  { order_id: "ord_1", fr_click: clickId },
  { userId: "user_42", consent: { analytics: true, advertising: reklamIzni } },
);

// Kimlik yöntemleri (UTP §8.2): kimlik olay başına verilir, global özellikler istemci örneğinindir.
feralin.setUserProperties({ plan: "pro", tier: 2 }, { userId: "user_42", consent: { analytics: true } });
feralin.group("acme-team", { plan: "team" }, { userId: "user_42", consent: { analytics: true } });
feralin.setGlobalProperties({ app_release: "2026.11" });

// Yakalanan hata (`fr_error`): ham yığın izi gitmez; sınır saatte 20 olay, aynı hata için 3.
try {
  await siparisiKaydet();
} catch (error) {
  feralin.captureError(error, { userId: "user_42", consent: { analytics: true } });
}

// Kapanışta kalanı gönderin.
process.once("SIGTERM", () => void feralin.close());
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız) |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil) |
| consent | SUPPORTED (yayınsız; olay başına passthrough) |
| identity | SUPPORTED (yayınsız; identify, reset, group ve setUserProperties kimlik TrackOptions ile, setGlobalProperties/clearGlobalProperties istemci örneğine bağlı; kişisel veriye benzeyen anahtar istemcide düşer, toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar; birim testli, gerçek collect e2e geçti) |
| attribution | N/A |
| deeplink | N/A |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; node --test testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS |  |
| registry | BLOCKED_EXTERNAL | @feralin npm organizasyonu yok. |
| clean_install | PASS | npm pack çıktısı boş dizine kuruldu, ESM ve CommonJS yüklendi, 0 bağımlılık. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs node: 202, outbox, izinsiz red, 401, idempotency. |
| documentation | PASS | docs/sdk/node.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
