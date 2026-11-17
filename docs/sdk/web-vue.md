<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Vue / Nuxt: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/web-vue/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/vue` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/web-vue` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: @feralin npm organizasyonu, 2FA, OIDC trusted publishing) |
| Derleme | `pnpm --filter @feralin/vue build` |
| Test | `pnpm --filter @feralin/vue test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
pnpm --filter @feralin/web build
cd packages/sdk-web && npm pack
cd ../../sdks/web-vue && npm pack
npm install ./feralin-web-0.1.0.tgz ./feralin-vue-0.1.0.tgz
```

## İlk kullanım

```ts
import { createApp } from "vue";
import { FeralinPlugin } from "@feralin/vue";

createApp(App)
  .use(FeralinPlugin, { projectKey: "pk_live_…", collectUrl: "https://collect.example.com", consent: { analytics: true }, router })
  .use(router)
  .mount("#app");
```

```ts
import { useFeralin } from "@feralin/vue";
const feralin = useFeralin();
feralin.track("signup_completed", { plan: "growth" });
```

```ts
import { FeralinPlugin } from "@feralin/vue";

export default defineNuxtPlugin((nuxtApp) => {
  nuxtApp.vueApp.use(FeralinPlugin, { projectKey: "pk_live_…", collectUrl: "https://collect.example.com", router: useRouter() });
});
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız; çerçeve katmanı #1 üstünde) |
| batch | SUPPORTED (yayınsız; #1 localStorage kuyruğu) |
| consent | SUPPORTED (yayınsız; fr_click reklam izni yoksa çıkarılır) |
| identity | SUPPORTED (yayınsız; identify, reset, group, setUserProperties, setGlobalProperties tutamakta, çekirdek @feralin/web; gerçek collect ile jsdom e2e geçti) |
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
| test | PASS | vitest 12/12; gerçek vue-router, window'suz Vue SSR. Nuxt uygulaması koşmadı. |
| registry | BLOCKED_EXTERNAL | @feralin npm organizasyonu yok. |
| clean_install | PASS | npm pack çıktıları boş dizine kuruldu, ESM ve CommonJS yüklendi. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs web-vue: jsdom ve gerçek toplayıcı. Gerçek tarayıcı ve Nuxt build NOT_RUN. |
| documentation | PASS | docs/sdk/web-vue.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
