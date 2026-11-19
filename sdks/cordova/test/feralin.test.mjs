// JS yüzü birim testleri: `cordova/exec` sahte işlevle verilir. Yerel köprülerin eylem adları ve Android yapılandırma alanları kaynak
// dosyalarla karşılaştırılır (köprüler burada derlenmez; bkz. README "Doğrulama durumu").
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(import.meta.url);
const plugin = require("../www/feralin.js");

/** Çağrıları kaydeden sahte exec; yanıt eylem adına göre verilir. */
function fakeExec(responses = {}) {
  const calls = [];
  const exec = (success, failure, service, action, args) => {
    calls.push({ service, action, args });
    const response = responses[action];
    if (typeof response === "function") return response(success, failure, args);
    if (response === "fail") return failure("bridge_error");
    if (response === "throw") throw new Error("exec yok");
    success(response);
  };
  return { exec, calls };
}

const validConfig = { projectKey: "pk_test_123456", collectUrl: "https://collect.example.com" };

test("cordova/exec yoksa yalnız fabrika dışa aktarılır", () => {
  assert.equal(typeof plugin.createFeralin, "function");
  assert.equal(plugin.track, undefined);
});

test("initialize: gizli anahtar, bozuk adres ve bozuk imza anahtarı yerel katmana gitmez", async () => {
  const { exec, calls } = fakeExec({ initialize: true });
  const feralin = plugin.createFeralin(exec);
  assert.equal(await feralin.initialize({ projectKey: "sk_live_123456", collectUrl: "https://c.example.com" }), false);
  assert.equal(await feralin.initialize({ projectKey: " SK_live_123456", collectUrl: "https://c.example.com" }), false);
  assert.equal(await feralin.initialize({ projectKey: "pk_test_123456", collectUrl: "ftp://c.example.com" }), false);
  assert.equal(await feralin.initialize({ ...validConfig, signingKey: { id: "bad", secret: "x".repeat(20) } }), false);
  assert.equal(await feralin.initialize(null), false);
  assert.equal(calls.length, 0);
});

test("initialize: yapılandırma süzülür, SDK adı ve sürümü eklenir", async () => {
  const { exec, calls } = fakeExec({ initialize: true });
  const feralin = plugin.createFeralin(exec);
  const ready = await feralin.initialize({
    ...validConfig,
    projectKey: "  pk_test_123456  ",
    consent: { analytics: true, advertising: false, extra: 1 },
    batchSize: 20,
    flushIntervalMs: -5,
    installCode: "ABCDE-FGHJK",
    metaAppId: "12ab",
    signingKey: { id: "sgn_abcdefghijkl", secret: "s".repeat(32) },
    attribution: { apiUrl: "https://api.example.com", projectId: "prj_1" },
    shortLinkHosts: ["marka.fera.fly", "kötü host"],
  });
  assert.equal(ready, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].service, "Feralin");
  const sent = calls[0].args[0];
  assert.equal(sent.projectKey, "pk_test_123456");
  assert.deepEqual(sent.consent, { analytics: true, advertising: false });
  assert.equal(sent.batchSize, 20);
  assert.equal("flushIntervalMs" in sent, false);
  assert.equal(sent.installCode, "ABCDE-FGHJK");
  assert.equal("metaAppId" in sent, false);
  assert.deepEqual(sent.signingKey, { id: "sgn_abcdefghijkl", secret: "s".repeat(32) });
  assert.deepEqual(sent.shortLinkHosts, ["marka.fera.fly"]);
  assert.equal(sent.sdkName, "cordova-plugin-feralin");
  assert.equal(sent.sdkVersion, plugin.createFeralin(exec).SDK_VERSION);
});

test("track: geçersiz ad yerel katmana gitmez, özellikler şema desenine göre süzülür", async () => {
  const { exec, calls } = fakeExec({ track: "01JTESTEVENT0000000000000" });
  const feralin = plugin.createFeralin(exec);
  assert.equal(await feralin.track("Bad Name"), null);
  assert.equal(await feralin.track(""), null);
  assert.equal(await feralin.track("a".repeat(101)), null);
  assert.equal(calls.length, 0);
  const id = await feralin.track("level_up", { level: 3, ok: true, "bad key": 1, fn: () => 1, inf: Infinity, nested: { a: [1, undefined, 2] } });
  assert.equal(id, "01JTESTEVENT0000000000000");
  assert.deepEqual(calls[0].args, ["level_up", { level: 3, ok: true, nested: { a: [1, 2] } }]);
});

test("track: 100 özellik sınırı aşılmaz", async () => {
  const { exec, calls } = fakeExec({ track: "e1" });
  const props = {};
  for (let i = 0; i < 150; i++) props[`k${i}`] = i;
  await plugin.createFeralin(exec).track("many", props);
  assert.equal(Object.keys(calls[0].args[1]).length, 100);
});

test("yerel hata, istisna ve boş yanıt güvenli varsayılana döner; Promise reddedilmez", async () => {
  const failing = plugin.createFeralin(fakeExec({ track: "fail", flush: "throw", getStatus: "fail", installIdentifier: undefined }).exec);
  assert.equal(await failing.track("ok_event"), null);
  assert.deepEqual(await failing.flush(), { sent: 0, accepted: 0, rejected: 0, status: 0, batchId: null });
  const status = await failing.getStatus();
  assert.equal(status.initialized, false);
  assert.equal(status.sdk, "cordova-plugin-feralin");
  assert.equal(await failing.installIdentifier(), null);
});

test("setConsent: analytics boolean değilse yok sayılır; optOut analitik izni kapatır", async () => {
  const { exec, calls } = fakeExec({ setConsent: true });
  const feralin = plugin.createFeralin(exec);
  assert.equal(await feralin.setConsent({ advertising: true }), false);
  assert.equal(calls.length, 0);
  assert.equal(await feralin.setConsent({ analytics: true, advertising: true, session_replay: "evet" }), true);
  assert.deepEqual(calls[0].args, [{ analytics: true, advertising: true }]);
  assert.equal(await feralin.optOut(), true);
  assert.deepEqual(calls[1].args, [{ analytics: false }]);
});

test("identify ve group uzunluk sınırları", async () => {
  const { exec, calls } = fakeExec({ identify: true, group: "g1" });
  const feralin = plugin.createFeralin(exec);
  assert.equal(await feralin.identify(""), false);
  assert.equal(await feralin.identify("u".repeat(129)), false);
  assert.equal(await feralin.group("", {}), null);
  assert.equal(calls.length, 0);
  assert.equal(await feralin.identify("user_42"), true);
  assert.equal(await feralin.group("acct_42", { plan: "pro" }), "g1");
});

test("trackRevenue: sözleşme dışı girdi olay üretmez", async () => {
  const { exec, calls } = fakeExec({ trackRevenue: "r1" });
  const feralin = plugin.createFeralin(exec);
  assert.equal(await feralin.trackRevenue({ transactionId: "t1", amountMinor: 49.99, currency: "TRY" }), null);
  assert.equal(await feralin.trackRevenue({ transactionId: "t1", amountMinor: 4999, currency: "try" }), null);
  assert.equal(await feralin.trackRevenue({ transactionId: "", amountMinor: 4999, currency: "TRY" }), null);
  assert.equal(await feralin.trackRevenue({ transactionId: "t1", amountMinor: 100, currency: "TRY", purchaseType: "subscription_cancel" }), null);
  assert.equal(await feralin.trackRevenue({ transactionId: "t1", amountMinor: 100, currency: "TRY", receipt: { provider: "paypal", token: "x" } }), null);
  assert.equal(await feralin.trackRevenue({ transactionId: "t1", amountMinor: 100, currency: "TRY", quantity: 100001 }), null);
  assert.equal(calls.length, 0);
});

test("trackRevenue: doğrulama beyanı düşer, Android girdisi ve iOS özellikleri birlikte gider", async () => {
  const { exec, calls } = fakeExec({ trackRevenue: "r1" });
  const feralin = plugin.createFeralin(exec);
  const id = await feralin.trackRevenue({
    transactionId: "order_1",
    amountMinor: 4999,
    currency: "TRY",
    productId: "pro_monthly",
    purchaseType: "subscription_start",
    receipt: { provider: "apple", token: "tok" },
    properties: { verified: true, receipt_digest: "x", campaign: "kis" },
  });
  assert.equal(id, "r1");
  const [wire, props] = calls[0].args;
  assert.deepEqual(wire, {
    transactionId: "order_1",
    amountMinor: 4999,
    currency: "TRY",
    quantity: 1,
    purchaseType: "subscription_start",
    productId: "pro_monthly",
    receipt: { provider: "apple", token: "tok" },
    properties: { verified: true, receipt_digest: "x", campaign: "kis" },
  });
  assert.deepEqual(props, {
    campaign: "kis",
    transaction_id: "order_1",
    amount_minor: 4999,
    currency: "TRY",
    quantity: 1,
    purchase_type: "subscription_start",
    product_id: "pro_monthly",
    receipt: { provider: "apple", token: "tok" },
  });
});

test("ilk açılış: seçenekler süzülür, bilinmeyen durum skipped olur", async () => {
  const { exec, calls } = fakeExec({ trackFirstOpen: { status: "sent", eventId: "fo1" } });
  const feralin = plugin.createFeralin(exec);
  assert.deepEqual(await feralin.trackFirstOpen({ clickId: "abc", source: "Clip Board", advertisingId: "uuid" }), { status: "sent", eventId: "fo1" });
  assert.deepEqual(calls[0].args, [{ clickId: "abc", advertisingId: "uuid" }]);
  const odd = plugin.createFeralin(fakeExec({ trackFirstOpen: { status: "weird" } }).exec);
  assert.deepEqual(await odd.trackFirstOpen(), { status: "skipped", eventId: null });
  const android = plugin.createFeralin(fakeExec({ trackFirstOpen: { status: "automatic" } }).exec);
  assert.deepEqual(await android.trackFirstOpen(), { status: "automatic", eventId: null });
});

test("ertelenmiş derin bağlantı: geri çağrı ve normalleştirme", async () => {
  const { exec } = fakeExec({ consumeDeferredDeepLink: { status: "delivered", path: "/urun/42", linkCode: "kis" } });
  const feralin = plugin.createFeralin(exec);
  let seen = null;
  const link = await feralin.consumeDeferredDeepLink((value) => {
    seen = value;
    throw new Error("uygulama hatası sonucu bozmaz");
  });
  assert.deepEqual(link, { status: "delivered", path: "/urun/42", linkCode: "kis" });
  assert.deepEqual(seen, link);
  const broken = plugin.createFeralin(fakeExec({ consumeDeferredDeepLink: { status: "matched" } }).exec);
  assert.deepEqual(await broken.consumeDeferredDeepLink(), { status: "failed", path: null, linkCode: null });
});

test("link açılışı: geçersiz adres yerel katmana gitmez, yanıt yoksa adresin yolu döner", async () => {
  const { exec, calls } = fakeExec({ handleShortLink: "fail", handleUniversalLink: { destination: "/a?b=1", linkCode: null, hasClickId: true } });
  const feralin = plugin.createFeralin(exec);
  assert.deepEqual(await feralin.handleShortLink("javascript:alert(1)"), { destination: "/", linkCode: null, hasClickId: false });
  assert.equal(calls.length, 0);
  assert.deepEqual(await feralin.handleShortLink("https://marka.fera.fly/kis?x=1#y"), { destination: "/kis?x=1", linkCode: null, hasClickId: false });
  assert.deepEqual(await feralin.handleUniversalLink("https://example.com/a?b=1"), { destination: "/a?b=1", linkCode: null, hasClickId: true });
});

test("push belirteci ve kaldırma ölçümü bildirimi", async () => {
  const { exec, calls } = fakeExec({ setPushToken: "p1" });
  const feralin = plugin.createFeralin(exec);
  assert.equal(await feralin.setPushToken("kisa"), null);
  assert.equal(await feralin.setPushToken(42), null);
  assert.equal(calls.length, 0);
  assert.equal(await feralin.setPushToken("f".repeat(64)), "p1");
  assert.equal(feralin.isUninstallCheck({ fr_uninstall_check: "1" }), true);
  assert.equal(feralin.isUninstallCheck({ fr_uninstall_check: 1 }), false);
  assert.equal(feralin.isUninstallCheck({}), false);
  assert.equal(feralin.isUninstallCheck(null), false);
});

test("getStatus ve flush sonuçları normalleştirilir", async () => {
  const feralin = plugin.createFeralin(fakeExec({
    getStatus: { initialized: true, sdk: "feralin-android", version: "0.1.0", queued: 3, consent: { analytics: true }, sessionId: "s1" },
    flush: { sent: 2, accepted: 2, rejected: 0, status: 202, batchId: "b1", extra: true },
  }).exec);
  assert.deepEqual(await feralin.getStatus(), {
    initialized: true, sdk: "feralin-android", version: "0.1.0", queued: 3, consent: { analytics: true }, anonymousId: null, sessionId: "s1", userId: null,
  });
  assert.deepEqual(await feralin.flush(), { sent: 2, accepted: 2, rejected: 0, status: 202, batchId: "b1" });
});

// --- Kaynak tutarlılığı: köprüler derlenmediği için eylem adları ve yapılandırma alanları metinden denetlenir. ---

function jsActions() {
  const source = readFileSync(join(root, "www/feralin.js"), "utf8");
  return [...new Set([...source.matchAll(/call\('([a-zA-Z]+)'/g)].map((m) => m[1]))].sort();
}

test("her JS eylemi Android ve iOS köprüsünde karşılanır", () => {
  const actions = jsActions();
  assert.ok(actions.length >= 20);
  const java = readFileSync(join(root, "src/android/FeralinPlugin.java"), "utf8");
  const swift = readFileSync(join(root, "src/ios/Plugin/FeralinCordovaPlugin.swift"), "utf8");
  for (const action of actions) {
    assert.ok(java.includes(`case "${action}":`), `Android köprüsünde eksik: ${action}`);
    assert.ok(swift.includes(`@objc func ${action}(_ command: CDVInvokedUrlCommand)`), `iOS köprüsünde eksik: ${action}`);
  }
});

test("Java köprüsünün FeralinConfig alan sırası Android çekirdeğiyle aynı", () => {
  const types = readFileSync(join(root, "../android/feralin/src/main/kotlin/com/feralin/android/Types.kt"), "utf8");
  const block = /public data class FeralinConfig\(([\s\S]*?)\n\) \{/.exec(types);
  assert.ok(block, "FeralinConfig bulunamadı");
  const fields = [...block[1].matchAll(/^\s*val (\w+):/gm)].map((m) => m[1]);
  const java = readFileSync(join(root, "src/android/FeralinPlugin.java"), "utf8");
  const comment = /FeralinConfig alanları \(sırayla[^\n]*\n\s*\*\s*([^\n]+)\n\s*\*\s*([^\n]+)/.exec(java);
  assert.ok(comment, "Java alan yorumu bulunamadı");
  const documented = `${comment[1]} ${comment[2]}`.split(/[,\s]+/).filter(Boolean);
  assert.deepEqual(documented, fields);
  const call = /return new FeralinConfig\(([\s\S]*?)\);/.exec(java);
  const argCount = call[1].split("\n").map((line) => line.trim()).filter((line) => line.length > 0).length;
  assert.equal(argCount, fields.length);
});

test("plugin.xml ve package.json kimlikleri ve sürümleri tutarlı", () => {
  const xml = readFileSync(join(root, "plugin.xml"), "utf8");
  const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  const swiftPackage = readFileSync(join(root, "Package.swift"), "utf8");
  assert.match(xml, new RegExp(`id="${pkg.cordova.id}"`));
  assert.equal(pkg.name, pkg.cordova.id);
  assert.match(xml, new RegExp(`version="${pkg.version}"`));
  assert.match(swiftPackage, new RegExp(`\\.library\\(name: "${pkg.cordova.id}"`));
  assert.equal(plugin.createFeralin(() => {}).SDK_VERSION, pkg.version);
  assert.match(xml, /<platform name="ios" package="swift">/);
  assert.match(xml, /<clobbers target="Feralin" \/>/);
});
