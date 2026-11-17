// Core Web Vitals modülü birim testleri (UI-066): PerformanceObserver girdilerinden LCP, INP, CLS ve TTFB hesaplanır, her ölçüt
// sayfa yüklemesi başına bir kez gider, olay gövdesi toplayıcı sözleşmesine (fr_web_vital) uyar, desteklenmeyen girdi tahmin edilmez,
// izin kapısı çekirdek SDK'dadır ve gövdede parmak izine yarayacak alan yoktur.
import test from "node:test";
import assert from "node:assert/strict";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
execFileSync(process.execPath, [join(root, "scripts/build.mjs")], { stdio: "pipe" });
const toUrl = (p) => p.replace(/\\/g, "/").replace(/^([A-Za-z]):/, "file:///$1:");
const vitals = await import(toUrl(join(root, "dist/feralin-vitals.mjs")));
const sdk = await import(toUrl(join(root, "dist/feralin.mjs")));

function target() {
  const handlers = new Map();
  return {
    handlers,
    visibilityState: "visible",
    addEventListener(type, fn, opts) {
      handlers.set(type, [...(handlers.get(type) ?? []), { fn, once: typeof opts === "object" && opts?.once }]);
    },
    removeEventListener(type, fn) { handlers.set(type, (handlers.get(type) ?? []).filter((h) => h.fn !== fn)); },
    fire(type, event = {}) {
      for (const h of [...(handlers.get(type) ?? [])]) {
        h.fn(event);
        if (h.once) this.removeEventListener(type, h.fn);
      }
    },
  };
}

/** Sahte PerformanceObserver: `emit(type, entries)` girdileri o türe abone gözlemcilere iletir. */
function fakeObserver(supported = ["largest-contentful-paint", "layout-shift", "event", "first-input", "navigation"]) {
  const observers = [];
  class Observer {
    constructor(cb) { this.cb = cb; this.types = []; observers.push(this); }
    observe(init) { this.types.push(init.type); this.init = init; }
    disconnect() { this.types = []; }
  }
  Observer.supportedEntryTypes = supported;
  return {
    Observer,
    observers,
    emit(type, entries) {
      for (const o of observers) if (o.types.includes(type)) o.cb({ getEntries: () => entries });
    },
  };
}

function fakeClient() {
  const events = [];
  return { events, track(name, props) { events.push({ name, props }); return null; }, getStatus() { return { consent: { analytics: true } }; } };
}

function setup(opts = {}) {
  const win = target();
  const doc = target();
  const obs = fakeObserver(opts.supported);
  const client = fakeClient();
  const nav = opts.nav === null ? [] : [{ responseStart: 120, activationStart: 0, type: "navigate", ...(opts.nav ?? {}) }];
  const handle = vitals.captureVitals({ client, window: win, document: doc, performance: { getEntriesByType: (t) => (t === "navigation" ? nav : []) }, PerformanceObserver: obs.Observer, ...(opts.extra ?? {}) });
  const hide = () => { doc.visibilityState = "hidden"; doc.fire("visibilitychange"); };
  return { win, doc, obs, client, handle, hide, byName: (n) => client.events.filter((e) => e.props.metric === n) };
}

test("TTFB gezinme yanıtından hemen gider; LCP, CLS ve INP sayfa gizlenince bir kez gider", () => {
  const s = setup();
  assert.deepEqual(s.client.events.map((e) => e.props.metric), ["TTFB"]);
  assert.deepEqual(s.byName("TTFB")[0].props, { metric: "TTFB", value: 120, rating: "good", navigation_type: "navigate" });
  s.obs.emit("largest-contentful-paint", [{ entryType: "largest-contentful-paint", startTime: 1800, duration: 0 }]);
  s.obs.emit("largest-contentful-paint", [{ entryType: "largest-contentful-paint", startTime: 2700.4, duration: 0 }]);
  s.obs.emit("layout-shift", [{ entryType: "layout-shift", startTime: 100, duration: 0, value: 0.05, hadRecentInput: false }]);
  s.obs.emit("event", [{ entryType: "event", startTime: 3000, duration: 80, interactionId: 1 }, { entryType: "event", startTime: 3001, duration: 120, interactionId: 1 }]);
  s.obs.emit("event", [{ entryType: "event", startTime: 5000, duration: 260, interactionId: 2 }]);
  s.hide();
  s.hide();
  s.win.fire("pagehide");
  const metrics = s.client.events.map((e) => e.props.metric);
  assert.deepEqual(metrics.sort(), ["CLS", "INP", "LCP", "TTFB"]);
  assert.ok(s.client.events.every((e) => e.name === "fr_web_vital"));
  assert.deepEqual(s.byName("LCP")[0].props, { metric: "LCP", value: 2700, rating: "needs_improvement", navigation_type: "navigate" });
  assert.equal(s.byName("CLS")[0].props.value, 0.05);
  // Etkileşim başına en uzun süre: 1 → 120, 2 → 260; iki etkileşimde aykırı atlanmaz, INP 260.
  assert.equal(s.byName("INP")[0].props.value, 260);
  assert.equal(s.byName("INP")[0].props.rating, "needs_improvement");
});

test("LCP ilk kullanıcı girdisinde kesinleşir; sonradan gelen büyük öğe değeri değiştirmez", () => {
  const s = setup();
  s.obs.emit("largest-contentful-paint", [{ entryType: "largest-contentful-paint", startTime: 900, duration: 0 }]);
  s.win.fire("pointerdown");
  s.obs.emit("largest-contentful-paint", [{ entryType: "largest-contentful-paint", startTime: 7000, duration: 0 }]);
  s.hide();
  assert.equal(s.byName("LCP").length, 1);
  assert.equal(s.byName("LCP")[0].props.value, 900);
  assert.equal(s.byName("LCP")[0].props.rating, "good");
});

test("CLS: girdiye bağlı kayma sayılmaz, en büyük oturum penceresi alınır", () => {
  const s = setup();
  s.obs.emit("layout-shift", [
    { entryType: "layout-shift", startTime: 0, duration: 0, value: 0.1, hadRecentInput: false },
    { entryType: "layout-shift", startTime: 500, duration: 0, value: 0.1, hadRecentInput: false },
    { entryType: "layout-shift", startTime: 600, duration: 0, value: 5, hadRecentInput: true },
    // 1 sn'den uzun ara: yeni pencere (0,15 < 0,2).
    { entryType: "layout-shift", startTime: 3000, duration: 0, value: 0.15, hadRecentInput: false },
  ]);
  s.hide();
  assert.equal(s.byName("CLS")[0].props.value, 0.2);
  assert.equal(s.byName("CLS")[0].props.rating, "needs_improvement");
});

test("INP: her 50 etkileşimde en kötüsü aykırı sayılır; etkileşim yoksa INP gönderilmez", () => {
  assert.equal(vitals.inpFrom([500, 300, 200], 120), 200);
  assert.equal(vitals.inpFrom([500, 300, 200], 49), 500);
  assert.equal(vitals.inpFrom([], 0), null);
  const s = setup();
  s.obs.emit("event", [{ entryType: "event", startTime: 1, duration: 300, interactionId: 0 }]);
  s.hide();
  assert.equal(s.byName("INP").length, 0);
});

test("önceden işlenen sayfa: değerler etkinleşme anına göre düzeltilir ve navigation_type prerender", () => {
  const s = setup({ nav: { responseStart: 50, activationStart: 400 } });
  // Yanıt etkinleşmeden önce gelmişse TTFB 0.
  assert.deepEqual(s.byName("TTFB")[0].props, { metric: "TTFB", value: 0, rating: "good", navigation_type: "prerender" });
  s.obs.emit("largest-contentful-paint", [{ entryType: "largest-contentful-paint", startTime: 1400, duration: 0 }]);
  s.hide();
  assert.equal(s.byName("LCP")[0].props.value, 1000);
});

test("desteklenmeyen girdi türü tahmin edilmez; gizli açılan sayfada LCP ölçülmez; gözlemci yoksa hiçbir şey yapmaz", () => {
  const s = setup({ supported: ["largest-contentful-paint"] });
  s.obs.emit("largest-contentful-paint", [{ entryType: "largest-contentful-paint", startTime: 1000, duration: 0 }]);
  s.hide();
  assert.deepEqual(s.client.events.map((e) => e.props.metric).sort(), ["LCP", "TTFB"]);

  const win = target();
  const doc = target();
  doc.visibilityState = "hidden";
  const obs = fakeObserver();
  const client = fakeClient();
  vitals.captureVitals({ client, window: win, document: doc, performance: { getEntriesByType: () => [] }, PerformanceObserver: obs.Observer });
  assert.equal(obs.observers.some((o) => o.types.includes("largest-contentful-paint")), false);
  doc.fire("visibilitychange");
  assert.deepEqual(client.events.map((e) => e.props.metric), ["CLS"]);

  const none = fakeClient();
  const handle = vitals.captureVitals({ client: none, window: target(), document: target(), performance: { getEntriesByType: () => [] }, PerformanceObserver: undefined });
  handle.report();
  assert.equal(none.events.length, 0);
});

test("TTFB yanıt gelmeden başlatılırsa yükleme olayında gider; durdurulunca dinleyiciler kalkar", () => {
  const nav = [{ responseStart: 0, activationStart: 0, type: "reload" }];
  const win = target();
  const doc = target();
  const obs = fakeObserver();
  const client = fakeClient();
  const handle = vitals.captureVitals({ client, window: win, document: doc, performance: { getEntriesByType: () => nav }, PerformanceObserver: obs.Observer });
  assert.equal(client.events.length, 0);
  nav[0].responseStart = 2100;
  win.fire("load");
  assert.deepEqual(client.events[0].props, { metric: "TTFB", value: 2100, rating: "poor", navigation_type: "reload" });
  handle.stop();
  doc.visibilityState = "hidden";
  doc.fire("visibilitychange");
  assert.equal(client.events.length, 1);
  assert.ok(obs.observers.every((o) => o.types.length === 0));
});

test("örnekleme yüklemede bir kez karar verir; geçersiz ve sınır dışı değer gönderilmez", () => {
  const s = setup({ extra: { sampleRate: 0.1, random: () => 0.5 } });
  s.hide();
  assert.equal(s.client.events.length, 0);
  assert.equal(vitals.buildVitalProperties("LCP", -1), null);
  assert.equal(vitals.buildVitalProperties("LCP", Number.NaN), null);
  assert.equal(vitals.buildVitalProperties("LCP", 60_001), null);
  assert.equal(vitals.buildVitalProperties("CLS", 10.5), null);
  assert.equal(vitals.buildVitalProperties("FID", 10), null);
  assert.deepEqual(vitals.buildVitalProperties("CLS", 0.123456), { metric: "CLS", value: 0.1235, rating: "needs_improvement" });
});

test("olay gövdesi toplayıcı şemasına (fr_web_vital) uyar; şema bilinmeyen ölçütü ve fazla alanı reddeder", () => {
  const ajv = new Ajv2020({ strict: true, allErrors: true });
  addFormats(ajv);
  ajv.addSchema(JSON.parse(readFileSync(join(root, "../schemas/utp/v1/event.schema.json"), "utf8")));
  const validate = ajv.compile(JSON.parse(readFileSync(join(root, "../schemas/utp/v1/batch.schema.json"), "utf8")));
  const base = { event_id: "01JBX5Z8K3Q9R7T2V4W6Y8A0BC", event_name: "fr_web_vital", occurred_at: "2026-11-13T10:00:00Z", platform: "web", schema_version: 1, consent: { analytics: true } };
  for (const props of [vitals.buildVitalProperties("LCP", 2400, "navigate"), vitals.buildVitalProperties("CLS", 0.02), vitals.buildVitalProperties("INP", 180), vitals.buildVitalProperties("TTFB", 900, "back_forward")]) {
    assert.equal(validate({ events: [{ ...base, properties: props }] }), true, JSON.stringify(validate.errors));
  }
  assert.equal(validate({ events: [{ ...base, properties: { metric: "FID", value: 10 } }] }), false);
  assert.equal(validate({ events: [{ ...base, properties: { metric: "LCP", value: 10, selector: "#hero" } }] }), false);
  assert.equal(validate({ events: [{ ...base, properties: { metric: "LCP", value: 70_000 } }] }), false);
  assert.equal(validate({ events: [{ ...base }] }), false);
});

test("izin kapısı çekirdek SDK'dadır: analytics izni yokken ölçüt olayı üretilmez, izinle sayfa yoluyla kuyruğa girer", () => {
  const storage = new Map();
  const store = { getItem: (k) => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, v), removeItem: (k) => storage.delete(k) };
  const denied = sdk.initialize({ projectKey: "pk_test_vitals_1", collectUrl: "https://collect.example.test", consent: { analytics: false }, flushIntervalMs: 0, storage: store, fetch: async () => ({ status: 202, json: async () => ({}) }) });
  const s1 = vitals.captureVitals({ client: denied, window: target(), document: target(), performance: { getEntriesByType: () => [{ responseStart: 100, type: "navigate" }] }, PerformanceObserver: fakeObserver().Observer });
  s1.report();
  assert.equal(denied.getStatus().queued ?? 0, 0);
  denied.destroy();
  const granted = sdk.initialize({ projectKey: "pk_test_vitals_2", collectUrl: "https://collect.example.test", consent: { analytics: true }, flushIntervalMs: 0, storage: store, fetch: async () => ({ status: 202, json: async () => ({}) }) });
  const tracked = [];
  const spy = { track: (name, props) => { const e = granted.track(name, props); tracked.push(e); return e; }, getStatus: () => granted.getStatus() };
  vitals.captureVitals({ client: spy, window: target(), document: target(), performance: { getEntriesByType: () => [{ responseStart: 100, type: "navigate" }] }, PerformanceObserver: fakeObserver().Observer });
  assert.equal(tracked.length, 1);
  assert.equal(tracked[0].event_name, "fr_web_vital");
  // Gövde yalnız ölçüt alanlarını taşır: seçici, URL, ekran ya da cihaz özelliği yok.
  assert.deepEqual(Object.keys(tracked[0].properties).sort(), ["metric", "navigation_type", "rating", "value"]);
  granted.destroy();
});
