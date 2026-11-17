<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Angular: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/web-angular/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/angular` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/web-angular` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: @feralin npm organizasyonu, 2FA, OIDC trusted publishing) |
| Derleme | `pnpm --filter @feralin/angular build` |
| Test | `pnpm --filter @feralin/angular test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
pnpm --filter @feralin/web build
cd packages/sdk-web && npm pack
cd ../../sdks/web-angular && npm pack
npm install ./feralin-web-0.1.0.tgz ./feralin-angular-0.1.0.tgz
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
| event | SUPPORTED (yayınsız; çerçeve katmanı #1 üstünde) |
| batch | SUPPORTED (yayınsız; #1 localStorage kuyruğu) |
| consent | SUPPORTED (yayınsız; fr_click reklam izni yoksa çıkarılır) |
| identity | SUPPORTED (yayınsız; identify, reset, group, setUserProperties, setGlobalProperties FeralinService üzerinde, çekirdek @feralin/web; gerçek collect ile jsdom e2e geçti) |
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
| test | PASS | vitest 12/12; Angular 22 createApplication ve window'suz renderApplication, JIT ile. |
| registry | BLOCKED_EXTERNAL | @feralin npm organizasyonu yok. |
| clean_install | PASS | npm pack çıktıları boş dizine kuruldu. Yalnız ESM. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs web-angular: gerçek enjektör, jsdom ve gerçek toplayıcı. Angular CLI AOT derlemesi ve gerçek tarayıcı NOT_RUN. |
| documentation | PASS | docs/sdk/web-angular.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
