<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Electron: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/electron/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/electron` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/electron` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: @feralin npm organizasyonu, 2FA, OIDC trusted publishing) |
| Derleme | `pnpm --filter @feralin/electron build` |
| Test | `pnpm --filter @feralin/electron test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
cd sdks/node && npm pack
cd ../electron && npm pack
npm install ./feralin-node-0.1.0.tgz ./feralin-electron-0.1.0.tgz
```

## İlk kullanım

```ts
import { app, BrowserWindow, ipcMain } from "electron";
import { createFeralinMain } from "@feralin/electron/main";

app.whenReady().then(() => {
  createFeralinMain({
    ipcMain,
    app, // kapanışta kuyruk gönderilir, sürüm ve dil olaya eklenir
    projectKey: "pk_live_…",
    collectUrl: "https://collect.example.com",
    allowedOrigins: ["app://arayuz"],
  });
  new BrowserWindow({ webPreferences: { preload: PRELOAD_YOLU, contextIsolation: true, sandbox: true } });
});
```

```ts
import { contextBridge, ipcRenderer } from "electron";
import { exposeFeralin } from "@feralin/electron/preload";

exposeFeralin({ contextBridge, ipcRenderer });
```

```bash
npx esbuild preload.ts --bundle --platform=node --format=cjs --external:electron --outfile=preload.bundle.cjs
```

```ts
import { getFeralin } from "@feralin/electron/renderer";

const feralin = getFeralin();
await feralin.setConsent({ analytics: true, advertising: false });
await feralin.track("project_opened");
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız; #7 üstünde, platform=node) |
| batch | PARTIAL (ana süreç belleğinde kuyruk, kalıcı ve şifreli değil) |
| consent | SUPPORTED (yayınsız; köprüden setConsent, süreç başına) |
| identity | PARTIAL (identify, reset; group ve setUserProperties renderer köprüsünde, doğrulama ana süreçte; kurulum kimliğini uygulama verir) |
| attribution | PARTIAL (installCode → fr_install_code eşleştirme kodu; mağaza referrer yolu yok) |
| deeplink | PARTIAL (opt-in deepLinks: özel protokol, open-url ve second-instance adresi SDK derin bağlantı akışına verilir; birim testli, gerçek pencerede koşmadı) |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; node --test testli, gerçek toplayıcı e2e yok) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; node --test testli, sembolleştirme yok) |
| replay | PLANNED |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS | node --test 13/13; taklit IPC ile. |
| registry | BLOCKED_EXTERNAL | @feralin npm organizasyonu yok. |
| clean_install | PASS | npm pack çıktıları boş dizine kuruldu, ESM ve CommonJS yüklendi. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs electron ile FERALIN_E2E_ELECTRON_RUNTIME=1: gerçek Electron süreci, sandbox ve contextIsolation açık, paketlenmiş preload, gerçek IPC ve gerçek toplayıcı. Olaylarda platform=node; UTP şemasında masaüstü değeri yok. Yalnız Windows; macOS, Linux ve imzalı paket NOT_RUN. |
| documentation | PASS | docs/sdk/electron.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
