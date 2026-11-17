# @feralin/nest

`@feralin/node` üstünde NestJS modülü. Küresel `FeralinService`, her HTTP isteğine `req.feralin` ekleyen interceptor ve `@CurrentFeralin()` parametre dekoratörü. Sağlayıcılar `useFactory` ile kurulur, tüketicinin `emitDecoratorMetadata` ayarına bağlı değildir.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (gerçek NestJS 12, platform-express, gerçek HTTP) | Geçiyor |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs node-nest` ile geçti |
| Fastify adaptörü, NestJS 10 ve 11 | Sınanmadı |
| npm yayını | `BLOCKED_EXTERNAL`: `@feralin` organizasyonu yok |

## Kurulum

```bash
cd sdks/node && npm pack
cd ../node-nest && npm pack
npm install ./feralin-node-0.1.0.tgz ./feralin-nest-0.1.0.tgz
```

## Kullanım

```ts
import { FeralinModule, CurrentFeralin, type RequestFeralin } from "@feralin/nest";

@Module({
  imports: [
    FeralinModule.forRoot({
      projectKey: process.env.FERALIN_PROJECT_KEY!, // pk_… anahtarı
      collectUrl: "https://collect.example.com",
      resolveConsent: (req) => izniOku(req), // { analytics, advertising }
    }),
  ],
})
export class AppModule {}

@Controller()
export class OrdersController {
  @Post("siparis")
  create(@CurrentFeralin() feralin: RequestFeralin) {
    feralin.track("order_completed", { order_id: "ord_1" });
  }
}
```

Kuyruk `app.close()` ile gönderilir; sinyalde çalışması için `app.enableShutdownHooks()` gerekir.

## İstek kapsamı

İstemci süreçte tektir, izin ve kimlik isteğe aittir. Bu yüzden:

| Nerede | Nasıl |
|---|---|
| Denetleyici ve onun çağırdığı servisler | `req.feralin` / `@CurrentFeralin()` ya da enjekte edilen `FeralinService`. `identify` ve `setConsent` yalnız o isteği etkiler; `FeralinService.track` o isteğin izni ve kimliğiyle gider |
| Korumalar (guard) | Interceptor'dan önce çalışırlar, kapsam henüz yoktur. Kimliği `req` üzerine koyun, `resolveUserId` okusun |
| Cron, kuyruk tüketicisi, RPC, WebSocket | `FeralinService.track(ad, ozellikler, { consent, userId })`: izin ve kimlik olay başına verilir. Burada `identify` ve `setConsent` hata verir |

`identify` ve `setConsent` istek dışında **açık hata** verir, çünkü paylaşılan istemciye yazılsa bir kullanıcının kimliği başka isteklere sızar, `analytics=false` herkesin olayını durdurup kuyruğu silerdi. Aynı nedenle `FeralinService.client.identify`, `client.setConsent`, `client.optOut` ve `client.reset` istek işlerken çağrılmaz; `client` süreç düzeyinde `flush` ve `getStatus` içindir.

## İzin

İzin kararı uygulamanındır. `resolveConsent` yoksa `consent` varsayılanı geçerlidir (varsayılan `analytics=false`). `undefined` dönerse veya hata atarsa izin yok sayılır, istek düşmez. `fr_click` yalnız `advertising === true` iken gider.

İstek içindeki `setConsent` kalıcı değildir ve daha önce kuyruğa girmiş olayı silmez: ret kararını saklayın, sonraki isteklerde `resolveConsent` döndürsün.

## Desteklenmeyenler

Yalnız HTTP bağlamı bağlanır; RPC ve WebSocket için olay başına yol kullanılır. IP, User-Agent ve çerez okunmaz, istek bağlamı (`page_url`) eklenmez. `group`, `setUserProperties`, `trackRevenue`, hata raporlama, OTel ve kalıcı kuyruk yoktur.
