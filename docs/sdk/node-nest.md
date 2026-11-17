<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# NestJS: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/node-nest/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/nest` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INSTALL_VERIFIED |
| Kaynak dizin | `sdks/node-nest` |
| Registry | npm: **PUBLISHED** (sonraki adım: her paket için npm trusted publishing (OIDC); npm 2FA'yı atlayan anahtarla doğrudan yayını Ocak 2027'de kapatıyor) |
| Derleme | `pnpm --filter @feralin/nest build` |
| Test | `pnpm --filter @feralin/nest test` |

## Kurulum

```bash
npm install @feralin/node @feralin/nest
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil) |
| consent | SUPPORTED (olay başına passthrough) |
| identity | SUPPORTED (identify, reset, group ve setUserProperties kimlik TrackOptions ile, setGlobalProperties/clearGlobalProperties istemci örneğine bağlı; kişisel veriye benzeyen anahtar istemcide düşer, toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar; birim testli, gerçek collect e2e geçti) |
| attribution | N/A |
| deeplink | N/A |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; node --test testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS | node --test 7/7; gerçek NestJS 12, platform-express. Fastify, NestJS 10 ve 11 sınanmadı. |
| registry | PASS | npm'de yayımlandı: @feralin/nest@0.1.0 (17 Kasım 2026, git b1a7d127, org @feralin; ilk yayın site sahibinin tek onayıyla, docs/sdk/npm-yayin-adimlari.md B yolu; RELEASE_CANDIDATE dört göz koşulu bu yayında aranmadı). Registry'den geri okuma: latest 0.1.0, dist.integrity sha512-IUOpl475Dvsr… yerel kuru koşu paketinin özetiyle birebir aynı, sahip org @feralin. npm ilk yayında 2 dosyalık 0.0.0-stage yer tutucu sürümünü de oluşturdu; Feralin yayını değildir. |
| clean_install | PASS | npm pack çıktıları boş dizine kuruldu, ESM ve CommonJS yüklendi. Registry'den temiz kurulum: FERALIN_E2E_FROM_REGISTRY=1 scripts/sdk-e2e/run.mjs node-nest (17 Kasım 2026): @feralin/node@0.1.0 ve @feralin/nest@0.1.0 npmjs.org'dan kuruldu (resolved https://registry.npmjs.org/@feralin/nest/-/nest-0.1.0.tgz, kilit dosyasındaki sürüm ve özet registry'deki dist.integrity ile aynı). |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs node-nest: gerçek HTTP, 202, outbox, izinsiz red, 401, idempotency. Registry'den kurulan @feralin/nest@0.1.0 ile (17 Kasım 2026): gerçek collect 202 (6 istek) ve 401, outbox'ta 8 satır, ClickHouse'ta 3 olay tam bir kez. |
| documentation | PASS | docs/sdk/node-nest.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
