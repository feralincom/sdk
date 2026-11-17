<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Web JS/TS: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `packages/sdk-web/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/web` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `packages/sdk-web` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: @feralin npm organizasyonu, 2FA, OIDC trusted publishing) |
| Derleme | `pnpm --filter @feralin/web build` |
| Test | `pnpm --filter @feralin/web test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
# depo kökünde
pnpm --filter @feralin/web build
npm pack ./packages/sdk-web
# uygulamanızın dizininde (DEPO: deponun yolu)
npm install DEPO/feralin-web-0.1.0.tgz
```

## İlk kullanım

```html
<script src="https://feralin.com/sdk/feralin.iife.js" defer></script>
<script>
  window.addEventListener("load", () => {
    feralin.initialize({
      projectKey: "pk_live_…",              // yalnız public anahtar
      collectUrl: "https://collect.feralin.com",
      consent: { analytics: true, advertising: false }, // consent yoksa olay üretilmez
    });
  });
</script>
```

```ts
import { initialize, track } from "@feralin/web";
initialize({ projectKey: "pk_live_…", collectUrl: "https://collect.feralin.com", consent: { analytics: true } });
track("signup_completed", { plan: "growth" });
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız) |
| batch | SUPPORTED (yayınsız; localStorage kuyruk) |
| consent | SUPPORTED (yayınsız) |
| identity | SUPPORTED (yayınsız; identify, reset, group → fr_group, setUserProperties → fr_user_properties, setGlobalProperties/clearGlobalProperties; kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer istemcide düşer; toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar; birim testli, gerçek collect ile web-vue ve web-angular jsdom e2e geçti) |
| attribution | PARTIAL (utm_* okunur; web→store referrer yok) |
| deeplink | PLANNED |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL) |
| error | PARTIAL (`@feralin/web/errors`: window error ve unhandledrejection, fr_error, parmak izi, örnekleme ve sınır, birim testli; sembolleştirme yok, PLANNED) |
| replay | PLANNED |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS |  |
| registry | BLOCKED_EXTERNAL | @feralin npm organizasyonu yok; bugün /sdk/feralin.iife.js ile sunulur. |
| clean_install | PASS | scripts/sdk-e2e/run.mjs web: tam derleme (esbuild ve tip bildirimleri), npm pack, boş dizine yalnız tarball ve jsdom; 0 çalışma zamanı bağımlılığı, types/IIFE/ESM/CJS dosyaları pakette, paket adıyla ESM ve CommonJS içe aktarma, auto/errors/vitals/flags/replay alt yolları yüklendi. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs web: temiz kurulumdan jsdom penceresinde gerçek toplayıcı: page_view, 202 ve outbox, fr_click reklam iznine bağlı, izinsiz red, 401, idempotency, örnek devri. Gerçek tarayıcı akışı ayrıca Playwright ve canlı duman testinde. |
| documentation | PASS | docs/sdk/web.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
