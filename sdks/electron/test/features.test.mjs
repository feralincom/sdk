// Gelir, kimlik, hata, kurulum kodu ve derin bağlantı köprüsü: gerçek @feralin/node istemcisi, taklit IPC ve app. Gerçek Electron koşmaz.
import test from "node:test";
import assert from "node:assert/strict";
import { createFeralinMain, FERALIN_CHANNELS, parseDeepLink } from "../dist/esm/main.js";
import { exposeFeralin } from "../dist/esm/preload.js";
import { noopFeralinBridge } from "../dist/esm/renderer.js";
import { fakeApp, fakeElectron } from "./fake-electron.mjs";

const KEY = "pk_test_electron_unit_2";
const COLLECT = "http://collector.test";

function setup(options = {}, electronOptions) {
  const electron = fakeElectron(electronOptions);
  const batches = [];
  const fetchImpl = async (_url, init) => {
    batches.push(JSON.parse(init.body).events);
    return new Response("{}", { status: 202 });
  };
  const main = createFeralinMain({ ipcMain: electron.ipcMain, projectKey: KEY, collectUrl: COLLECT, flushIntervalMs: 0, fetch: fetchImpl, consent: { analytics: true }, deepLinks: undefined, ...options });
  exposeFeralin(electron);
  return { electron, batches, main, bridge: electron.world.feralin };
}

async function sentEvents(ctx) {
  await ctx.bridge.flush();
  return ctx.batches.flat();
}

test("köprü yeni kanalları açar; boş yüzey de aynı yöntemleri taşır", async () => {
  const { bridge } = setup();
  assert.deepEqual(Object.keys(bridge).sort(), ["captureError", "flush", "group", "identify", "page", "reset", "setConsent", "setUserProperties", "track", "trackRevenue"]);
  assert.equal(Object.values(FERALIN_CHANNELS).length, 10);
  for (const name of ["trackRevenue", "group", "setUserProperties", "captureError"]) assert.equal(await noopFeralinBridge[name]({}), false);
});

test("trackRevenue: sözleşme ana süreçte doğrulanır, verified ve bilinmeyen alan geçmez", async () => {
  const ctx = setup();
  assert.equal(await ctx.bridge.trackRevenue({ transactionId: "tx_1", amountMinor: 4999, currency: "TRY", productId: "pro", verified: true, properties: { verified: true, plan: "pro" } }), true);
  for (const bad of [null, "tx", [], { transactionId: "tx_2", amountMinor: 49.99, currency: "TRY" }, { transactionId: "tx_3", amountMinor: "100", currency: "TRY" }, { transactionId: "tx_4", amountMinor: 1, currency: "TRY", purchaseType: "bedava" }, { transactionId: "tx_5", amountMinor: 1, currency: "TRY", receipt: "x" }, { transactionId: "tx_6", amountMinor: 5, currency: "TRY", purchaseType: "subscription_cancel" }]) {
    assert.equal(await ctx.bridge.trackRevenue(bad), false, JSON.stringify(bad));
  }
  const [event] = await sentEvents(ctx);
  assert.equal(event.event_name, "feralin_purchase");
  assert.deepEqual(event.properties, { plan: "pro", transaction_id: "tx_1", amount_minor: 4999, currency: "TRY", quantity: 1, purchase_type: "purchase", product_id: "pro" });
});

test("group ve setUserProperties: geçerli girdi olay üretir, bozuk girdi false döner", async () => {
  const ctx = setup();
  assert.equal(await ctx.bridge.group("acme_42", { plan: "growth" }), true);
  assert.equal(await ctx.bridge.group("ali@example.com"), false);
  assert.equal(await ctx.bridge.group(42), false);
  assert.equal(await ctx.bridge.setUserProperties({ plan: "pro", email: "ali@example.com" }), true);
  assert.equal(await ctx.bridge.setUserProperties({ email: "ali@example.com" }), false);
  assert.equal(await ctx.bridge.setUserProperties("plan"), false);
  const events = await sentEvents(ctx);
  assert.deepEqual(events.map((e) => e.event_name), ["fr_group", "fr_user_properties"]);
  assert.deepEqual(events[0].properties, { plan: "growth", group_id: "acme_42" });
  assert.deepEqual(events[1].properties, { plan: "pro" });
});

test("captureError: Error düz alanlara çevrilir; ham yığın izi ve yol gitmez; renderer fatal ve uncaught bildiremez", async () => {
  const ctx = setup();
  const error = new TypeError("kart 4111 1111 1111 1111 reddedildi");
  error.stack = "TypeError: x\n    at pay (app://arayuz/assets/checkout.3f9a1b2c.js:12:7)\n    at click (app://arayuz/assets/ui.js:3:1)";
  assert.equal(await ctx.bridge.captureError(error), true);
  assert.equal(await ctx.bridge.captureError("dize hata", { origin: "uncaught_exception" }), true);
  assert.equal(await ctx.bridge.captureError({ name: "X".repeat(500), message: 5, stack: "y".repeat(100_000) }, { origin: "window_onerror" }), true);
  // Preload her değeri düz özete çevirir; doğrudan IPC'ye gelen bozuk gövde ana süreçte reddedilir.
  assert.equal(await ctx.electron.ipcRenderer.invoke(FERALIN_CHANNELS.captureError, [1, 2]), false);
  assert.equal(await ctx.electron.ipcRenderer.invoke(FERALIN_CHANNELS.captureError, null), false);
  const events = await sentEvents(ctx);
  assert.deepEqual(events.map((e) => e.event_name), ["fr_error", "fr_error", "fr_error"]);
  assert.deepEqual(events[0].properties, {
    error_type: "TypeError",
    fingerprint: events[0].properties.fingerprint,
    frame_count: 2,
    handled: true,
    fatal: false,
    origin: "handled",
    message: "kart [num] reddedildi",
    top_frame: "pay@checkout.js",
    frames: [
      { file: "checkout.3f9a1b2c.js", line: 12, column: 7, function: "pay" },
      { file: "ui.js", line: 3, column: 1, function: "click" },
    ],
  });
  assert.match(events[0].properties.fingerprint, /^[0-9a-f]{16}$/);
  assert.equal(events[1].properties.origin, "handled");
  assert.equal(events[1].properties.fatal, false);
  assert.equal(events[2].properties.origin, "window_onerror");
  assert.equal(events[2].properties.error_type.length, 64);
  assert.equal(JSON.stringify(events).includes("app://arayuz/assets"), false);
});

test("captureError ana süreçte: uncaught ve fatal yalnız buradan; sürüm app'ten gelir", async () => {
  const { app } = fakeApp({ version: "4.5.6" });
  const ctx = setup({ app });
  const event = ctx.main.captureError(new RangeError("çöktü"), { origin: "uncaught_exception", fatal: true });
  assert.equal(event.properties.fatal, true);
  assert.equal(event.properties.origin, "uncaught_exception");
  assert.equal(event.properties.app_version, "4.5.6");
});

test("captureError izin yokken olay üretmez; reddedilen köken false alır", async () => {
  const ctx = setup({ consent: { analytics: false } });
  assert.equal(await ctx.bridge.captureError(new Error("x")), false);
  const remote = setup({}, { senderFrame: { url: "https://kotu.example.com/", parent: null } });
  for (const call of [() => remote.bridge.captureError(new Error("x")), () => remote.bridge.trackRevenue({ transactionId: "t", amountMinor: 1, currency: "TRY" }), () => remote.bridge.group("g1"), () => remote.bridge.setUserProperties({ a: 1 })]) {
    assert.equal(await call(), false);
  }
  assert.equal(remote.main.client.getStatus().queued, 0);
});

test("installCode: ilk olaya bir kez eklenir, geçersiz kod yok sayılır", async () => {
  const ctx = setup({ installCode: "7K3M-9QX2-PA" });
  await ctx.bridge.track("app_opened");
  await ctx.bridge.track("app_opened");
  const events = await sentEvents(ctx);
  assert.equal(events[0].properties.fr_install_code, "7K3M-9QX2-PA");
  assert.equal(events[1].properties?.fr_install_code, undefined);
  const bad = setup({ installCode: "OOPS" });
  assert.equal(bad.main.track("app_opened").properties, undefined);
});

test("deepLinks: şema kaydı, açılış argv, second-instance ve open-url deep_link_opened üretir; kanıt reklam iznine bağlı", async () => {
  const { app, protocols } = fakeApp();
  const ctx = setup({ app, deepLinks: { schemes: ["myapp", "https"], argv: ["C:\\app\\app.exe", "--flag", "myapp://open/start?fr_click=clk_0&utm_source=mail&email=ali%40example.com"] } });
  assert.deepEqual(protocols, ["myapp"]);
  app.emit("second-instance", {}, ["app.exe", "C:\\belge.txt", "myapp://open/product/42?fr_click=clk_1"]);
  ctx.main.client.setConsent({ analytics: true, advertising: true });
  let prevented = 0;
  app.emit("open-url", { preventDefault: () => prevented++ }, "myapp://open/promo?fr_click=clk_2&utm_campaign=kis&diger=x");
  app.emit("open-url", { preventDefault: () => prevented++ }, "baska://x?fr_click=x");
  assert.equal(prevented, 2);
  assert.equal(ctx.main.handleDeepLink("https://uygulama.example.com/a?utm_medium=cpc").properties.attribution_source, "app_link");
  const events = await sentEvents(ctx);
  assert.deepEqual(events.map((e) => e.event_name), ["deep_link_opened", "deep_link_opened", "deep_link_opened", "deep_link_opened"]);
  assert.deepEqual(events[0].properties, { attribution_source: "none" });
  assert.deepEqual(events[1].properties, { attribution_source: "none" });
  assert.deepEqual(events[2].properties, { attribution_source: "app_link", fr_click: "clk_2", utm_campaign: "kis" });
  assert.deepEqual(events[3].properties, { attribution_source: "app_link", utm_medium: "cpc" });
  assert.equal(JSON.stringify(events).includes("example.com"), false);
  assert.equal(JSON.stringify(events).includes("diger"), false);
});

test("deepLinks: kayıt kapatılabilir; verilmezse handleDeepLink null; geçersiz şema kurulumda hata", () => {
  const { app, protocols, listeners } = fakeApp();
  setup({ app, deepLinks: { schemes: ["myapp"], registerProtocol: false, argv: [] } });
  assert.deepEqual(protocols, []);
  assert.equal(listeners["open-url"].length, 1);
  const plain = setup({ app: fakeApp().app });
  assert.equal(plain.main.handleDeepLink("myapp://x"), null);
  assert.throws(() => setup({ deepLinks: { schemes: ["my app"] } }), /şema/);
  assert.throws(() => setup({ deepLinks: { schemes: [] } }), /şema/);
  assert.equal(parseDeepLink("myapp://open?fr_click=%E0%A4%A", new Set(["myapp"])).params.frClick, undefined);
});
