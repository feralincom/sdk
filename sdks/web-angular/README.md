# @feralin/angular

`@feralin/web` üstünde Angular bağdaştırıcısı: `provideFeralin` ve `FeralinService`. Dekoratör içermez, `ngc` gerektirmez, yalnız ESM'dir.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (vitest, `createApplication`, gerçek `renderApplication` ile window'suz SSR) | Geçiyor, Angular 22 |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs web-angular` ile geçti (jsdom, gerçek enjektör) |
| Angular CLI ile derlenmiş AOT uygulama, gerçek tarayıcı | **Çalıştırılmadı.** Testler Angular paketleri için JIT yükler |
| Angular 17-21 | Peer aralığında, sınanmadı |
| npm yayını | npm'de yayımlandı: `@feralin/angular@0.1.0` (17 Kasım 2026, `@feralin` organizasyonu); sürüm ve özet registry'den geri okundu |

## Kurulum

Çekirdek peer bağımlılığıdır, iki paket birlikte kurulur:

```bash
npm install @feralin/web @feralin/angular
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

## Hata yakalama (`provideFeralinErrorHandler`)

> Yayın bekliyor: depoda var, npm'deki `@feralin/angular@0.1.0` içinde yok. Sonraki sürümle yayımlanacak.

```ts
import { bootstrapApplication } from "@angular/platform-browser";
import { provideFeralin, provideFeralinErrorHandler } from "@feralin/angular";

bootstrapApplication(AppComponent, {
  providers: [
    provideFeralin({ projectKey: "pk_live_...", collectUrl: "https://feralin.com/collect" }),
    provideFeralinErrorHandler({ appVersion: "1.4.2", delegate: new MyErrorHandler() }),
  ],
});
```

Uygulamanın `ErrorHandler`'ı olur: bileşen ve değişiklik algılama hataları (Angular 20+ `provideBrowserGlobalErrorListeners` açıksa pencere hataları da) `fr_error` olarak gider (`origin: "uncaught_exception"`, `handled: false`, `fatal: false`), ardından `delegate.handleError` çağrılır; `delegate` yoksa Angular'ın varsayılanı gibi `console.error("ERROR", hata)` yazılır. Gövde, PII temizliği, parmak izi, örnekleme ve sınır `@feralin/web/errors` modülündendir; ham yığın izi gitmez. İzin yoksa olay üretilmez ve sınır sayacı harcanmaz. Sunucuda (Angular SSR) olay üretmez, `delegate` yine çağrılır. `provideFeralin` olmadan kurulursa yalnız `delegate` çalışır.

## Desteklenmeyenler

- NgModule sarmalayıcısı ve otomatik router izleme yoktur.
- Replay yoktur. `trackRevenue` (`feralin_purchase`) istemci beyanıdır; `verified` gönderilmez, doğrulama sunucudaki makbuz doğrulayıcısınındır.
- Çekirdekten gelen sınırlar: üstel geri çekilme yok; yanıt kaybolduktan sonra araya olay girerse `Idempotency-Key` değişir ve kaybolan olay outbox'a ikinci kez yazılır. Düzeltme `packages/sdk-web` içindedir.
