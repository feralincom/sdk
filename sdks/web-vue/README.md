# @feralin/vue

`@feralin/web` üstünde Vue 3 bağdaştırıcısı: `FeralinPlugin` ve `useFeralin`. Çekirdek ayrı peer bağımlılığıdır.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (vitest, jsdom, gerçek vue-router, window'suz Vue SSR) | Geçiyor |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs web-vue` ile geçti (jsdom) |
| Nuxt uygulaması | **Çalıştırılmadı.** Plugin'in sunucuda yaptığı çağrılar Vue SSR ile sınandı, `nuxt build` denenmedi |
| Gerçek tarayıcı | Sınanmadı |
| npm yayını | npm'de yayımlandı: `@feralin/vue@0.1.0` (17 Kasım 2026, `@feralin` organizasyonu); sürüm ve özet registry'den geri okundu |

## Kurulum

Çekirdek peer bağımlılığıdır, iki paket birlikte kurulur:

```bash
npm install @feralin/web @feralin/vue
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

## Hata yakalama (`FeralinErrorHandler`)

> Yayın bekliyor: depoda var, npm'deki `@feralin/vue@0.1.0` içinde yok. Sonraki sürümle yayımlanacak.

```ts
import { createApp } from "vue";
import { FeralinErrorHandler, FeralinPlugin } from "@feralin/vue";

const app = createApp(App);
app.use(FeralinPlugin, { projectKey: "pk_live_...", collectUrl: "https://feralin.com/collect" });
app.use(FeralinErrorHandler, { appVersion: "1.4.2", sampleRate: 1 });
app.mount("#app");
```

`app.config.errorHandler` olur: bileşen çizimi, kurulum, yaşam döngüsü, izleyici ve bileşen olay işleyicisi hataları `fr_error` olarak gider (`origin: "uncaught_exception"`, `handled: false`, `fatal: false`). Kurulumdan önce atanmış işleyici aynı argümanlarla çağrılır (eklentiyi kendi işleyicinizden sonra kurun); yoksa hata `console.error` ile yazılır. Gövde, PII temizliği, parmak izi, örnekleme ve sınır `@feralin/web/errors` modülündendir; ham yığın izi gitmez. İzin yoksa olay üretilmez ve sınır sayacı harcanmaz. İstemci hata anında `FeralinPlugin`'den çözülür (eklenti sırası önemsiz) ya da `feralin` seçeneğiyle verilir. Sunucuda (Vue SSR, Nuxt) olay üretmez. Vue dışındaki pencere hataları için `@feralin/web/errors` içindeki `captureErrors` ayrıca kurulabilir.

## Desteklenmeyenler

- Ayrı Nuxt modülü yoktur, plugin dosyası elle eklenir.
- Replay yoktur. `trackRevenue` (`feralin_purchase`) istemci beyanıdır; `verified` gönderilmez, doğrulama sunucudaki makbuz doğrulayıcısınındır.
- Çekirdekten gelen sınırlar: üstel geri çekilme yok; yanıt kaybolduktan sonra araya olay girerse `Idempotency-Key` değişir ve kaybolan olay outbox'a ikinci kez yazılır. Düzeltme `packages/sdk-web` içindedir.
