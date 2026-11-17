<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Express: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/node-express/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/express` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/node-express` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: @feralin npm organizasyonu, 2FA, OIDC trusted publishing) |
| Derleme | `pnpm --filter @feralin/express build` |
| Test | `pnpm --filter @feralin/express test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
cd sdks/node && npm pack
cd ../node-express && npm pack
npm install ./feralin-node-0.1.0.tgz ./feralin-express-0.1.0.tgz
```

## İlk kullanım

```ts
import express from "express";
import { feralinMiddleware } from "@feralin/express";

const app = express();
const feralin = feralinMiddleware({
  projectKey: process.env.FERALIN_PROJECT_KEY!, // pk_… anahtarı; kaynak koda yazmayın
  collectUrl: "https://collect.example.com",
  resolveConsent: (req) => izniOku(req), // { analytics, advertising }
  resolveUserId: (req) => req.user?.id,
});
app.use(feralin);

app.post("/siparis", (req, res) => {
  req.feralin.track("order_completed", { order_id: "ord_1" });
  res.sendStatus(201);
});

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
| test | PASS | node --test 7/7; gerçek Express 5 ve HTTP. Express 4 sınanmadı. |
| registry | BLOCKED_EXTERNAL | @feralin npm organizasyonu yok. |
| clean_install | PASS | npm pack çıktıları boş dizine kuruldu, ESM ve CommonJS yüklendi. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs node-express: gerçek HTTP, 202, outbox, izinsiz red, 401, idempotency. |
| documentation | PASS | docs/sdk/node-express.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
