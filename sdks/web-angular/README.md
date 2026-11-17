# @feralin/angular

`@feralin/web` üstünde Angular bağdaştırıcısı: `provideFeralin` ve `FeralinService`. Dekoratör içermez, `ngc` gerektirmez, yalnız ESM'dir.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (vitest, `createApplication`, gerçek `renderApplication` ile window'suz SSR) | Geçiyor, Angular 22 |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs web-angular` ile geçti (jsdom, gerçek enjektör) |
| Angular CLI ile derlenmiş AOT uygulama, gerçek tarayıcı | **Çalıştırılmadı.** Testler Angular paketleri için JIT yükler |
| Angular 17-21 | Peer aralığında, sınanmadı |
| npm yayını | `BLOCKED_EXTERNAL`: `@feralin` organizasyonu yok |

## Kurulum

```bash
pnpm --filter @feralin/web build
cd packages/sdk-web && npm pack
cd ../../sdks/web-angular && npm pack
npm install ./feralin-web-0.1.0.tgz ./feralin-angular-0.1.0.tgz
```

## Kullanım

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

Rota geçişleri otomatik izlenmez. İlk sayfayı çekirdek gönderir, sonrakiler için:

```ts
inject(Router).events.pipe(filter((e) => e instanceof NavigationEnd), skip(1)).subscribe(() => feralin.page());
```

## İzin

`consent` verilmezse olay üretilmez; izin aracınızdan `feralin.setConsent({ analytics: true, advertising: false })` çağırın. Reklam izni yoksa `fr_click` çıkarılır. Yalnız public anahtar (`pk_`) kabul edilir; `sk_` ve başka önekler sunucuda ve tarayıcıda reddedilir, boşluklar kırpılır.

## SSR

`PLATFORM_ID` tarayıcı değilse istemci kurulmaz, servis boş yüzey olur.

## Desteklenmeyenler

- NgModule sarmalayıcısı ve otomatik router izleme yoktur.
- Hata raporlama ve replay yoktur. `trackRevenue` (`feralin_purchase`) istemci beyanıdır; `verified` gönderilmez, doğrulama sunucudaki makbuz doğrulayıcısınındır.
- Çekirdekten gelen sınırlar: üstel geri çekilme yok; yanıt kaybolduktan sonra araya olay girerse `Idempotency-Key` değişir ve kaybolan olay outbox'a ikinci kez yazılır. Düzeltme `packages/sdk-web` içindedir.
