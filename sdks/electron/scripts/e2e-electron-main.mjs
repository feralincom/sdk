// Gerçek Electron süreci: sandbox ve contextIsolation açık pencere, paketlenmiş preload, gerçek IPC, gerçek services/collect.
// scripts/sdk-e2e/targets/electron.mjs, FERALIN_E2E_ELECTRON_RUNTIME=1 iken bu dosyayı temiz kurulumda çalıştırır.
import { appendFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { BrowserWindow, app, ipcMain, protocol } from "electron";
import { createFeralinMain } from "@feralin/electron/main";

const here = dirname(fileURLToPath(import.meta.url));
const collectUrl = process.env.FERALIN_E2E_COLLECT_URL;
const projectKey = process.env.FERALIN_E2E_PROJECT_KEY;
const out = process.env.FERALIN_E2E_CHECKS;
const expect = (line) => appendFileSync(out, line + "\n");
// Windows'ta electron.exe çıktısı yönlendirilmiş akışa güvenilir düşmez; sonuç dosyaya da yazılır, hedef bunu okur.
const log = (line) => {
  appendFileSync(process.env.FERALIN_E2E_ELECTRON_LOG, line + "\n");
  console.log(line);
};

function fail(message) {
  log(`KALDI: ${message}`);
  app.exit(1);
}

setTimeout(() => fail("zaman aşımı"), 90_000).unref();

function assertEqual(actual, wanted, label) {
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(wanted)}`);
}

process.on("uncaughtException", (error) => fail(error.message));
process.on("unhandledRejection", (error) => fail(error instanceof Error ? error.message : String(error)));

// README'deki app:// protokolü gerçek pencerede denenir; şema uygulama hazır olmadan kaydedilmelidir.
protocol.registerSchemesAsPrivileged([{ scheme: "app", privileges: { standard: true, secure: true } }]);
// Köken senaryosu pencerelerini kapatınca uygulama varsayılan olarak çıkar; çıkış senaryo sonunda açıkça istenir.
app.on("window-all-closed", () => {});

/** Gerçek senderFrame.url değerleriyle köken denetimi: listedeki app://, listede olmayan file:// ve opak data:. */
async function originScenario() {
  protocol.handle("app", () => new Response('<!doctype html><html><head><meta charset="utf-8"><title>app</title></head><body></body></html>', { headers: { "content-type": "text/html; charset=utf-8" } }));
  const preload = join(here, "preload.bundle.cjs");
  const open = () => new BrowserWindow({ show: false, webPreferences: { preload, contextIsolation: true, sandbox: true, nodeIntegration: false } });
  const listed = createFeralinMain({ ipcMain, projectKey, collectUrl, flushIntervalMs: 0, consent: { analytics: true }, allowedOrigins: ["app://arayuz"] });

  const appWindow = open();
  await appWindow.loadURL("app://arayuz/index.html");
  assertEqual(await appWindow.webContents.executeJavaScript('window.feralin.track("origin_check")'), true, "listedeki app:// kökeni");
  const fileWindow = open();
  await fileWindow.loadFile(join(here, "index.html"));
  assertEqual(await fileWindow.webContents.executeJavaScript('window.feralin.track("origin_check")'), false, "listede olmayan file://");
  const dataWindow = open();
  await dataWindow.loadURL("data:text/html,<p>opak</p>");
  assertEqual(await dataWindow.webContents.executeJavaScript('window.feralin.track("origin_check")'), false, "listede opak köken");
  // İzin geri çekme gerçek pencereden işlenir, kuyruk silinir; bu olaylar gönderilmez.
  await appWindow.webContents.executeJavaScript("window.feralin.setConsent({ analytics: false })");
  assertEqual(listed.client.getStatus().optedOut, true, "izin geri çekme");
  assertEqual(listed.client.getStatus().queued, 0, "geri çekmede kuyruk");
  await listed.close();
  for (const win of [appWindow, fileWindow, dataWindow]) win.destroy();
  log("  OK koken-listesi-app-file-data");
}

// Üst düzey await kullanılmaz: ESM giriş dosyası yüklenmeden ready olayı gelmez, await kilitlenir.
async function scenario() {
  log("  uygulama hazır");
  await originScenario();

  const sent = [];
  const main = createFeralinMain({
    ipcMain,
    app,
    projectKey,
    collectUrl,
    flushIntervalMs: 0,
    fetch: async (url, init) => {
      const res = await fetch(url, init);
      sent.push({ events: JSON.parse(init.body).events, ack: await res.clone().json().catch(() => ({})) });
      return res;
    },
  });

  const win = new BrowserWindow({
    show: false,
    webPreferences: { preload: join(here, "preload.bundle.cjs"), contextIsolation: true, sandbox: true, nodeIntegration: false },
  });
  await win.loadFile(join(here, "index.html"));
  log("  pencere yüklendi");

  const page = (code) => win.webContents.executeJavaScript(code);

  // Web görünümünde Node ve ipcRenderer yok, yalnız köprü var
  assertEqual(await page("typeof require"), "undefined", "require");
  assertEqual(await page("typeof process"), "undefined", "process");
  assertEqual(await page("Object.keys(window.feralin).sort()"), ["captureError", "flush", "group", "identify", "page", "reset", "setConsent", "setUserProperties", "track", "trackRevenue"], "köprü");
  log("  OK context-isolation-sandbox");

  // İzin yok: olay üretilmez, istek yapılmaz
  assertEqual(await page('window.feralin.track("order_completed")'), false, "izinsiz track");
  assertEqual((await page("window.feralin.flush()")).status, 0, "izinsiz flush");
  assertEqual(sent.length, 0, "izinsiz istek");
  log("  OK izinsiz-sdk-uretmez");

  // Reklam izniyle fr_click gider
  await page('window.feralin.setConsent({ analytics: true, advertising: true })');
  assertEqual(await page('window.feralin.track("order_completed", { order_id: "ord_electron_real_1", fr_click: "clk_electron_real_1" })'), true, "izinli track");
  assertEqual((await page("window.feralin.flush()")).status, 202, "izinli flush");
  expect(`frclick ${sent.at(-1).ack.batch_id}`);
  expect(`once ${sent.at(-1).events[0].event_id}`);
  expect(`platform node:${sent.at(-1).events[0].event_id}`);
  log(`  OK 202-outbox-frclick: ${sent.at(-1).ack.batch_id}`);

  // Reklam izni yok: fr_click çıkarılır
  await page('window.feralin.setConsent({ analytics: true, advertising: false })');
  await page('window.feralin.track("order_completed", { order_id: "ord_electron_real_2", fr_click: "clk_electron_real_2" })');
  assertEqual((await page("window.feralin.flush()")).status, 202, "reklamsız flush");
  expect(`nofrclick ${sent.at(-1).ack.batch_id}`);
  log("  OK frclick-izinsiz-cikarildi");

  // Alt çerçeve IPC çağrısı reddedilir: iframe köprüye sahiptir, ana süreç kabul etmez
  const framed = await page(`new Promise((resolve) => {
    const frame = document.createElement("iframe");
    frame.srcdoc = "<p>alt</p>";
    frame.onload = () => resolve(frame.contentWindow.feralin ? frame.contentWindow.feralin.track("frame_event") : "kopru-yok");
    document.body.appendChild(frame);
  })`);
  if (framed !== false && framed !== "kopru-yok") throw new Error(`alt çerçeve kabul edildi: ${framed}`);
  log(`  OK alt-cerceve-reddedildi: ${framed}`);

  // Liste yok: yerel olmayan üst çerçeve reddedilir (file:// yukarıda kabul edildi)
  const foreign = new BrowserWindow({ show: false, webPreferences: { preload: join(here, "preload.bundle.cjs"), contextIsolation: true, sandbox: true, nodeIntegration: false } });
  await foreign.loadURL("data:text/html,<p>opak</p>");
  assertEqual(await foreign.webContents.executeJavaScript('window.feralin.track("foreign_event")'), false, "varsayılanda opak köken");
  foreign.destroy();
  log("  OK varsayilan-yerel-olmayan-reddedildi");

  // Kapanışta kuyruk gönderilir (will-quit bir kez ertelenir)
  const last = main.track("app_closed", { order_id: "ord_electron_real_3" });
  expect(`once ${last.event_id}`);
  app.once("quit", () => {
    if (sent.at(-1)?.events.at(-1)?.event_id !== last.event_id) return log("KALDI: kapanışta kuyruk gönderilmedi");
    log("  OK will-quit-gonderim");
    log("electron gerçek süreç: geçti");
  });
  win.destroy();
  app.quit();
}

app.whenReady().then(scenario).catch((error) => fail(error.message));
