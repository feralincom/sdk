// Birim testleri: sahte fetch ile SDK davranışı ve şema uyumu. Gerçek toplayıcı testi scripts/sdk-e2e/run.mjs içindedir.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { FeralinClient, idempotencyKeyFor } from "../dist/esm/index.js";

const require = createRequire(import.meta.url);
const Ajv2020 = require("ajv/dist/2020").default;
const addFormats = require("ajv-formats").default ?? require("ajv-formats");

const eventSchema = JSON.parse(readFileSync(new URL("../../../packages/schemas/utp/v1/event.schema.json", import.meta.url), "utf8"));
const batchSchema = JSON.parse(readFileSync(new URL("../../../packages/schemas/utp/v1/batch.schema.json", import.meta.url), "utf8"));
const ajv = new Ajv2020({ strict: false });
addFormats(ajv);
ajv.addSchema(eventSchema);
const validateBatch = ajv.compile(batchSchema);

const KEY = "pk_test_node_unit_0001";
const URL_BASE = "http://collector.test";
const GRANTED = { analytics: true };

function fakeFetch(responses = []) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    const next = responses.length ? responses.shift() : { status: 202, body: { batch_id: "b1", accepted: 1, rejected: 0 } };
    if (next instanceof Error) throw next;
    return new Response(next.body === undefined ? "" : JSON.stringify(next.body), { status: next.status, headers: next.headers ?? {} });
  };
  return { impl, calls };
}

function client(fetchImpl, extra = {}) {
  return new FeralinClient({ projectKey: KEY, collectUrl: URL_BASE, flushIntervalMs: 0, fetch: fetchImpl, consent: GRANTED, ...extra });
}

test("yapılandırma: sk_, pk_ olmayan anahtar ve geçersiz URL reddedilir", () => {
  assert.throws(() => new FeralinClient({ projectKey: "sk_live_12345678", collectUrl: URL_BASE }), /gizli anahtar/);
  assert.throws(() => new FeralinClient({ projectKey: "abc_12345678", collectUrl: URL_BASE }), /pk_/);
  assert.throws(() => new FeralinClient({ projectKey: KEY, collectUrl: "ftp://x" }), /collectUrl/);
  assert.throws(() => new FeralinClient({ projectKey: KEY, collectUrl: "yol" }), /collectUrl/);
});

test("izin zorunlu: varsayılan analytics=false, olay üretilmez ve istek yapılmaz", async () => {
  const { impl, calls } = fakeFetch();
  const c = new FeralinClient({ projectKey: KEY, collectUrl: URL_BASE, flushIntervalMs: 0, fetch: impl });
  assert.equal(c.track("order_completed"), null);
  assert.equal((await c.flush()).sent, 0);
  assert.equal(calls.length, 0);
});

test("olay bazlı izin varsayılanı aşar, açık ret aşılamaz", () => {
  const { impl } = fakeFetch();
  const c = new FeralinClient({ projectKey: KEY, collectUrl: URL_BASE, flushIntervalMs: 0, fetch: impl });
  assert.ok(c.track("a_event", {}, { consent: GRANTED }));
  c.optOut();
  assert.equal(c.getStatus().queued, 0, "ret kuyruğu siler");
  assert.equal(c.track("a_event", {}, { consent: GRANTED }), null);
  c.setConsent(GRANTED);
  assert.ok(c.track("a_event"));
});

test("fr_click yalnız consent.advertising === true iken gider", () => {
  const { impl } = fakeFetch();
  const c = client(impl);
  assert.equal(c.track("a", { fr_click: "x", keep: 1 }).properties.fr_click, undefined);
  assert.equal(c.track("a", { fr_click: "x" }, { consent: { analytics: true, advertising: false } }).properties, undefined);
  assert.equal(c.track("a", { fr_click: "x" }, { consent: { analytics: true, advertising: "evet" } }).properties, undefined);
  assert.equal(c.track("a", { fr_click: "x" }, { consent: { analytics: true, advertising: true } }).properties.fr_click, "x");
});

test("üretilen batch UTP v1 şemasına uyar; anahtar gövdede ve URL'de yok, yalnız başlıkta", async () => {
  const { impl, calls } = fakeFetch();
  const c = client(impl);
  c.identify("user_42");
  c.track(
    "order_completed",
    { order_id: "ord_1", "geçersiz anahtar": 1, fn() {} },
    {
      anonymousId: "anon_1",
      sessionId: "sess_1",
      occurredAt: new Date("2026-11-03T10:00:00.000Z"),
      context: {
        page_url: "https://shop.example/odeme?token=gizli&utm_source=ads#x",
        referrer: "https://google.example/search?q=gizli",
        page_title: "Ödeme",
        locale: "tr-TR",
        timezone: "Europe/Istanbul",
        screen: { width: 1, height: -1 },
        app: { version: "1.0.0" },
        bilinmeyen: "x",
      },
    },
  );
  c.page();
  const result = await c.flush();
  assert.equal(result.status, 202);
  const { init, body, url } = calls[0];
  assert.ok(validateBatch(body), JSON.stringify(validateBatch.errors));
  assert.equal(url, `${URL_BASE}/v1/batch`);
  assert.equal(init.headers["x-feralin-project-key"], KEY);
  assert.ok(!init.body.includes(KEY));
  assert.ok(!url.includes(KEY));
  const event = body.events[0];
  assert.equal(event.platform, "node");
  assert.equal(event.schema_version, 1);
  assert.equal(event.user_id, "user_42");
  assert.equal(event.context.page_url, "https://shop.example/odeme");
  assert.equal(event.context.referrer, "https://google.example");
  assert.equal(event.properties.utm_source, "ads");
  assert.ok(!init.body.includes("gizli"));
  assert.deepEqual(event.context.screen, { width: 1 });
  assert.equal(body.events[1].event_name, "page_view");
  for (const banned of ["tenant_id", "project_id", "verified"]) assert.ok(!(banned in event));
});

test("geçersiz girdi fırlatmaz: ad, kimlik, BigInt ve döngüsel değer", () => {
  const warnings = [];
  const { impl } = fakeFetch();
  const c = client(impl, { logger: { warn: (m) => warnings.push(m) } });
  assert.equal(c.track("Geçersiz Ad"), null);
  assert.equal(c.track("a", {}, { userId: "x".repeat(129) }), null);
  assert.equal(c.track("a", { big: 10n }), null);
  const loop = {};
  loop.self = loop;
  assert.equal(c.track("a", { loop }), null);
  assert.equal(c.getStatus().queued, 0);
  assert.ok(warnings.length >= 3);
});

test("idempotency anahtarı tüm event_id özetinden; sıradan bağımsız ve Web SDK ile aynı değer", async () => {
  assert.equal(idempotencyKeyFor(["01JC0000000000000000000002", "01JC0000000000000000000001"]), idempotencyKeyFor(["01JC0000000000000000000001", "01JC0000000000000000000002"]));
  assert.equal(idempotencyKeyFor(["01JC0000000000000000000001", "01JC0000000000000000000002"]), "8f95d6b736d56c98-2");
  const { impl, calls } = fakeFetch();
  const c = client(impl);
  const a = c.track("a");
  const b = c.track("b");
  await c.flush();
  assert.equal(calls[0].init.headers["idempotency-key"], idempotencyKeyFor([a.event_id, b.event_id]));
});

test("sonucu bilinmeyen batch aynı içerik ve anahtarla yeniden denenir, yeni olay araya girmez", async () => {
  const { impl, calls } = fakeFetch([new Error("yanıt kayboldu"), { status: 503 }, { status: 202, body: { batch_id: "b1", accepted: 1, rejected: 0 } }, { status: 202, body: { batch_id: "b2", accepted: 1, rejected: 0 } }]);
  const c = client(impl);
  const first = c.track("a");
  const r1 = await c.flush();
  assert.deepEqual([r1.status, r1.retained], [0, 1]);
  const second = c.track("b");
  const r2 = await c.flush();
  assert.deepEqual([r2.status, r2.retained], [503, 2]);
  const r3 = await c.flush();
  assert.equal(r3.retained, 0);
  assert.equal(r3.sent, 2);
  assert.equal(calls[0].init.headers["idempotency-key"], calls[1].init.headers["idempotency-key"]);
  assert.equal(calls[1].init.headers["idempotency-key"], calls[2].init.headers["idempotency-key"]);
  assert.deepEqual(calls[2].body.events.map((e) => e.event_id), [first.event_id]);
  assert.deepEqual(calls[3].body.events.map((e) => e.event_id), [second.event_id]);
});

test("kalıcı 4xx olayları atar, fırlatmaz; 429 tutar ve Retry-After süresince istek yapmaz", async () => {
  let now = 1_000_000;
  const { impl, calls } = fakeFetch([{ status: 401, body: { title: "Proje anahtarı geçersiz" } }, { status: 429, headers: { "retry-after": "60" } }, { status: 202, body: { batch_id: "b", accepted: 1, rejected: 0 } }]);
  const c = client(impl, { now: () => now, random: () => 1 });
  c.track("a");
  const rejected = await c.flush();
  assert.deepEqual([rejected.status, rejected.rejected, rejected.retained], [401, 1, 0]);
  c.track("b");
  const limited = await c.flush();
  assert.deepEqual([limited.status, limited.retained], [429, 1]);
  const deferred = await c.flush();
  assert.deepEqual([deferred.sent, deferred.retained], [0, 1]);
  assert.equal(calls.length, 2);
  now += 61_000;
  assert.equal((await c.flush()).status, 202);
});

test("geri çekilme üstel, jitter'lı ve 30 sn ile sınırlı; arka plan turu beklemeye uyar", async () => {
  let now = 0;
  const { impl, calls } = fakeFetch(Array.from({ length: 12 }, () => new Error("ağ yok")));
  const c = client(impl, { now: () => now, random: () => 1 });
  c.track("a");
  const delays = [];
  for (let i = 0; i < 8; i++) {
    await c.flush();
    delays.push(c.getStatus().backoffMs);
  }
  assert.deepEqual(delays, [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000]);
  const half = client(fakeFetch([new Error("ağ yok")]).impl, { now: () => now, random: () => 0 });
  half.track("a");
  await half.flush();
  assert.equal(half.getStatus().backoffMs, 500);
  const before = calls.length;
  c.backgroundTick();
  assert.equal(calls.length, before);
});

test("kuyruk sınırı en eskiyi atar; batch boyutu ve 500 üst sınırı uygulanır", async () => {
  const { impl, calls } = fakeFetch();
  const c = client(impl, { queueLimit: 3, batchSize: 5 });
  const ids = ["a", "b", "c", "d"].map((n) => c.track(n).event_id);
  assert.equal(c.getStatus().dropped, 1);
  await c.flush();
  assert.deepEqual(calls.flatMap((x) => x.body.events.map((e) => e.event_id)), ids.slice(1));

  // Batch boyutu istek başına uygulanır; flushIntervalMs=0 iken açık çağrı olmadan istek yapılmaz.
  const small = fakeFetch();
  const eager = client(small.impl, { queueLimit: 3, batchSize: 2 });
  const eagerIds = ["a", "b", "c"].map((n) => eager.track(n).event_id);
  assert.equal(small.calls.length, 0);
  await eager.flush();
  assert.equal(small.calls[0].body.events.length, 2);
  assert.deepEqual(small.calls.flatMap((x) => x.body.events.map((e) => e.event_id)), eagerIds);

  const large = fakeFetch();
  const capped = client(large.impl, { batchSize: 10_000, queueLimit: 10_000 });
  for (let i = 0; i < 501; i++) capped.track("a");
  await capped.flush();
  assert.equal(large.calls[0].body.events.length, 500);
  assert.equal(large.calls[1].body.events.length, 1);
});

test("gövde 900 KB ile bölünür; sınırı tek başına aşan olay atılır", async () => {
  const { impl, calls } = fakeFetch();
  const c = client(impl);
  c.track("a", { blob: "x".repeat(500 * 1024) });
  c.track("b", { blob: "x".repeat(500 * 1024) });
  assert.equal(c.track("c", { blob: "x".repeat(1024 * 1024) }), null);
  await c.flush();
  assert.equal(calls.length, 2);
  for (const call of calls) assert.ok(Buffer.byteLength(call.init.body) < 1024 * 1024);
});

test("istek sürerken izin geri çekilirse batch yeniden denenmez", async () => {
  let release;
  const c = client(() => new Promise((resolve) => { release = () => resolve(new Response("", { status: 503 })); }));
  c.track("a");
  const pending = c.flush();
  c.setConsent({ analytics: false });
  release();
  const result = await pending;
  assert.equal(result.retained, 0);
  assert.equal(c.getStatus().queued, 0);
});

test("close kalanı gönderir, sonra olay üretilmez; ikinci çağrı güvenli; zaman aşımı beklemez", async () => {
  const { impl, calls } = fakeFetch();
  const c = client(impl);
  c.track("a");
  assert.equal((await c.close()).status, 202);
  assert.equal(calls.length, 1);
  assert.equal(c.track("b"), null);
  assert.equal((await c.close()).sent, 0);

  const hanging = client(() => new Promise(() => {}));
  hanging.track("a");
  const result = await hanging.close(20);
  assert.equal(result.retained, 1);
});

test("arka plan göndericisi kuyruğu boşaltır", async () => {
  const { impl, calls } = fakeFetch();
  const c = client(impl, { flushIntervalMs: 5 });
  c.track("a");
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.equal(calls.length, 1);
  await c.close();
});

test("sır loglanmaz: anahtar, özellik değeri ve kimlik log alanlarına girmez", async () => {
  const lines = [];
  const log = (m, f) => lines.push(`${m} ${JSON.stringify(f ?? {})}`);
  const { impl } = fakeFetch([{ status: 401, body: { title: "Geçersiz" } }, new Error("ağ"), { status: 500 }]);
  const c = client(impl, { logger: { debug: log, warn: log } });
  c.identify("kullanici_gizli");
  c.track("a", { deger: "ozellik_gizli" });
  await c.flush();
  c.track("b", { deger: "ozellik_gizli" });
  await c.flush();
  await c.flush();
  const output = lines.join("\n");
  assert.ok(lines.length > 0);
  for (const secret of [KEY, "ozellik_gizli", "kullanici_gizli"]) assert.ok(!output.includes(secret), secret);
  assert.ok(!JSON.stringify(c.getStatus()).includes(KEY));
});

test("logger hatası ve fetch'in eşzamanlı fırlatması uygulamaya yansımaz", async () => {
  const c = client(() => { throw new Error("patladı"); }, { logger: { warn: () => { throw new Error("logger"); }, debug: () => { throw new Error("logger"); } } });
  assert.equal(c.track("Geçersiz Ad"), null);
});

test("trackRevenue: feralin_purchase sözleşmesi; verified düşer, geçersiz girdi olay üretmez, şemaya uyar", async () => {
  const { impl, calls } = fakeFetch();
  const c = client(impl);
  const e = c.trackRevenue({ transactionId: "ord_1", amountMinor: 4999, currency: "TRY", productId: "pro", purchaseType: "subscription_start", receipt: { provider: "stripe", token: "tok_1" }, properties: { verified: true, receipt_digest: "x", plan: "pro" } }, { userId: "user_42" });
  assert.equal(e.event_name, "feralin_purchase");
  assert.equal(e.user_id, "user_42");
  assert.equal(e.properties.transaction_id, "ord_1");
  assert.equal(e.properties.amount_minor, 4999);
  assert.equal(e.properties.purchase_type, "subscription_start");
  assert.deepEqual(e.properties.receipt, { provider: "stripe", token: "tok_1" });
  assert.equal(e.properties.plan, "pro");
  assert.equal("verified" in e.properties, false);
  assert.equal("receipt_digest" in e.properties, false);
  assert.equal("verified" in e, false);
  await c.flush();
  assert.equal(validateBatch(calls[0].body), true, JSON.stringify(validateBatch.errors));
  for (const bad of [
    { transactionId: "", amountMinor: 1, currency: "TRY" },
    { transactionId: "t", amountMinor: 49.99, currency: "TRY" },
    { transactionId: "t", amountMinor: -1, currency: "TRY" },
    { transactionId: "t", amountMinor: 1, currency: "try" },
    { transactionId: "t", amountMinor: 1, currency: "TRY", quantity: 1.5 },
    { transactionId: "t", amountMinor: 1, currency: "TRY", purchaseType: "gift" },
    { transactionId: "t", amountMinor: 1, currency: "TRY", receipt: { provider: "paypal", token: "x" } },
    { transactionId: "t", amountMinor: 1, currency: "TRY", purchaseType: "subscription_cancel" },
  ]) {
    assert.equal(c.trackRevenue(bad), null, JSON.stringify(bad));
  }
  assert.equal(c.trackRevenue({ transactionId: "t", amountMinor: 0, currency: "TRY", purchaseType: "subscription_cancel" }).properties.purchase_type, "subscription_cancel");
  // Sıfır tutarlı iptal kuyruğa girdi; geçersiz girdiler girmedi.
  assert.equal(c.getStatus().queued, 1);
});
