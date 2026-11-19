// JS/TS katmanı birim testleri: yerel eklenti sahte nesneyle verilir; web yedeği hem sahte hem gerçek @feralin/web derlemesiyle sınanır.
// Önce derleme gerekir: npm run build (dist/esm). Yerel köprülerin yöntem adları kaynak dosyalarla karşılaştırılır.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const { createFeralin, buildRevenueProperties, normalizeConfig, SDK_NAME, SDK_VERSION } = await import(pathToFileURL(join(root, "dist/esm/core.js")).href);
const { createWebNative } = await import(pathToFileURL(join(root, "dist/esm/web-native.js")).href);

const validConfig = { projectKey: "pk_test_123456", collectUrl: "https://collect.example.com" };

/** Çağrıları kaydeden sahte yerel eklenti; yanıt yöntem adına göre verilir. */
function fakeNative(responses = {}) {
  const calls = [];
  const handler = {
    get(_target, method) {
      return async (options) => {
        calls.push({ method, options });
        const response = responses[method];
        if (response === "throw") throw new Error("yerel hata");
        return typeof response === "function" ? response(options) : response;
      };
    },
  };
  return { native: new Proxy({}, handler), calls };
}

test("yerel eklenti yoksa her yöntem güvenli varsayılan döner", async () => {
  const feralin = createFeralin(null);
  assert.equal(await feralin.initialize(validConfig), false);
  assert.equal(await feralin.track("level_up"), null);
  assert.deepEqual(await feralin.flush(), { sent: 0, accepted: 0, rejected: 0, status: 0, batchId: null });
  assert.deepEqual(await feralin.consumeDeferredDeepLink(), { status: "failed", path: null, linkCode: null });
  assert.equal((await feralin.getStatus()).initialized, false);
});

test("initialize: gizli anahtar ve bozuk imza anahtarı yerel katmana gitmez; geçerli yapılandırma süzülür", async () => {
  const { native, calls } = fakeNative({ initialize: { ready: true } });
  const feralin = createFeralin(native);
  assert.equal(await feralin.initialize({ projectKey: "sk_live_123456", collectUrl: "https://c.example.com" }), false);
  assert.equal(await feralin.initialize({ ...validConfig, signingKey: { id: "sgn_x", secret: "kisa" } }), false);
  assert.equal(calls.length, 0);
  assert.equal(await feralin.initialize({ ...validConfig, consent: { analytics: true, personalization: 1 }, queueLimit: 0, debug: true }), true);
  assert.deepEqual(calls[0].options.config, {
    projectKey: "pk_test_123456",
    collectUrl: "https://collect.example.com",
    sdkName: SDK_NAME,
    sdkVersion: SDK_VERSION,
    consent: { analytics: true },
    debug: true,
  });
});

test("yerel hata Promise reddine dönüşmez", async () => {
  const { native } = fakeNative({ track: "throw", getStatus: "throw", flush: "throw" });
  const feralin = createFeralin(native);
  assert.equal(await feralin.track("level_up"), null);
  assert.equal((await feralin.getStatus()).sdk, SDK_NAME);
  assert.equal((await feralin.flush()).status, 0);
});

test("track ve screen: ad ve özellikler doğrulanır", async () => {
  const { native, calls } = fakeNative({ track: { eventId: "e1" }, screen: { eventId: "s1" } });
  const feralin = createFeralin(native);
  assert.equal(await feralin.track("Kötü Ad"), null);
  assert.equal(calls.length, 0);
  assert.equal(await feralin.track("level_up", { level: 2, "kötü anahtar": 1, f: () => 0 }), "e1");
  assert.deepEqual(calls[0].options, { name: "level_up", properties: { level: 2 } });
  assert.equal(await feralin.screen("home"), "s1");
  assert.deepEqual(calls[1].options, { name: "home", properties: null });
});

test("trackRevenue: sözleşme Web ve Cordova ile aynı", async () => {
  assert.equal(buildRevenueProperties({ transactionId: "t", amountMinor: 1.5, currency: "TRY" }), null);
  assert.equal(buildRevenueProperties({ transactionId: "t", amountMinor: 10, currency: "TRY", purchaseType: "subscription_cancel" }), null);
  const { native, calls } = fakeNative({ trackRevenue: { eventId: "r1" } });
  const id = await createFeralin(native).trackRevenue({
    transactionId: "order_1", amountMinor: 0, currency: "USD", purchaseType: "subscription_cancel", properties: { verified: true, plan: "pro" },
  });
  assert.equal(id, "r1");
  assert.deepEqual(calls[0].options.properties, {
    plan: "pro", transaction_id: "order_1", amount_minor: 0, currency: "USD", quantity: 1, purchase_type: "subscription_cancel",
  });
  assert.equal(calls[0].options.input.purchaseType, "subscription_cancel");
});

test("ilk açılış, mağaza, derin bağlantı ve push belirteci sonuçları normalleştirilir", async () => {
  const { native, calls } = fakeNative({
    trackFirstOpen: { status: "sent", eventId: "fo1" },
    getInstallStore: { installStore: "app_store" },
    consumeDeferredDeepLink: { status: "pending" },
    handleShortLink: { destination: "/kis", linkCode: "kis", hasClickId: true },
    setPushToken: { eventId: "p1" },
    installIdentifier: { installId: "01JINSTALL" },
  });
  const feralin = createFeralin(native);
  assert.deepEqual(await feralin.trackFirstOpen({ clickId: "c1", source: "clipboard" }), { status: "sent", eventId: "fo1" });
  assert.deepEqual(calls[0].options, { options: { clickId: "c1", source: "clipboard" } });
  assert.equal(await feralin.getInstallStore(), "app_store");
  let seen;
  assert.deepEqual(await feralin.consumeDeferredDeepLink((link) => { seen = link; }), { status: "pending", path: null, linkCode: null });
  assert.equal(seen.status, "pending");
  assert.deepEqual(await feralin.handleShortLink("https://marka.fera.fly/kis"), { destination: "/kis", linkCode: "kis", hasClickId: true });
  assert.deepEqual(await feralin.handleShortLink("ftp://x"), { destination: "/", linkCode: null, hasClickId: false });
  assert.equal(await feralin.setPushToken("x"), null);
  assert.equal(await feralin.setPushToken("a".repeat(40)), "p1");
  assert.equal(await feralin.installIdentifier(), "01JINSTALL");
  assert.equal(feralin.isUninstallCheck({ fr_uninstall_check: "1" }), true);
  assert.equal(feralin.isUninstallCheck({ fr_uninstall_check: "0" }), false);
});

// --- Web yedeği ---

function fakeWebSdk() {
  const events = [];
  const state = { consent: { analytics: false }, userId: null, globals: {} };
  const client = {
    track(name, properties) {
      if (!state.consent.analytics) return null;
      events.push({ name, properties });
      return { event_id: `w${events.length}` };
    },
    trackRevenue(input) { return client.track("feralin_purchase", input); },
    identify(userId) { state.userId = userId; },
    group(groupId) { return client.track("fr_group", { group_id: groupId }); },
    setUserProperties(properties) { return client.track("fr_user_properties", properties); },
    setGlobalProperties(properties) { Object.assign(state.globals, properties); },
    clearGlobalProperties() { state.globals = {}; },
    setConsent(consent) { state.consent = consent; },
    async flush() { return { sent: events.length, accepted: events.length, rejected: 0, status: 202, batch_id: "b1" }; },
    reset() { state.userId = null; },
    getStatus() { return { sdk: "@feralin/web", version: "0.1.0", queued: events.length, consent: state.consent, anonymous_id: "a1", session_id: "s1", user_id: state.userId }; },
  };
  const sdk = {
    options: null,
    initialize(options) {
      if (!options.projectKey.startsWith("pk_")) throw new Error("feralin: projectKey pk_ ile başlamalı");
      sdk.options = options;
      if (options.consent) state.consent = options.consent;
      return client;
    },
    sanitizeProfileProperties(input) {
      return { properties: Object.fromEntries(Object.entries(input).filter(([key]) => key !== "email")) };
    },
  };
  return { sdk, events };
}

test("web yedeği: çağrılar Web SDK'ya gider, uygulamaya özgü yetenekler not_supported döner", async () => {
  const { sdk, events } = fakeWebSdk();
  const feralin = createFeralin(createWebNative(async () => sdk));
  assert.equal(await feralin.track("before_init"), null);
  assert.equal(await feralin.initialize({ ...validConfig, consent: { analytics: true }, batchSize: 900 }), true);
  assert.equal(sdk.options.batchSize, 500);
  assert.equal(await feralin.track("level_up", { level: 1 }), "w1");
  assert.equal(await feralin.screen("home", { tab: "a" }), "w2");
  assert.deepEqual(events[1], { name: "screen_view", properties: { tab: "a", screen_name: "home" } });
  assert.equal(await feralin.identify("u1"), true);
  assert.equal(await feralin.setGlobalProperties({ theme: "dark", email: "x" }), 1);
  assert.equal(await feralin.trackRevenue({ transactionId: "o1", amountMinor: 100, currency: "EUR" }), "w3");
  assert.deepEqual(await feralin.trackFirstOpen(), { status: "not_supported", eventId: null });
  assert.deepEqual(await feralin.consumeDeferredDeepLink(), { status: "not_supported", path: null, linkCode: null });
  assert.equal(await feralin.getInstallStore(), null);
  assert.equal(await feralin.setPushToken("t".repeat(40)), null);
  assert.deepEqual(await feralin.handleUniversalLink("https://example.com/urun/42?renk=mavi&fr_click=abc"), { destination: "/urun/42?renk=mavi", linkCode: null, hasClickId: false });
  assert.deepEqual(await feralin.flush(), { sent: 3, accepted: 3, rejected: 0, status: 202, batchId: "b1" });
  assert.deepEqual(await feralin.getStatus(), {
    initialized: true, sdk: "@feralin/web", version: "0.1.0", queued: 3, consent: { analytics: true }, anonymousId: "a1", sessionId: "s1", userId: "u1",
  });
  assert.equal(await feralin.optOut(), true);
  assert.equal(await feralin.track("after_opt_out"), null);
});

test("web yedeği: Web SDK'nın reddettiği yapılandırma false döner", async () => {
  const { sdk } = fakeWebSdk();
  const native = createWebNative(async () => sdk);
  const feralin = createFeralin(native);
  // JS katmanı pk_ denetimini geçen ama web çekirdeğinin reddettiği bir durum: çekirdek hatası yakalanır.
  sdk.initialize = () => { throw new Error("feralin: reddedildi"); };
  assert.equal(await feralin.initialize(validConfig), false);
});

const webDist = join(root, "../../packages/sdk-web/dist/feralin.mjs");
test("web yedeği gerçek @feralin/web derlemesiyle çalışır (ağ çağrısı yapılmaz)", { skip: !existsSync(webDist) && "packages/sdk-web derlenmemiş" }, async () => {
  const feralin = createFeralin(createWebNative(() => import(pathToFileURL(webDist).href)));
  assert.equal(await feralin.initialize({ ...validConfig, consent: { analytics: true }, flushIntervalMs: 3_600_000 }), true);
  const id = await feralin.track("level_up", { level: 1 });
  assert.match(id, /^[0-9A-Za-z-]{16,64}$/);
  assert.match(await feralin.trackRevenue({ transactionId: "o1", amountMinor: 4999, currency: "TRY" }), /^[0-9A-Za-z-]{16,64}$/);
  assert.equal(await feralin.trackRevenue({ transactionId: "o1", amountMinor: 4999, currency: "try" }), null);
  const status = await feralin.getStatus();
  assert.equal(status.initialized, true);
  assert.equal(status.sdk, "@feralin/web");
  assert.equal(status.queued, 2);
  assert.equal(await feralin.setConsent({ analytics: false }), true);
  assert.equal((await feralin.getStatus()).queued, 0);
});

test("normalizeConfig iOS ertelenmiş bağlantı yapılandırmasını taşır", () => {
  const config = normalizeConfig({ ...validConfig, attribution: { apiUrl: "https://api.example.com", projectId: "prj_1" } });
  assert.deepEqual(config.attribution, { apiUrl: "https://api.example.com", projectId: "prj_1" });
  assert.equal(normalizeConfig({ ...validConfig, attribution: { apiUrl: "javascript:x", projectId: "p" } }).attribution, undefined);
});

// --- Kaynak tutarlılığı: yerel köprüler burada derlenmediği için yöntem adları ve alanlar metinden denetlenir. ---

function nativeMethods() {
  const source = readFileSync(join(root, "src/definitions.ts"), "utf8");
  const block = /export interface NativeFeralin \{([\s\S]*?)\n\}/.exec(source)[1];
  return [...block.matchAll(/^\s+(\w+)\(/gm)].map((m) => m[1]);
}

test("her yerel yöntem Android, iOS ve web yedeğinde karşılanır", () => {
  const methods = nativeMethods();
  assert.equal(methods.length, 20);
  const java = readFileSync(join(root, "android/src/main/java/com/feralin/capacitor/FeralinPlugin.java"), "utf8");
  const swift = readFileSync(join(root, "ios/Sources/FeralinCapacitorPlugin/FeralinPlugin.swift"), "utf8");
  const web = readFileSync(join(root, "src/web-native.ts"), "utf8");
  for (const method of methods) {
    assert.match(java, new RegExp(`@PluginMethod\\s+public void ${method}\\(PluginCall call\\)`), `Android: ${method}`);
    assert.ok(swift.includes(`CAPPluginMethod(name: "${method}", returnType: CAPPluginReturnPromise)`), `iOS yöntem listesi: ${method}`);
    assert.ok(swift.includes(`@objc func ${method}(_ call: CAPPluginCall)`), `iOS: ${method}`);
    assert.match(web, new RegExp(`async ${method}\\(`), `web: ${method}`);
  }
  assert.match(java, /@CapacitorPlugin\(name = "Feralin"\)/);
  assert.ok(swift.includes('public let jsName = "Feralin"'));
});

test("ortak iOS köprüsü Cordova kopyasıyla birebir aynı", () => {
  const own = readFileSync(join(root, "ios/Sources/FeralinCapacitorPlugin/FeralinBridge.swift"), "utf8");
  const cordova = readFileSync(join(root, "../cordova/src/ios/Plugin/FeralinBridge.swift"), "utf8");
  assert.equal(own, cordova);
});

test("Java köprüsünün FeralinConfig alan sırası Android çekirdeğiyle aynı", () => {
  const types = readFileSync(join(root, "../android/feralin/src/main/kotlin/com/feralin/android/Types.kt"), "utf8");
  const fields = [...(/public data class FeralinConfig\(([\s\S]*?)\n\) \{/.exec(types)[1]).matchAll(/^\s*val (\w+):/gm)].map((m) => m[1]);
  const java = readFileSync(join(root, "android/src/main/java/com/feralin/capacitor/FeralinPlugin.java"), "utf8");
  const comment = /FeralinConfig alanları \(sırayla[^\n]*\n\s*\*\s*([^\n]+)\n\s*\*\s*([^\n]+)/.exec(java);
  assert.deepEqual(`${comment[1]} ${comment[2]}`.split(/[,\s]+/).filter(Boolean), fields);
  const args = /return new FeralinConfig\(([\s\S]*?)\);/.exec(java)[1].split("\n").map((l) => l.trim()).filter(Boolean);
  assert.equal(args.length, fields.length);
});

test("paket adı, Swift paketi ve podspec Capacitor CLI adlandırmasıyla uyumlu", () => {
  const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  // Capacitor CLI fixName: @feralin/capacitor → FeralinCapacitor
  const fixed = pkg.name.replace(/\//g, "_").replace(/-/g, "_").replace(/@/g, "").replace(/_\w/g, (m) => m[1].toUpperCase());
  const iosName = fixed.charAt(0).toUpperCase() + fixed.slice(1);
  assert.equal(iosName, "FeralinCapacitor");
  const swiftPackage = readFileSync(join(root, "Package.swift"), "utf8");
  assert.match(swiftPackage, new RegExp(`name: "${iosName}"`));
  assert.match(swiftPackage, new RegExp(`\\.library\\(name: "${iosName}"`));
  assert.match(readFileSync(join(root, "FeralinCapacitor.podspec"), "utf8"), new RegExp(`s\\.name = '${iosName}'`));
  assert.equal(pkg.version, SDK_VERSION);
  assert.equal(pkg.name, SDK_NAME);
});
