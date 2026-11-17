<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Angular: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/web-angular/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/angular` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INSTALL_VERIFIED |
| Kaynak dizin | `sdks/web-angular` |
| Registry | npm: **PUBLISHED** (sonraki adım: her paket için npm trusted publishing (OIDC); npm 2FA'yı atlayan anahtarla doğrudan yayını Ocak 2027'de kapatıyor) |
| Derleme | `pnpm --filter @feralin/angular build` |
| Test | `pnpm --filter @feralin/angular test` |

## Kurulum

```bash
npm install @feralin/web @feralin/angular
```

## İlk kullanım

```ts
import { bootstrapApplication } from "@angular/platform-browser";
import { provideFeralin } from "@feralin/angular";

bootstrapApplication(AppComponent, {
  providers: [provideFeralin({ projectKey: "pk_live_…", collectUrl: "https://collect.example.com", consent: { analytics: true } })],
});
```

```ts
import { inject } from "@angular/core";
import { FeralinService } from "@feralin/angular";

const feralin = inject(FeralinService);
feralin.track("signup_completed", { plan: "growth" });
```

```ts
inject(Router).events.pipe(filter((e) => e instanceof NavigationEnd), skip(1)).subscribe(() => feralin.page());
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (çerçeve katmanı #1 üstünde) |
| batch | SUPPORTED (#1 localStorage kuyruğu) |
| consent | SUPPORTED (fr_click reklam izni yoksa çıkarılır) |
| identity | SUPPORTED (identify, reset, group, setUserProperties, setGlobalProperties FeralinService üzerinde, çekirdek @feralin/web; gerçek collect ile jsdom e2e geçti) |
| attribution | PARTIAL (#1 ile aynı; utm_* okunur) |
| deeplink | PLANNED |
| revenue | PARTIAL (handle.trackRevenue → çekirdek feralin_purchase; vitest; verified yalnız sunucuda) |
| error | PARTIAL (provideFeralinErrorHandler: Angular ErrorHandler, delegate'i zincirler, @feralin/web/errors üzerinden fr_error, origin uncaught_exception; izin, örnekleme, sınır ve PII süzgeci çekirdekten; depoda, yayın bekliyor: npm'deki 0.1.0 içinde yok. vitest (gerçek createApplication ve sunucu enjektörü) ve 17 Kasım 2026 yerel paketle scripts/sdk-e2e/run.mjs web-angular: gerçek enjektör, jsdom, gerçek collect 202, outbox ve ClickHouse'ta tam bir kez, izinsiz hata olay üretmedi. Angular CLI AOT derlemesi ve gerçek tarayıcı sınanmadı; sembolleştirme yok) |
| replay | PLANNED |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS | vitest 20/20 (17 Kasım 2026, provideFeralinErrorHandler dahil); Angular 22 createApplication ve window'suz renderApplication, JIT ile. |
| registry | PASS | npm'de yayımlandı: @feralin/angular@0.1.0 (17 Kasım 2026, git b1a7d127, org @feralin; ilk yayın site sahibinin tek onayıyla, docs/sdk/npm-yayin-adimlari.md B yolu; RELEASE_CANDIDATE dört göz koşulu bu yayında aranmadı). Registry'den geri okuma: latest 0.1.0, dist.integrity sha512-r8VtAreKPN5+… yerel kuru koşu paketinin özetiyle birebir aynı, sahip org @feralin. npm ilk yayında 2 dosyalık 0.0.0-stage yer tutucu sürümünü de oluşturdu; Feralin yayını değildir. |
| clean_install | PASS | npm pack çıktıları boş dizine kuruldu. Yalnız ESM. Registry'den temiz kurulum: FERALIN_E2E_FROM_REGISTRY=1 scripts/sdk-e2e/run.mjs web-angular (17 Kasım 2026): @feralin/web@0.1.0 ve @feralin/angular@0.1.0 npmjs.org'dan kuruldu (resolved https://registry.npmjs.org/@feralin/angular/-/angular-0.1.0.tgz, kilit dosyasındaki sürüm ve özet registry'deki dist.integrity ile aynı). |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs web-angular: gerçek enjektör, jsdom ve gerçek toplayıcı. Angular CLI AOT derlemesi ve gerçek tarayıcı NOT_RUN. Registry'den kurulan @feralin/angular@0.1.0 ile (17 Kasım 2026): gerçek collect 202 (11 istek) ve 401, outbox'ta 11 satır, kimlik denetimi 9 satır, ClickHouse'ta 5 olay tam bir kez, izinsiz 2 olay yok. |
| documentation | PASS | docs/sdk/web-angular.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
