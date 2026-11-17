// Hata, oyun ve reklam geliri sözleşmeleri (X4): Android, Flutter ve Unity ile aynı alan adları ve sınırlar. Sahte yerel modül.
import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createFeralin } = require("../dist/core.js");
const signals = require("../dist/signals.js");

const CONFIG = { projectKey: "pk_test_rn_unit_0001", collectUrl: "https://collect.example.com", appVersion: "3.4.5" };

function fakeNative() {
  const calls = [];
  return {
    calls,
    initialize: async () => true,
    setConsent() {},
    optOut() {},
    track: async (name, properties) => {
      calls.push({ name, properties });
      return `01EV${calls.length}`;
    },
    screen: async () => null,
    identify() {},
    reset() {},
    flush: async () => ({}),
    getStatus: async () => ({}),
  };
}

async function ready() {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  await api.initialize(CONFIG);
  return { native, api };
}

test("fnv1a64 BigInt gerçeklemesiyle (Web SDK) aynı özeti üretir", () => {
  const reference = (text) => {
    let hash = 0xcbf29ce484222325n;
    for (let i = 0; i < text.length; i++) hash = BigInt.asUintN(64, (hash ^ BigInt(text.charCodeAt(i))) * 0x100000001b3n);
    return hash.toString(16).padStart(16, "0");
  };
  for (const text of ["", "a", "TypeError|fn@app.js|g@b.js", "ğüşiöç çok dilli ✓", "x".repeat(500)]) {
    assert.equal(signals.fnv1a64(text), reference(text), text);
  }
});

test("hata mesajındaki kişisel veri temizlenir ve 200 karaktere kırpılır", () => {
  const out = signals.scrubErrorMessage("Hata a.b@example.com https://x.test/y?t=1 1234567890 550e8400-e29b-41d4-a716-446655440000 abcdefghijklmnopqrstuvwx1 UnsupportedOperationException");
  assert.equal(out, "Hata [email] [url] [num] [id] [token] UnsupportedOperationException");
  assert.equal(signals.scrubErrorMessage("a".repeat(500)).length, 200);
});

test("yığın normalize edilir: satır, sütun, dizin gitmez; yerel çerçeve atılır; Hermes, V8 ve JSC biçimleri", () => {
  const hermes = "Error: x\n    at boom (address at index.android.bundle:1:23456)\n    at apply (native)\n    at run (http://10.0.2.2:8081/src/app.3f9a1b2c.js?platform=android:10:5)";
  assert.deepEqual(signals.normalizeFrames(hermes), ["boom@index.android.bundle", "run@app.js"]);
  assert.deepEqual(signals.normalizeFrames("go@file:///a/b/App.js:12:3\nglobal code@native"), ["go@App.js"]);
  assert.deepEqual(signals.normalizeFrames(undefined), []);
});

test("hata gövdesi sözleşme alanlarını taşır; ham yığın, yol ve satır gitmez", () => {
  const error = new TypeError("Kullanıcı a@b.co bulunamadı");
  error.stack = "TypeError: x\n    at Checkout (address at index.android.bundle:1:999)\n    at main (address at index.android.bundle:1:1)";
  const props = signals.errorProperties(error, "handled", false, "1.2.3");
  assert.deepEqual(Object.keys(props).sort(), ["app_version", "error_type", "fatal", "fingerprint", "frame_count", "handled", "message", "origin", "top_frame"]);
  assert.equal(props.error_type, "TypeError");
  assert.equal(props.message, "Kullanıcı [email] bulunamadı");
  assert.match(props.fingerprint, /^[0-9a-f]{16,64}$/);
  assert.equal(props.top_frame, "Checkout@index.android.bundle");
  assert.equal(props.frame_count, 2);
  assert.equal(props.handled, true);
  assert.equal(props.fatal, false);
  assert.equal(props.origin, "handled");
  assert.ok(!JSON.stringify(props).includes("999"));
  // Satır kaysa da parmak izi aynı kalır.
  error.stack = error.stack.replace("1:999", "1:5000");
  assert.equal(signals.errorProperties(error, "handled", false).fingerprint, props.fingerprint);
  // Uzun sürüm, string ve nesne olmayan hata.
  assert.equal("app_version" in signals.errorProperties(error, "handled", false, "x".repeat(33)), false);
  assert.equal(signals.errorProperties("düz metin", "uncaught_exception", true).error_type, "Error");
  assert.equal(signals.errorProperties(undefined, "handled", false).error_type, "Error");
});

test("captureError: fr_error olarak köprüye gider, sınır aşılınca olay üretilmez", async () => {
  const { native, api } = await ready();
  const error = new RangeError("kaçtı");
  error.stack = "RangeError\n    at f (address at b.bundle:1:1)";
  assert.equal(typeof (await api.captureError(error)), "string");
  assert.equal(native.calls[0].name, "fr_error");
  assert.equal(native.calls[0].properties.app_version, "3.4.5");
  await api.captureError(error);
  await api.captureError(error);
  assert.equal(await api.captureError(error), null, "aynı parmak izi için en çok 3");
  assert.equal(native.calls.length, 3);
});

test("captureError: SDK kapalıyken ve köprü hata verirken null döner, fırlatmaz", async () => {
  assert.equal(await createFeralin(undefined, "ios").captureError(new Error("x")), null);
  const native = { ...fakeNative(), track: async () => { throw new Error("köprü"); } };
  const api = createFeralin(native, "android");
  await api.initialize(CONFIG);
  assert.equal(await api.captureError(new Error("x")), null);
});

test("captureUncaughtErrors: genel işleyici sarılır, önceki işleyici çağrılmaya devam eder, ölümcül bayrağı taşınır", async () => {
  const { native, api } = await ready();
  let handler;
  const previousCalls = [];
  const errorUtils = {
    getGlobalHandler: () => (error, isFatal) => previousCalls.push([error, isFatal]),
    setGlobalHandler: (h) => { handler = h; },
  };
  assert.equal(api.captureUncaughtErrors({}, { errorUtils, dev: false }), true);
  assert.equal(api.captureUncaughtErrors({}, { errorUtils }), false, "ikinci çağrı yok sayılır");
  const boom = new Error("çöktü");
  handler(boom, true);
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(previousCalls, [[boom, true]]);
  assert.equal(native.calls[0].name, "fr_error");
  assert.equal(native.calls[0].properties.origin, "uncaught_exception");
  assert.equal(native.calls[0].properties.fatal, true);
  assert.equal(native.calls[0].properties.handled, false);
});

test("captureUncaughtErrors: Promise reddi yayında açık, geliştirmede kapalı, istenince açık; ErrorUtils yoksa false", async () => {
  const mk = () => ({ getGlobalHandler: () => undefined, setGlobalHandler() {} });
  let received;
  const trackRejections = (cb) => { received = cb; return true; };

  const release = (await ready()).api;
  release.captureUncaughtErrors({}, { errorUtils: mk(), trackRejections, dev: false });
  assert.equal(typeof received, "function");
  received = undefined;

  const dev = (await ready()).api;
  dev.captureUncaughtErrors({}, { errorUtils: mk(), trackRejections, dev: true });
  assert.equal(received, undefined);

  const forced = await ready();
  forced.api.captureUncaughtErrors({ promiseRejections: true }, { errorUtils: mk(), trackRejections, dev: true });
  received(new Error("reddedildi"));
  await new Promise((r) => setImmediate(r));
  assert.equal(forced.native.calls[0].properties.origin, "unhandledrejection");
  assert.equal(forced.native.calls[0].properties.fatal, false);

  assert.equal((await ready()).api.captureUncaughtErrors({}, { errorUtils: null }), false);
});

test("captureUncaughtErrors: örnekleme 0 ise olay üretilmez; önceki işleyici yine çalışır", async () => {
  const { native, api } = await ready();
  let handler;
  let called = 0;
  api.captureUncaughtErrors({ sampleRate: 0 }, { errorUtils: { getGlobalHandler: () => () => { called++; }, setGlobalHandler: (h) => { handler = h; } } });
  handler(new Error("x"), false);
  await new Promise((r) => setImmediate(r));
  assert.equal(called, 1);
  assert.equal(native.calls.length, 0);
});

test("oyun olayları Android, Flutter ve Unity ile aynı alan adlarını kullanır", async () => {
  const { native, api } = await ready();
  await api.trackLevelStart("1-3", { attempt: 2 });
  await api.trackLevelComplete("1-3", { attempt: 2, score: 900, durationMs: 41000 });
  await api.trackLevelFail("1-3", { failReason: "timeout", durationMs: 5 });
  await api.trackEconomySource("gold", 50, { reason: "quest", itemId: "q1" });
  await api.trackEconomySink("gold", 20);
  await api.trackRewardedAdShown("daily", { network: "admob" });
  await api.trackRewardedAdComplete("daily", { rewardAmount: 10, rewardCurrency: "gold" });
  await api.trackIapOfferShown("pack_s", { placement: "shop" });
  await api.trackIapInitiated("pack_s", { transactionId: "tx1" });
  assert.deepEqual(native.calls.map((c) => [c.name, c.properties]), [
    ["level_start", { level_id: "1-3", attempt: 2 }],
    ["level_complete", { level_id: "1-3", attempt: 2, score: 900, duration_ms: 41000 }],
    ["level_fail", { level_id: "1-3", duration_ms: 5, fail_reason: "timeout" }],
    ["economy_source", { currency_name: "gold", amount: 50, reason: "quest", item_id: "q1" }],
    ["economy_sink", { currency_name: "gold", amount: 20 }],
    ["rewarded_ad_shown", { placement: "daily", network: "admob" }],
    ["rewarded_ad_complete", { placement: "daily", reward_amount: 10, reward_currency: "gold" }],
    ["iap_offer_shown", { product_id: "pack_s", placement: "shop" }],
    ["iap_initiated", { product_id: "pack_s", transaction_id: "tx1" }],
  ]);
});

test("oyun olayı sözleşme dışı girdide null döner ve köprüye gitmez", async () => {
  const { native, api } = await ready();
  for (const result of [
    await api.trackLevelStart(""),
    await api.trackLevelStart("x".repeat(65)),
    await api.trackLevelStart("a", { attempt: 0 }),
    await api.trackLevelComplete("a", { durationMs: 86_400_001 }),
    await api.trackLevelComplete("a", { score: -1 }),
    await api.trackLevelFail("a", { failReason: "x".repeat(65) }),
    await api.trackEconomySource("gold", 0),
    await api.trackEconomySource("gold", 1.5),
    await api.trackEconomySink("gold", 1_000_000_000_001),
    await api.trackRewardedAdShown(""),
    await api.trackIapOfferShown("p".repeat(129)),
    await api.trackIapInitiated("p", { transactionId: "t".repeat(129) }),
  ]) assert.equal(result, null);
  assert.equal(native.calls.length, 0);
  const closed = createFeralin(undefined, "ios");
  assert.equal(await closed.trackLevelStart("a"), null);
  assert.equal(await closed.trackAdRevenue({ network: "admob", adFormat: "banner", revenueMicros: 1, currency: "USD" }), null);
});

test("trackAdRevenue: fr_ad_revenue, revenue_micros tam sayı, verified düşer, ayrı gelir sınıfı", async () => {
  const { native, api } = await ready();
  await api.trackAdRevenue({
    network: "admob", adFormat: "rewarded_interstitial", revenueMicros: 12500, currency: "USD", adUnit: "ca-app-pub-1/2",
    precision: "precise", placement: "level_end", impressionId: "imp-1",
    properties: { verified: true, receipt: "x", bolum: 3, receipt_provider: "google" },
  });
  assert.equal(native.calls[0].name, "fr_ad_revenue");
  assert.deepEqual(native.calls[0].properties, {
    bolum: 3, network: "admob", ad_format: "rewarded_interstitial", revenue_micros: 12500, currency: "USD",
    precision: "precise", ad_unit: "ca-app-pub-1/2", placement: "level_end", impression_id: "imp-1",
  });
  await api.trackAdRevenue({ network: "applovin_max", adFormat: "banner", revenueMicros: 0, currency: "EUR" });
  assert.equal(native.calls[1].properties.precision, "unknown");
  assert.equal(native.calls.some((c) => c.name === "feralin_purchase"), false);
});

test("trackAdRevenue sözleşme dışı girdide null döner", async () => {
  const { native, api } = await ready();
  const base = { network: "admob", adFormat: "banner", revenueMicros: 1, currency: "USD" };
  for (const bad of [
    { ...base, network: "AdMob" },
    { ...base, network: "" },
    { ...base, adFormat: "video" },
    { ...base, revenueMicros: 0.5 },
    { ...base, revenueMicros: -1 },
    { ...base, revenueMicros: Number.MAX_SAFE_INTEGER + 1 },
    { ...base, currency: "usd" },
    { ...base, precision: "kesin" },
    { ...base, adUnit: "" },
    { ...base, placement: "p".repeat(65) },
    { ...base, impressionId: "i".repeat(129) },
    null,
  ]) assert.equal(await api.trackAdRevenue(bad), null);
  assert.equal(native.calls.length, 0);
});
