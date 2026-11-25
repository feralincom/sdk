<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Web JS/TS: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `packages/sdk-web/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/web` |
| Sürüm | 0.2.0 |
| Yaşam döngüsü | INSTALL_VERIFIED |
| Kaynak dizin | `packages/sdk-web` |
| Registry | npm: **PUBLISHED** (sonraki adım: her paket için npm trusted publishing (OIDC); npm 2FA'yı atlayan anahtarla doğrudan yayını Ocak 2027'de kapatıyor) |
| Derleme | `pnpm --filter @feralin/web build` |
| Test | `pnpm --filter @feralin/web test` |

## Kurulum

```bash
npm install @feralin/web
```

## İlk kullanım

```html
<script src="https://feralin.com/sdk/feralin.iife.js" defer></script>
<script>
  window.addEventListener("load", () => {
    feralin.initialize({
      projectKey: "pk_live_…",              // yalnız public anahtar
      collectUrl: "https://feralin.com/collect",
      consent: { analytics: true, advertising: false }, // consent yoksa olay üretilmez
    });
  });
</script>
```

```ts
import { initialize, track } from "@feralin/web";
initialize({ projectKey: "pk_live_…", collectUrl: "https://feralin.com/collect", consent: { analytics: true } });
track("signup_completed", { plan: "growth" });
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED |
| batch | SUPPORTED (localStorage kuyruk) |
| consent | SUPPORTED |
| identity | SUPPORTED (identify, reset, group → fr_group, setUserProperties → fr_user_properties, setGlobalProperties/clearGlobalProperties; kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer istemcide düşer; toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar; birim testli, gerçek collect ile web-vue ve web-angular jsdom e2e geçti) |
| attribution | PARTIAL (utm_* okunur; web→store referrer yok) |
| deeplink | PLANNED |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL) |
| error | PARTIAL (`@feralin/web/errors`: window error ve unhandledrejection, fr_error, parmak izi, örnekleme ve sınır, birim testli; sembolleştirme: en üst 5 çerçevenin konumu (dosya taban adı, satır, sütun) gider, yüklenen JavaScript kaynak haritasıyla (UI-067, migrasyon 0133, symbols:write) okuma anında kaynağa çözülür; gerçek esbuild çıktısıyla PostgreSQL ve ClickHouse entegrasyon testli (performance-symbols.integration.spec.ts); dizinli (sections) harita ve derleme aracı eklentisiyle otomatik yükleme yok; V8 yığın başlığındaki `@` içeren mesajın top_frame alanına girmesi düzeltildi (depoda, yayın bekliyor: npm'deki 0.1.0 içinde yok; toplayıcı alanı sunucuda zaten temizliyordu)) |
| replay | PARTIAL (`@feralin/web/replay`: yalnız heatmap etkileşim olayları fr_replay_click/scroll/view; maskeli seçici, yüzde koordinat, görünüm alanı sınıfı; çift izin kapısı (analytics ve session_replay), toplayıcı da session_replay olmadan reddeder; birim testli, Go filtre testli; DOM kaydı, metin ve oturum oynatma yok) |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS |  |
| registry | PASS | npm'de yayımlandı: @feralin/web@0.1.0 (17 Kasım 2026, git b1a7d127, org @feralin; ilk yayın site sahibinin tek onayıyla, docs/sdk/npm-yayin-adimlari.md B yolu; RELEASE_CANDIDATE dört göz koşulu bu yayında aranmadı). Registry'den geri okuma: latest 0.1.0, dist.integrity sha512-V0j8ubuY/yKT… yerel kuru koşu paketinin özetiyle birebir aynı, sahip org @feralin. npm ilk yayında 2 dosyalık 0.0.0-stage yer tutucu sürümünü de oluşturdu; Feralin yayını değildir. |
| clean_install | PASS | scripts/sdk-e2e/run.mjs web: tam derleme (esbuild ve tip bildirimleri), npm pack, boş dizine yalnız tarball ve jsdom; 0 çalışma zamanı bağımlılığı, types/IIFE/ESM/CJS dosyaları pakette, paket adıyla ESM ve CommonJS içe aktarma, auto/errors/vitals/flags/replay alt yolları yüklendi. Registry'den temiz kurulum: FERALIN_E2E_FROM_REGISTRY=1 scripts/sdk-e2e/run.mjs web (17 Kasım 2026): @feralin/web@0.1.0 npmjs.org'dan kuruldu (resolved https://registry.npmjs.org/@feralin/web/-/web-0.1.0.tgz, özet registry'deki dist.integrity ile aynı). |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs web: temiz kurulumdan jsdom penceresinde gerçek toplayıcı: page_view, 202 ve outbox, fr_click reklam iznine bağlı, izinsiz red, 401, idempotency, örnek devri. Gerçek tarayıcı akışı ayrıca Playwright ve canlı duman testinde. Registry'den kurulan @feralin/web@0.1.0 ile: gerçek collect 202 (11 istek) ve 401, outbox'ta 11 satır, ClickHouse'ta 5 olay tam bir kez, izinsiz 2 olay yok. |
| documentation | PASS | docs/sdk/web.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
