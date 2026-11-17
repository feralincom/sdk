// JS yüzeyi birim testleri: sahte yerel modül. Android çekirdeğinin davranışı sdks/android, gerçek köprü emülatör testinde sınanır.
import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createFeralin, SDK_NAME, SDK_VERSION } = require("../dist/core.js");

const KEY = "pk_test_rn_unit_0001";
const CONFIG = { projectKey: KEY, collectUrl: "https://collect.example.com" };

function fakeNative(overrides = {}) {
  const calls = [];
  const record = (name, value) => (...args) => {
    calls.push([name, ...args]);
    return value;
  };
  return {
    calls,
    initialize: async (config) => {
      calls.push(["initialize", config]);
      return true;
    },
    setConsent: record("setConsent"),
    optOut: record("optOut"),
    track: async (...args) => {
      calls.push(["track", ...args]);
      return "01EVENT";
    },
    screen: async (...args) => {
      calls.push(["screen", ...args]);
      return "01SCREEN";
    },
    identify: record("identify"),
    reset: record("reset"),
    flush: async () => ({ sent: 1, accepted: 1, rejected: 0, status: 202, batchId: "b1" }),
    getStatus: async () => ({ initialized: true, sdk: SDK_NAME, version: SDK_VERSION, queued: 2, consent: { analytics: true }, anonymousId: "a", sessionId: "s", userId: null }),
    ...overrides,
  };
}

test("yerel modül yoksa (iOS) düşmez, kapalı kalır ve nedeni bildirir", async () => {
  const api = createFeralin(undefined, "ios");
  assert.equal(await api.initialize(CONFIG), false);
  assert.equal(await api.track("a"), null);
  assert.equal(await api.screen("home"), null);
  api.setConsent({ analytics: true });
  api.identify("u");
  api.reset();
  api.optOut();
  assert.deepEqual(await api.flush(), { sent: 0, accepted: 0, rejected: 0, status: 0, batchId: null });
  const status = await api.getStatus();
  assert.equal(status.initialized, false);
  assert.match(status.unavailable, /ios/);
});

test("sk_ anahtar ve geçersiz adres yerel katmana ulaşmaz", async () => {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  assert.equal(await api.initialize({ projectKey: "sk_live_12345678", collectUrl: CONFIG.collectUrl }), false);
  assert.equal(await api.initialize({ projectKey: KEY, collectUrl: "ftp://x" }), false);
  assert.equal(await api.initialize({ projectKey: "", collectUrl: CONFIG.collectUrl }), false);
  assert.equal(native.calls.length, 0);
  assert.equal(await api.track("a"), null);
});

test("başlatma yapılandırması: sarmalayıcı kimliği gider, izin verilmemişse alan yoktur", async () => {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  assert.equal(await api.initialize({ ...CONFIG, batchSize: 10, debug: true, bilinmeyen: "x" }), true);
  const [, payload] = native.calls[0];
  assert.deepEqual(payload, { projectKey: KEY, collectUrl: CONFIG.collectUrl, wrapperName: SDK_NAME, wrapperVersion: SDK_VERSION, batchSize: 10, debug: true });
});

test("izin başlatmada ve sonradan yalnız şema alanlarıyla iletilir; analytics yalnız true ise true", async () => {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  await api.initialize({ ...CONFIG, consent: { analytics: true, advertising: false, bilinmeyen: 1 } });
  assert.deepEqual(native.calls[0][1].consent, { analytics: true, advertising: false });
  api.setConsent({ analytics: "evet", advertising: true });
  assert.deepEqual(native.calls[1], ["setConsent", { analytics: false, advertising: true }]);
});

test("başlatılmadan çağrılar yerel katmana gitmez", async () => {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  assert.equal(await api.track("a"), null);
  api.setConsent({ analytics: true });
  assert.equal(native.calls.length, 0);
});

test("track: geçersiz ad elenir, geçersiz özellik anahtarı ve köprünün taşıyamadığı değerler atılır", async () => {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  await api.initialize(CONFIG);
  assert.equal(await api.track("Geçersiz Ad"), null);
  assert.equal(await api.track("x".repeat(101)), null);
  assert.equal(await api.track("a", { ok: 1, "bad key": 2, undef: undefined, fn() {}, nan: Number.NaN, nested: { keep: "v", drop: undefined }, list: [1, undefined, "x"], at: new Date(0) }), "01EVENT");
  assert.deepEqual(native.calls.at(-1), ["track", "a", { ok: 1, nested: { keep: "v" }, list: [1, "x"], at: "1970-01-01T00:00:00.000Z" }]);
  await api.track("b");
  assert.deepEqual(native.calls.at(-1), ["track", "b", null]);
  await api.screen("home", { a: 1 });
  assert.deepEqual(native.calls.at(-1), ["screen", "home", { a: 1 }]);
});

test("yerel hata uygulamaya geçmez: reddedilen Promise yok, eşzamanlı hata yok", async () => {
  const boom = () => { throw new Error(`patladı ${KEY}`); };
  const native = fakeNative({ track: async () => { throw new Error("x"); }, screen: boom, flush: boom, getStatus: boom, setConsent: boom, identify: boom, reset: boom, optOut: boom });
  const api = createFeralin(native, "android");
  await api.initialize(CONFIG);
  assert.equal(await api.track("a"), null);
  assert.equal(await api.screen("home"), null);
  assert.equal((await api.flush()).status, 0);
  assert.equal((await api.getStatus()).initialized, false);
  api.setConsent({ analytics: true });
  api.identify("u");
  api.reset();
  api.optOut();
});

test("yerel başlatma reddedilirse SDK kapalı kalır", async () => {
  const api = createFeralin(fakeNative({ initialize: async () => { throw new Error("x"); } }), "android");
  assert.equal(await api.initialize(CONFIG), false);
  assert.match((await api.getStatus()).unavailable, /başlatma/);
  assert.equal(await api.track("a"), null);
});

test("flush ve getStatus yerel sonucu tipli döndürür, anahtar yoktur", async () => {
  const api = createFeralin(fakeNative(), "android");
  await api.initialize(CONFIG);
  assert.deepEqual(await api.flush(), { sent: 1, accepted: 1, rejected: 0, status: 202, batchId: "b1" });
  const status = await api.getStatus();
  assert.equal(status.queued, 2);
  assert.ok(!JSON.stringify(status).includes(KEY));
});

test("ertelenmiş derin bağlantı: Android köprüden gelir, iOS dürüstçe not_supported döner", async () => {
  const ios = createFeralin(undefined, "ios");
  assert.deepEqual(await ios.consumeDeferredDeepLink(), { status: "not_supported", path: null });

  const native = fakeNative({ consumeDeferredDeepLink: async () => ({ status: "delivered", path: "/urun/42" }) });
  const api = createFeralin(native, "android");
  // Android'de başlatılmadan önce "desteklenmiyor" denmez.
  assert.deepEqual(await api.consumeDeferredDeepLink(), { status: "not_initialized", path: null });
  await api.initialize({ projectKey: "pk_test_x", collectUrl: "https://collect.example.com" });
  assert.deepEqual(await api.consumeDeferredDeepLink(), { status: "delivered", path: "/urun/42" });

  const failing = fakeNative({ consumeDeferredDeepLink: async () => { throw new Error("köprü"); } });
  const quiet = createFeralin(failing, "android");
  await quiet.initialize({ projectKey: "pk_test_x", collectUrl: "https://collect.example.com" });
  assert.deepEqual(await quiet.consumeDeferredDeepLink(), { status: "not_initialized", path: null });
});

const lastTrack = (native) => native.calls.filter((c) => c[0] === "track").at(-1);

test("trackRevenue: sözleşme alanları kurulur, verified ve makbuz türevleri düşer (Android/Flutter ile aynı)", async () => {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  await api.initialize(CONFIG);
  const id = await api.trackRevenue({
    transactionId: "ord_1",
    amountMinor: 4999,
    currency: "TRY",
    productId: "pro",
    purchaseType: "subscription_start",
    receipt: { provider: "stripe", token: "tok_1" },
    properties: { verified: true, receipt_digest: "x", verification: "y", plan: "pro", "bad key": 1 },
  });
  assert.equal(id, "01EVENT");
  const [, name, props] = lastTrack(native);
  assert.equal(name, "feralin_purchase");
  assert.deepEqual(props, {
    plan: "pro",
    transaction_id: "ord_1",
    amount_minor: 4999,
    currency: "TRY",
    quantity: 1,
    purchase_type: "subscription_start",
    product_id: "pro",
    receipt: { provider: "stripe", token: "tok_1" },
  });
  assert.ok(!("verified" in props) && !("receipt_digest" in props) && !("verification" in props));
});

test("trackRevenue: istemci receipt alanını özellikle taklit edemez, varsayılanlar purchase ve adet 1", async () => {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  await api.initialize(CONFIG);
  await api.trackRevenue({ transactionId: "t", amountMinor: 0, currency: "USD", properties: { receipt: { provider: "apple", token: "x" } } });
  const [, , props] = lastTrack(native);
  assert.ok(!("receipt" in props));
  assert.equal(props.purchase_type, "purchase");
  assert.equal(props.quantity, 1);
});

test("trackRevenue: sözleşme dışı girdi olay üretmez", async () => {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  await api.initialize(CONFIG);
  const ok = { transactionId: "t", amountMinor: 1, currency: "TRY" };
  const bad = [
    { ...ok, transactionId: "" },
    { ...ok, transactionId: "x".repeat(129) },
    { ...ok, amountMinor: -1 },
    { ...ok, amountMinor: 1.5 },
    { ...ok, amountMinor: Number.MAX_SAFE_INTEGER + 1 },
    { ...ok, amountMinor: "1" },
    { ...ok, currency: "try" },
    { ...ok, currency: "TRYY" },
    { ...ok, quantity: -1 },
    { ...ok, quantity: 100_001 },
    { ...ok, productId: "" },
    { ...ok, purchaseType: "refund" },
    { ...ok, purchaseType: "subscription_cancel" },
    { ...ok, receipt: { provider: "apple", token: "" } },
    { ...ok, receipt: { provider: "apple", token: "x".repeat(8193) } },
    { ...ok, receipt: { provider: "paypal", token: "x" } },
    null,
  ];
  for (const input of bad) assert.equal(await api.trackRevenue(input), null, JSON.stringify(input));
  assert.equal(native.calls.filter((c) => c[0] === "track").length, 0);
  // Abonelik iptali 0 tutarla geçerlidir.
  assert.equal(await api.trackRevenue({ ...ok, amountMinor: 0, purchaseType: "subscription_cancel" }), "01EVENT");
  assert.equal(await api.trackRevenue({ ...ok, amountMinor: Number.MAX_SAFE_INTEGER }), "01EVENT");
});

test("group: fr_group olayı group_id ile gider, geçersiz kimlik elenir, trait group_id'yi ezemez", async () => {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  await api.initialize(CONFIG);
  assert.equal(await api.group(""), null);
  assert.equal(await api.group("g".repeat(129)), null);
  assert.equal(native.calls.filter((c) => c[0] === "track").length, 0);
  assert.equal(await api.group("acme", { plan: "pro", seats: 5, group_id: "baska", "bad key": 1 }), "01EVENT");
  assert.deepEqual(lastTrack(native), ["track", "fr_group", { plan: "pro", seats: 5, group_id: "acme" }]);
  await api.group("solo");
  assert.deepEqual(lastTrack(native), ["track", "fr_group", { group_id: "solo" }]);
});

test("setUserProperties: fr_user_properties olayı, geçerli özellik yoksa olay yok", async () => {
  const native = fakeNative();
  const api = createFeralin(native, "android");
  await api.initialize(CONFIG);
  assert.equal(await api.setUserProperties({}), null);
  assert.equal(await api.setUserProperties({ "bad key": 1, undef: undefined }), null);
  assert.equal(await api.setUserProperties(undefined), null);
  assert.equal(native.calls.filter((c) => c[0] === "track").length, 0);
  assert.equal(await api.setUserProperties({ tier: "gold", beta: true, "bad key": 1 }), "01EVENT");
  assert.deepEqual(lastTrack(native), ["track", "fr_user_properties", { tier: "gold", beta: true }]);
});

test("yeni yöntemler başlatılmadan ve köprü hatasında düşmez, yerel katmana gitmez", async () => {
  const native = fakeNative({ track: async () => { throw new Error("x"); } });
  const api = createFeralin(native, "android");
  const input = { transactionId: "t", amountMinor: 1, currency: "TRY" };
  assert.equal(await api.trackRevenue(input), null);
  assert.equal(await api.group("g"), null);
  assert.equal(await api.setUserProperties({ a: 1 }), null);
  assert.equal(native.calls.length, 0);
  await api.initialize(CONFIG);
  assert.equal(await api.trackRevenue(input), null);
  assert.equal(await api.group("g"), null);
  assert.equal(await api.setUserProperties({ a: 1 }), null);
  const ios = createFeralin(undefined, "ios");
  assert.equal(await ios.trackRevenue(input), null);
  assert.equal(await ios.group("g"), null);
  assert.equal(await ios.setUserProperties({ a: 1 }), null);
});

test("bindInstall: modül yoksa ve Android'de dürüstçe unsupported; iOS yerel modülü varsa sonucu tipli döner", async () => {
  assert.deepEqual(await createFeralin(undefined, "ios").bindInstall(), { status: "unsupported", installId: null });
  const android = createFeralin(fakeNative(), "android");
  await android.initialize(CONFIG);
  assert.deepEqual(await android.bindInstall(), { status: "unsupported", installId: null });

  const native = fakeNative({ bindInstall: async () => ({ status: "received", installId: "01INSTALL" }) });
  const api = createFeralin(native, "ios");
  assert.deepEqual(await api.bindInstall(), { status: "not_initialized", installId: null });
  await api.initialize(CONFIG);
  assert.deepEqual(await api.bindInstall(), { status: "received", installId: "01INSTALL" });

  const failing = createFeralin(fakeNative({ bindInstall: async () => { throw new Error("köprü"); } }), "ios");
  await failing.initialize(CONFIG);
  assert.deepEqual(await failing.bindInstall(), { status: "not_initialized", installId: null });
  const garbled = createFeralin(fakeNative({ bindInstall: async () => ({ installId: 5 }) }), "ios");
  await garbled.initialize(CONFIG);
  assert.deepEqual(await garbled.bindInstall(), { status: "not_initialized", installId: null });
});

test("kurulum eşleştirme kodu yalnız biçimi doğruysa yerel katmana iletilir", async () => {
  const native = fakeNative();
  assert.equal(await createFeralin(native, "android").initialize({ ...CONFIG, installCode: " K7M2-Q9XR4 " }), true);
  assert.equal(native.calls[0][1].installCode, "K7M2-Q9XR4");
  const other = fakeNative();
  assert.equal(await createFeralin(other, "android").initialize({ ...CONFIG, installCode: "x;DROP" }), true);
  assert.equal("installCode" in other.calls[0][1], false);
});
