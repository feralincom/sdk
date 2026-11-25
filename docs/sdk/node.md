<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Node.js: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/node/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/node` |
| Sürüm | 0.2.0 |
| Yaşam döngüsü | INSTALL_VERIFIED |
| Kaynak dizin | `sdks/node` |
| Registry | npm: **PUBLISHED** (sonraki adım: her paket için npm trusted publishing (OIDC); npm 2FA'yı atlayan anahtarla doğrudan yayını Ocak 2027'de kapatıyor) |
| Derleme | `pnpm --filter @feralin/node build` |
| Test | `pnpm --filter @feralin/node test` |

## Kurulum

```bash
npm install @feralin/node
```

## İlk kullanım

```ts
import { FeralinClient } from "@feralin/node";

const feralin = new FeralinClient({
  projectKey: process.env.FERALIN_PROJECT_KEY!, // pk_… anahtarı; kaynak koda yazmayın
  collectUrl: "https://collect.example.com",
});

// İzin kararı son kullanıcınındır; uygulamadan olay başına geçirilir.
feralin.track(
  "order_completed",
  { order_id: "ord_1", fr_click: clickId },
  { userId: "user_42", consent: { analytics: true, advertising: reklamIzni } },
);

// Kimlik yöntemleri (UTP §8.2): kimlik olay başına verilir, global özellikler istemci örneğinindir.
feralin.setUserProperties({ plan: "pro", tier: 2 }, { userId: "user_42", consent: { analytics: true } });
feralin.group("acme-team", { plan: "team" }, { userId: "user_42", consent: { analytics: true } });
feralin.setGlobalProperties({ app_release: "2026.11" });

// Yakalanan hata (`fr_error`): ham yığın izi gitmez; sınır saatte 20 olay, aynı hata için 3.
try {
  await siparisiKaydet();
} catch (error) {
  feralin.captureError(error, { userId: "user_42", consent: { analytics: true } });
}

// Kapanışta kalanı gönderin.
process.once("SIGTERM", () => void feralin.close());
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED |
| batch | PARTIAL (bellek içi kuyruk; isteğe bağlı storageDirectory kalıcı kuyruğu depoda, yayın bekliyor: npm'deki 0.1.0 içinde yok: çökme sonrası aynı batch bileşimi ve Idempotency-Key, boyut ve yaş sınırı, süreç başına günlük ve atomik devralma; node --test (gerçek alt süreç çökmesi, iki süreçli yarış) ve 17 Kasım 2026 yerel paketle scripts/sdk-e2e/run.mjs node çökme-yeniden başlama senaryosu: gerçek collect 202, outbox ve ClickHouse'ta tam bir kez. fsync yok, güç kesintisinde son satırlar kaybolabilir) |
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
| test | PASS |  |
| registry | PASS | npm'de yayımlandı: @feralin/node@0.1.0 (17 Kasım 2026, git b1a7d127, org @feralin; ilk yayın site sahibinin tek onayıyla, docs/sdk/npm-yayin-adimlari.md B yolu; RELEASE_CANDIDATE dört göz koşulu bu yayında aranmadı). Registry'den geri okuma: latest 0.1.0, dist.integrity sha512-bw5MjeFM3BeF… yerel kuru koşu paketinin özetiyle birebir aynı, sahip org @feralin. npm ilk yayında 2 dosyalık 0.0.0-stage yer tutucu sürümünü de oluşturdu; Feralin yayını değildir. |
| clean_install | PASS | npm pack çıktısı boş dizine kuruldu, ESM ve CommonJS yüklendi, 0 bağımlılık. Registry'den temiz kurulum: FERALIN_E2E_FROM_REGISTRY=1 scripts/sdk-e2e/run.mjs node (commit 6ec46869, 17 Kasım 2026): @feralin/node@0.1.0 npmjs.org'dan kuruldu (resolved https://registry.npmjs.org/@feralin/node/-/node-0.1.0.tgz), 0 bağımlılık. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs node: 202, outbox, izinsiz red, 401, idempotency. Registry'den kurulan @feralin/node@0.1.0 ile (commit 6ec46869): gerçek collect 202, outbox'ta 11 satır, ClickHouse'ta 7 olay tam bir kez, izinsiz 2 olay yok. |
| documentation | PASS | docs/sdk/node.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
