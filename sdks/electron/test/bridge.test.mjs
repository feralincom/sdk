// Köprü mantığı Node'da: gerçek @feralin/node istemcisi, taklit IPC. Gerçek Electron süreci koşmaz.
import test from "node:test";
import assert from "node:assert/strict";
import { createFeralinMain, FERALIN_CHANNELS } from "../dist/esm/main.js";
import { exposeFeralin } from "../dist/esm/preload.js";
import { getFeralin, noopFeralinBridge } from "../dist/esm/renderer.js";
import { fakeElectron } from "./fake-electron.mjs";

const KEY = "pk_test_electron_unit_1";
const COLLECT = "http://collector.test";

function collector(status = 202) {
  const batches = [];
  const fetchImpl = async (url, init) => {
    batches.push({ url, headers: init.headers, events: JSON.parse(init.body).events });
    return new Response(JSON.stringify({ batch_id: "b1", accepted: 1, rejected: 0 }), { status });
  };
  return { batches, fetch: fetchImpl };
}

function setup(options = {}, electronOptions) {
  const electron = fakeElectron(electronOptions);
  const c = collector(options.status);
  const main = createFeralinMain({ ipcMain: electron.ipcMain, projectKey: KEY, collectUrl: COLLECT, flushIntervalMs: 0, fetch: c.fetch, ...options });
  exposeFeralin(electron);
  return { electron, c, main, bridge: electron.world.feralin };
}

test("köprü yalnız işlev açar; anahtar ve ipcRenderer web görünümüne geçmez", () => {
  const { bridge } = setup();
  assert.deepEqual(Object.keys(bridge).sort(), ["captureError", "flush", "group", "identify", "page", "reset", "setConsent", "setUserProperties", "track", "trackRevenue"]);
  assert.equal(JSON.stringify(Object.values(bridge).map(String)).includes(KEY), false);
});

test("izin yokken olay yok; izinle ana süreçten gönderilir; fr_click reklam iznine bağlı", async () => {
  const { bridge, c, main } = setup({ anonymousId: "kurulum_1" });
  assert.equal(await bridge.track("order_completed"), false);
  assert.equal((await bridge.flush()).status, 0);
  assert.equal(c.batches.length, 0);

  await bridge.setConsent({ analytics: true });
  assert.equal(await bridge.track("order_completed", { fr_click: "c1", order_id: "o1" }), true);
  await bridge.setConsent({ analytics: true, advertising: true });
  await bridge.identify("user_42");
  assert.equal(await bridge.track("order_completed", { fr_click: "c2" }), true);
  const result = await bridge.flush();
  assert.deepEqual(result, { status: 202, accepted: 1, rejected: 0, retained: 0 });
  const [first, second] = c.batches[0].events;
  assert.equal("fr_click" in first.properties, false);
  assert.equal(second.properties.fr_click, "c2");
  assert.equal(second.user_id, "user_42");
  assert.equal(first.anonymous_id, "kurulum_1");
  assert.equal(first.session_id, second.session_id);
  assert.equal(c.batches[0].headers["x-feralin-project-key"], KEY);
  assert.equal(JSON.stringify(c.batches[0].events).includes("verified"), false);

  await bridge.setConsent({ analytics: false });
  assert.equal(await bridge.track("order_completed"), false);
  await main.close();
});

test("web görünümünden bozuk girdi ana süreci düşürmez, fazlalık izin alanı geçmez", async () => {
  const { bridge, main } = setup();
  await bridge.setConsent({ analytics: true, verified: true, advertising: "evet" });
  assert.deepEqual(main.client.getStatus().consent, { analytics: true });
  assert.equal(await bridge.track(42), false);
  assert.equal(await bridge.track("Bad-Name"), false);
  assert.equal(await bridge.track("ok_event", [1, 2]), true);
  await bridge.setConsent(null);
  await bridge.identify({ a: 1 });
  assert.equal(main.client.getStatus().consent.analytics, true);
});

test("alt çerçeve ve izinsiz köken reddedilir", async () => {
  const sub = setup({ consent: { analytics: true } }, { senderFrame: { url: "app://arayuz/", parent: {} } });
  assert.equal(await sub.bridge.track("x_event"), false);
  assert.equal(sub.main.client.getStatus().queued, 0);

  const strict = setup({ consent: { analytics: true }, allowedOrigins: ["https://uygulama.example.com"] }, { senderFrame: { url: "https://kotu.example.com/", parent: null } });
  assert.equal(await strict.bridge.track("x_event"), false);
  assert.deepEqual(await strict.bridge.flush(), { status: 0, accepted: 0, rejected: 0, retained: 0 });
  strict.electron.frame.current = { url: "https://uygulama.example.com/a", parent: null };
  assert.equal(await strict.bridge.track("x_event"), true);
});

test("README'deki app:// kökeni eşleşir: izin geri çekme dahil çağrılar işlenir, başka host reddedilir", async () => {
  const { bridge, main, c, electron } = setup({ consent: { analytics: true }, allowedOrigins: ["app://arayuz"] });
  assert.equal(await bridge.track("order_completed"), true);
  await bridge.setConsent({ analytics: false });
  assert.equal(main.client.getStatus().optedOut, true);
  assert.equal(main.track("order_completed"), null, "izin geri çekilince ana süreç de olay üretmez");
  assert.equal((await bridge.flush()).status, 0);
  assert.equal(c.batches.length, 0);

  electron.frame.current = { url: "app://baska/index.html", parent: null };
  await bridge.setConsent({ analytics: true });
  assert.equal(main.client.getStatus().optedOut, true, "başka host izni değiştiremez");
  // Kurulumda sondaki eğik çizgi ve büyük harf aynı kökendir.
  const slash = setup({ consent: { analytics: true }, allowedOrigins: ["APP://Arayuz/"] });
  assert.equal(await slash.bridge.track("order_completed"), true);
});

test("opak köken listede de varsayılanda da eşleşmez", async () => {
  const opaque = ["data:text/html,<p>x</p>", "about:blank", "blob:https://uygulama.example.com/a", "app:/yol", "javascript:void(0)", "", "bozuk adres", undefined];
  for (const allowedOrigins of [undefined, ["app://arayuz", "file://", "https://uygulama.example.com"]]) {
    const { bridge, electron, main } = setup({ consent: { analytics: true }, allowedOrigins });
    for (const url of opaque) {
      electron.frame.current = { url, parent: null };
      assert.equal(await bridge.track("x_event"), false, `${url} kabul edildi`);
    }
    assert.equal(main.client.getStatus().queued, 0);
  }
});

test("geçersiz allowedOrigins kurulumda hata verir, istemci kurulmaz", () => {
  for (const entry of ["null", "NULL", " null ", "data:text/html,x", "about:blank", "app:", "bozuk", "", "https://uygulama.example.com/yol", "https://uygulama.example.com/?a=1", "https://kisi:parola@uygulama.example.com", 42]) {
    assert.throws(() => setup({ allowedOrigins: ["app://arayuz", entry] }), /allowedOrigins/, String(entry));
  }
  assert.throws(() => setup({ allowedOrigins: "app://arayuz" }), /allowedOrigins/);
  assert.doesNotThrow(() => setup({ allowedOrigins: [] }));
  assert.doesNotThrow(() => setup({ allowedOrigins: ["file://", "http://localhost:5173"] }));
});

test("liste yoksa yalnız yerel uygulama içeriği kabul edilir; dış site izin veremez, kimlik atayamaz", async () => {
  const { bridge, electron, main } = setup({ consent: { analytics: true } });
  for (const url of ["app://arayuz/index.html", "app://baska/index.html", "file:///C:/uygulama/index.html"]) {
    electron.frame.current = { url, parent: null };
    assert.equal(await bridge.track("x_event"), true, url);
  }
  const before = main.client.getStatus();
  for (const url of ["https://kotu.example.com/", "http://localhost:5173/", "file://sunucu/paylasim/index.html", "ozel://arayuz/"]) {
    electron.frame.current = { url, parent: null };
    assert.equal(await bridge.track("x_event"), false, url);
    await bridge.setConsent({ analytics: true, advertising: true });
    await bridge.identify("kotu_kullanici");
    await bridge.reset();
    assert.deepEqual(await bridge.flush(), { status: 0, accepted: 0, rejected: 0, retained: 0 });
  }
  const after = main.client.getStatus();
  assert.deepEqual(after.consent, before.consent);
  assert.equal(after.queued, before.queued);
  electron.frame.current = { url: "app://arayuz/index.html", parent: null };
  const event = main.track("x_event");
  assert.equal(event.user_id, undefined);

  // Liste yerel varsayılanı genişletmez, yerine geçer: boş liste hiçbir şeyi kabul etmez.
  const none = setup({ consent: { analytics: true }, allowedOrigins: [] });
  assert.equal(await none.bridge.track("x_event"), false);
  // Dış site ancak açıkça yazılırsa kabul edilir.
  const remote = setup({ consent: { analytics: true }, allowedOrigins: ["http://localhost:5173"] }, { senderFrame: { url: "http://localhost:5173/a?b=1", parent: null } });
  assert.equal(await remote.bridge.track("x_event"), true);
});

test("reddedilen çağrı debug düzeyinde görünür; anahtar, veri ve adres yolu yazılmaz", async () => {
  const logs = [];
  const logger = { debug: (message, fields) => logs.push({ message, fields }) };
  const { bridge, electron } = setup({ logger, consent: { analytics: true } }, { senderFrame: { url: "https://kotu.example.com/gizli/yol?token=GIZLI", parent: null } });
  await bridge.setConsent({ analytics: false, marker: "GIZLI_VERI" });
  await bridge.track("gizli_olay", { eposta: "GIZLI_VERI" });
  electron.frame.current = { url: "app://arayuz/index.html", parent: {} };
  await bridge.identify("GIZLI_VERI");
  const refused = logs.filter((entry) => /reddedildi/.test(entry.message));
  assert.equal(refused.length, 3);
  assert.deepEqual(refused.map((entry) => entry.fields.channel), [FERALIN_CHANNELS.setConsent, FERALIN_CHANNELS.track, FERALIN_CHANNELS.identify]);
  assert.deepEqual(refused.map((entry) => entry.fields.reason), ["origin", "origin", "frame"]);
  assert.equal(refused[0].fields.origin, "https://kotu.example.com");
  const raw = JSON.stringify(logs);
  for (const secret of ["GIZLI", KEY, "/gizli/yol", "gizli_olay"]) assert.equal(raw.includes(secret), false, secret);

  // Uygulamanın logger hatası çağrıyı reddetmekten öteye geçmez.
  const noisy = setup({ logger: { debug: () => { throw new Error("logger bozuk"); } } }, { senderFrame: { url: "https://kotu.example.com/", parent: null } });
  assert.equal(await noisy.bridge.track("x_event"), false);
});

test("401 kuyruğu atar ve IPC çağrısı düşmez; ağ hatası kuyrukta kalır, aynı anahtarla yeniden dener", async () => {
  const rejected = setup({ status: 401, consent: { analytics: true } });
  await rejected.bridge.track("order_completed");
  assert.deepEqual(await rejected.bridge.flush(), { status: 401, accepted: 0, rejected: 1, retained: 0 });

  const keys = [];
  let fail = true;
  const flaky = async (_url, init) => {
    keys.push(init.headers["idempotency-key"]);
    if (fail) {
      fail = false;
      throw new Error("ağ yok");
    }
    return new Response("{}", { status: 202 });
  };
  const retried = setup({ fetch: flaky, consent: { analytics: true } });
  await retried.bridge.track("order_completed");
  assert.equal((await retried.bridge.flush()).retained, 1);
  await retried.bridge.track("order_shipped");
  assert.equal((await retried.bridge.flush()).status, 202);
  assert.equal(keys[0], keys[1]);
});

test("app verilince sürüm ve dil eklenir; çıkış bir kez ertelenir, kuyruk gönderilir, işleyiciler kalkar", async () => {
  const electron = fakeElectron();
  const c = collector();
  const listeners = {};
  let quits = 0;
  const app = {
    getVersion: () => "1.2.3",
    getLocale: () => "tr",
    on: (name, listener) => {
      listeners[name] = listener;
    },
    quit: () => {
      quits++;
    },
  };
  const main = createFeralinMain({ ipcMain: electron.ipcMain, app, projectKey: KEY, collectUrl: COLLECT, flushIntervalMs: 0, fetch: c.fetch, consent: { analytics: true } });
  const event = main.track("app_started");
  assert.deepEqual(event.context, { locale: "tr", app: { version: "1.2.3" } });

  let prevented = 0;
  listeners["will-quit"]({ preventDefault: () => prevented++ });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(prevented, 1);
  assert.equal(quits, 1);
  assert.equal(c.batches[0].events.length, 1);
  assert.equal(electron.handlers.size, 0);
  listeners["will-quit"]({ preventDefault: () => prevented++ });
  assert.equal(prevented, 1);
  assert.deepEqual(Object.values(FERALIN_CHANNELS).length, 10);
});

test("renderer erişimi: köprü yoksa boş yüzey, varsa köprü", async () => {
  assert.equal(getFeralin(), noopFeralinBridge);
  assert.equal(await noopFeralinBridge.track("x"), false);
  const bridge = { track: async () => true };
  globalThis.window = { feralin: bridge };
  try {
    assert.equal(getFeralin(), bridge);
  } finally {
    delete globalThis.window;
  }
});

test("gizli anahtar açılışta reddedilir", () => {
  assert.throws(() => createFeralinMain({ ipcMain: fakeElectron().ipcMain, projectKey: "sk_live_gizli_0001", collectUrl: COLLECT }), /gizli anahtar/);
});
