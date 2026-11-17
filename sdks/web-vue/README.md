# @feralin/vue

`@feralin/web` üstünde Vue 3 bağdaştırıcısı: `FeralinPlugin` ve `useFeralin`. Çekirdek ayrı peer bağımlılığıdır.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (vitest, jsdom, gerçek vue-router, window'suz Vue SSR) | Geçiyor |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs web-vue` ile geçti (jsdom) |
| Nuxt uygulaması | **Çalıştırılmadı.** Plugin'in sunucuda yaptığı çağrılar Vue SSR ile sınandı, `nuxt build` denenmedi |
| Gerçek tarayıcı | Sınanmadı |
| npm yayını | `BLOCKED_EXTERNAL`: `@feralin` organizasyonu yok |

## Kurulum

```bash
pnpm --filter @feralin/web build
cd packages/sdk-web && npm pack
cd ../../sdks/web-vue && npm pack
npm install ./feralin-web-0.1.0.tgz ./feralin-vue-0.1.0.tgz
```

## Kullanım

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

`router` verilirse yol değişiminde `page_view` üretilir; iptal edilen gezinme ve yalnız sorgu değişimi sayılmaz.

Nuxt (`plugins/feralin.ts`, sunucuda da güvenle yüklenir):

```ts
import { FeralinPlugin } from "@feralin/vue";

export default defineNuxtPlugin((nuxtApp) => {
  nuxtApp.vueApp.use(FeralinPlugin, { projectKey: "pk_live_…", collectUrl: "https://collect.example.com", router: useRouter() });
});
```

## İzin

`consent` verilmezse olay üretilmez; izin aracınızdan `useFeralin().setConsent({ analytics: true, advertising: false })` çağırın. Reklam izni yoksa `fr_click` çıkarılır. Yalnız public anahtar (`pk_`) kabul edilir; `sk_` ve başka önekler sunucuda ve tarayıcıda reddedilir, boşluklar kırpılır.

## Desteklenmeyenler

- Ayrı Nuxt modülü yoktur, plugin dosyası elle eklenir.
- Hata raporlama ve replay yoktur. `trackRevenue` (`feralin_purchase`) istemci beyanıdır; `verified` gönderilmez, doğrulama sunucudaki makbuz doğrulayıcısınındır.
- Çekirdekten gelen sınırlar: üstel geri çekilme yok; yanıt kaybolduktan sonra araya olay girerse `Idempotency-Key` değişir ve kaybolan olay outbox'a ikinci kez yazılır. Düzeltme `packages/sdk-web` içindedir.
