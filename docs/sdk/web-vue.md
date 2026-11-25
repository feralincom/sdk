<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Vue / Nuxt: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/web-vue/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/vue` |
| Sürüm | 0.2.0 |
| Yaşam döngüsü | INSTALL_VERIFIED |
| Kaynak dizin | `sdks/web-vue` |
| Registry | npm: **PUBLISHED** (sonraki adım: her paket için npm trusted publishing (OIDC); npm 2FA'yı atlayan anahtarla doğrudan yayını Ocak 2027'de kapatıyor) |
| Derleme | `pnpm --filter @feralin/vue build` |
| Test | `pnpm --filter @feralin/vue test` |

## Kurulum

```bash
npm install @feralin/web @feralin/vue
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
| event | SUPPORTED (çerçeve katmanı #1 üstünde) |
| batch | SUPPORTED (#1 localStorage kuyruğu) |
| consent | SUPPORTED (fr_click reklam izni yoksa çıkarılır) |
| identity | SUPPORTED (identify, reset, group, setUserProperties, setGlobalProperties tutamakta, çekirdek @feralin/web; gerçek collect ile jsdom e2e geçti) |
| attribution | PARTIAL (#1 ile aynı; utm_* okunur) |
| deeplink | PLANNED |
| revenue | PARTIAL (handle.trackRevenue → çekirdek feralin_purchase; vitest; verified yalnız sunucuda) |
| error | PARTIAL (FeralinErrorHandler: app.config.errorHandler, önceki işleyiciyi zincirler, @feralin/web/errors üzerinden fr_error, origin uncaught_exception; izin, örnekleme, sınır ve PII süzgeci çekirdekten; depoda, yayın bekliyor: npm'deki 0.1.0 içinde yok. vitest ve 17 Kasım 2026 yerel paketle scripts/sdk-e2e/run.mjs web-vue: jsdom, gerçek collect 202, outbox ve ClickHouse'ta tam bir kez, izinsiz hata olay üretmedi. Gerçek tarayıcı ve Nuxt sınanmadı; sembolleştirme yok) |
| replay | PLANNED |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS | vitest 19/19 (17 Kasım 2026, FeralinErrorHandler dahil); gerçek vue-router, window'suz Vue SSR. Nuxt uygulaması koşmadı. |
| registry | PASS | npm'de yayımlandı: @feralin/vue@0.1.0 (17 Kasım 2026, git b1a7d127, org @feralin; ilk yayın site sahibinin tek onayıyla, docs/sdk/npm-yayin-adimlari.md B yolu; RELEASE_CANDIDATE dört göz koşulu bu yayında aranmadı). Registry'den geri okuma: latest 0.1.0, dist.integrity sha512-NDtfiGxvEVlG… yerel kuru koşu paketinin özetiyle birebir aynı, sahip org @feralin. npm ilk yayında 2 dosyalık 0.0.0-stage yer tutucu sürümünü de oluşturdu; Feralin yayını değildir. |
| clean_install | PASS | npm pack çıktıları boş dizine kuruldu, ESM ve CommonJS yüklendi. Registry'den temiz kurulum: FERALIN_E2E_FROM_REGISTRY=1 scripts/sdk-e2e/run.mjs web-vue (17 Kasım 2026): @feralin/web@0.1.0 ve @feralin/vue@0.1.0 npmjs.org'dan kuruldu (özetler registry'deki dist.integrity ile aynı). |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs web-vue: jsdom ve gerçek toplayıcı. Gerçek tarayıcı ve Nuxt build NOT_RUN. Registry'den kurulan paketlerle: Vue SSR ve jsdom, gerçek collect 202, outbox'ta 11 satır, ClickHouse'ta 5 olay tam bir kez, izinsiz 2 olay yok. |
| documentation | PASS | docs/sdk/web-vue.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
