# @feralin/electron

`@feralin/node` üstünde Electron köprüsü. Proje anahtarı ve ağ ana süreçte kalır; web görünümü `contextBridge` üzerinden dar bir yüzey görür ve IPC ile çağırır.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (Node, taklit IPC) | Geçiyor |
| Temiz kurulum + gerçek `services/collect` (taklit IPC) | `scripts/sdk-e2e/run.mjs electron` ile geçti |
| Gerçek Electron 45 penceresi (`sandbox` ve `contextIsolation` açık, paketlenmiş preload) | `FERALIN_E2E_ELECTRON_RUNTIME=1` ile geçti, yalnız Windows |
| macOS, Linux, imzalı paket, Forge veya Builder çıktısı | Sınanmadı |
| npm yayını | `BLOCKED_EXTERNAL`: `@feralin` organizasyonu yok |

Gerçek Electron akışı varsayılan koşuda atlanır, çünkü yaklaşık 100 MB indirir.

## Kurulum

```bash
cd sdks/node && npm pack
cd ../electron && npm pack
npm install ./feralin-node-0.1.0.tgz ./feralin-electron-0.1.0.tgz
```

## Kullanım

Ana süreç:

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

ESM ana dosyada `await app.whenReady()` üst düzeyde kullanılmaz: Electron 45'te bu çağrı kilitlendi, `then` kullanın.

Preload. `sandbox: true` preload npm paketi yükleyemez, bu dosya paketlenmelidir:

```ts
import { contextBridge, ipcRenderer } from "electron";
import { exposeFeralin } from "@feralin/electron/preload";

exposeFeralin({ contextBridge, ipcRenderer });
```

```bash
npx esbuild preload.ts --bundle --platform=node --format=cjs --external:electron --outfile=preload.bundle.cjs
```

Web görünümü:

```ts
import { getFeralin } from "@feralin/electron/renderer";

const feralin = getFeralin();
await feralin.setConsent({ analytics: true, advertising: false });
await feralin.track("project_opened");
```

## Gelir, kimlik, hata, kurulum kodu ve derin bağlantı

```ts
// Ana süreç
const gotLock = app.requestSingleInstanceLock(); // Windows ve Linux'ta ikinci örneğin adresi birinciye gelir
if (!gotLock) app.quit();
const feralin = createFeralinMain({
  ipcMain,
  app,
  projectKey: "pk_live_…",
  collectUrl: "https://collect.example.com",
  installCode: "7K3M-9QX2-PA", // panelin verdiği kurulum kodu; ilk olaya bir kez eklenir
  deepLinks: { schemes: ["myapp"] },
});
process.on("uncaughtException", (error) => feralin.captureError(error, { origin: "uncaught_exception", fatal: true }));
```

```ts
// Web görünümü
const feralin = getFeralin();
await feralin.trackRevenue({ transactionId: "ord_1", amountMinor: 4999, currency: "TRY" });
await feralin.group("acme_team", { plan: "team" });
await feralin.setUserProperties({ plan: "pro" });
window.addEventListener("error", (event) => void feralin.captureError(event.error, { origin: "window_onerror" }));
```

- `trackRevenue` `feralin_purchase` istemci beyanıdır, `verified` gönderilmez; geçersiz girdide `false`.
- `captureError`: preload Error nesnesini düz alanlara çevirir, ana süreç yığın izini `@feralin/node` kurallarıyla normalize eder (ham iz, dizin ve URL gitmez; saatte en çok 20 olay, aynı hata için 3). Web görünümü yalnız `handled`, `manual`, `window_onerror`, `unhandledrejection` bildirebilir.
- `deepLinks`: özel şemalar `app.setAsDefaultProtocolClient` ile kaydedilir (`registerProtocol: false` kapatır, `https` kaydedilmez). macOS `open-url`, Windows ve Linux `second-instance` ve açılış `process.argv` adresleri `deep_link_opened` olur. `fr_click` ve `utm_*` yalnız `advertising: true` iken olaya yazılır (`attribution_source: "app_link"`), aksi hâlde `none`; analitik izni yokken adres sayılmaz. Ham adres ve sorgu gönderilmez. `requestSingleInstanceLock` uygulamanındır; çağrılmazsa ikinci örnek ayrı süreç olarak açılır. Gerçek işletim sistemi kaydı ve macOS sınanmadı (taklit `app` ile birim testli).

## İzin

Varsayılan `analytics=false`. İzin web görünümünden `setConsent` ile gelir, yalnız bilinen boolean alanlar geçer. SDK izni diske yazmaz: uygulama saklar, açılışta `consent` seçeneğiyle verir. `fr_click` yalnız `advertising === true` iken gider. `sk_` anahtar reddedilir.

## Güvenlik

Alt çerçeveden gelen çağrı reddedilir. Üst çerçeve için köken şöyle denetlenir:

| `allowedOrigins` | Kabul edilen |
|---|---|
| Verilmedi | Yalnız yerel uygulama içeriği: `app://` ve yerel `file://`. Uzak sayfalar, `http://localhost` ve başka özel şemalar reddedilir: dış siteye giden pencere izin veremez, kimlik atayamaz |
| `["app://arayuz"]` | Yalnız listedeki şema ve host. Liste varsayılanı genişletmez, yerine geçer; `[]` hiçbir çağrıyı kabul etmez |

- Karşılaştırma şema ve host iledir, yol önemsizdir. Yerel dosya için `"file://"`, geliştirme sunucusu için `"http://localhost:5173"` yazın.
- `data:`, `about:blank`, `blob:` gibi opak adresler hiçbir zaman eşleşmez. Listeye `"null"`, yol içeren veya çözümlenemeyen değer yazılırsa `createFeralinMain` kurulumda hata verir.
- Reddedilen çağrı `logger.debug` ile görünür: kanal, neden (`frame` veya `origin`) ve köken. Anahtar, çağrı verisi ve adres yolu yazılmaz. `logger` verilmezse red sessizdir; izin geri çekme çağrısı da reddedilebileceğinden kurulumda `logger` verip köprüyü denemeniz önerilir.

`file://` varsayılanda kabul edildiği için uygulamanız güvenilmeyen yerel dosyayı pencereye yüklüyorsa `allowedOrigins` ile özel protokole sınırlayın. Web görünümünden gelen girdi ana süreci düşürmez. Web görünümü proje anahtarını ve `ipcRenderer` nesnesini görmez.

## Desteklenmeyenler

- Olaylarda `platform` değeri `node`tur; UTP şemasında masaüstü değeri yoktur.
- Kuyruk ana süreç belleğindedir: kalıcı ve şifreli değildir, süreç öldürülürse kaybolur.
- Anonim kurulum kimliği üretilmez, uygulama `anonymousId` ile verir. Oturum kimliği süreç başına üretilir.
- Köprü olay kimliği döndürmez, `track` yalnız `true` veya `false` döner.
- Otomatik `page_view` ve replay yoktur. Web görünümü hataları otomatik dinlenmez; `captureError` uygulamadan çağrılır.
