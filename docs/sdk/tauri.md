<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Tauri: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/tauri/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/tauri` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/tauri` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: olay alındısı halkası PASS (gerçek Tauri penceresi); sonra npm trusted publishing (OIDC)) |
| Derleme | `pnpm --filter @feralin/tauri build` |
| Test | `pnpm --filter @feralin/tauri test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
pnpm --filter @feralin/web build
cd packages/sdk-web && npm pack
cd ../../sdks/tauri && npm pack
npm install ./feralin-web-0.1.0.tgz ./feralin-tauri-0.1.0.tgz
```

## İlk kullanım

```ts
import { createFeralinTauri } from "@feralin/tauri";

const feralin = createFeralinTauri({ projectKey: "pk_live_…", collectUrl: "https://collect.example.com", consent: { analytics: true } });
feralin.page();
feralin.track("project_opened");
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız; #1 üstünde, gerçek Tauri penceresinde sınanmadı) |
| batch | PARTIAL (web görünümü localStorage kuyruğu, şifreli değil) |
| consent | SUPPORTED (yayınsız; fr_click reklam izni yoksa çıkarılır) |
| identity | PARTIAL (identify, reset, group, setUserProperties, setGlobalProperties tutamakta; vitest geçti, e2e koşmadı) |
| attribution | N/A |
| deeplink | PARTIAL (opt-in deepLinks, src/deeplink.ts; vitest; gerçek pencerede koşmadı) |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; vitest testli, gerçek toplayıcı e2e yok) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; vitest testli, sembolleştirme yok) (opt-in) |
| replay | PLANNED |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS | vitest 9/9; jsdom, Tauri işareti elle. |
| registry | BLOCKED_EXTERNAL | @feralin npm organizasyonu 17 Kasım 2026'da açıldı; paket olay alındısı halkası PARTIAL olduğu için yayın kapısında engelli ve yayınlanmadı. |
| clean_install | PASS | npm pack çıktıları boş dizine kuruldu, ESM ve CommonJS yüklendi. |
| event_receipt | PARTIAL | scripts/sdk-e2e/run.mjs tauri: jsdom ve gerçek toplayıcı. Gerçek Tauri penceresi KOŞMADI, Rust eklentisi yok. |
| documentation | PASS | docs/sdk/tauri.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
