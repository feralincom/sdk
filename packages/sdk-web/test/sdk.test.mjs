// SDK birim testleri: consent kapısı, idempotent batch, 202 ack, 5xx kuyrukta kalma, 400 atma, şema uyumu,
// izinsiz gönderim/depolama yokluğu, autoTrack, içerik özetli idempotency anahtarı, URL temizliği.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { gzipSync } from "node:zlib";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
execFileSync(process.execPath, [join(root, "scripts/build.mjs")], { stdio: "pipe" });
const sdk = await import(join(root, "dist/feralin.mjs").replace(/\\/g, "/").replace(/^([A-Za-z]):/, "file:///$1:"));

const schemasRoot = join(root, "../schemas/utp/v1");
const ajv = new Ajv2020({ strict: true, allErrors: true }); addFormats(ajv);
ajv.addSchema(JSON.parse(readFileSync(join(schemasRoot, "event.schema.json"), "utf8")));
const validateBatch = ajv.compile(JSON.parse(readFileSync(join(schemasRoot, "batch.schema.json"), "utf8")));

function fakeFetch(status, body = { batch_id: "01TEST", accepted: 1, rejected: 0 }) {
  const calls = [];
  const f = async (url, init) => { calls.push({ url, init }); return { status, json: async () => body }; };
  return { f, calls };
}
const mem = () => { const m = new Map(); return { get: (k) => m.get(k) ?? null, set: (k, v) => m.set(k, v), remove: (k) => m.delete(k) }; };

test("consent yokken olay üretilmez", () => {
  const c = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", fetch: fakeFetch(202).f, storage: mem(), flushIntervalMs: 0 });
  assert.equal(c.track("page_view"), null);
  assert.equal(c.getStatus().queued, 0);
});

test("gizli anahtar reddedilir", () => {
  assert.throws(() => new sdk.Feralin({ projectKey: "sk_live_x", collectUrl: "http://c", flushIntervalMs: 0, storage: mem() }));
});

test("olay UTP v1 şemasına uyar ve 202 ile kuyruktan düşer", async () => {
  const { f, calls } = fakeFetch(202);
  const c = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c/", consent: { analytics: true }, fetch: f, storage: mem(), flushIntervalMs: 0 });
  const e = c.track("signup_completed", { plan: "growth", "bad key": 1 });
  assert.ok(e && !("bad key" in (e.properties ?? {})));
  const r = await c.flush();
  assert.equal(r.status, 202);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "http://c/v1/batch");
  assert.equal(calls[0].init.headers["x-feralin-project-key"], "pk_test_abc");
  assert.ok(calls[0].init.headers["idempotency-key"].length >= 8);
  const body = JSON.parse(calls[0].init.body);
  assert.equal(validateBatch(body), true, JSON.stringify(validateBatch.errors));
  assert.equal(c.getStatus().queued, 0);
});

test("5xx'te olaylar kuyrukta kalır, aynı idempotency key ile tekrar denenir", async () => {
  const { f, calls } = fakeFetch(503, {});
  const c = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, fetch: f, storage: mem(), flushIntervalMs: 0 });
  c.track("page_view");
  await c.flush(); await c.flush();
  assert.equal(c.getStatus().queued, 1);
  assert.equal(calls[0].init.headers["idempotency-key"], calls[1].init.headers["idempotency-key"]);
});

test("400'de olaylar atılır (sonsuz tekrar yok)", async () => {
  const c = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, fetch: fakeFetch(400, {}).f, storage: mem(), flushIntervalMs: 0 });
  c.track("page_view");
  const r = await c.flush();
  assert.equal(r.status, 400);
  assert.equal(c.getStatus().queued, 0);
});

test("kuyruk depolamada kalıcı; reset anonim kimliği yeniler", async () => {
  const s = mem();
  const a = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, fetch: fakeFetch(503, {}).f, storage: s, flushIntervalMs: 0 });
  a.track("page_view");
  const b = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, fetch: fakeFetch(202).f, storage: s, flushIntervalMs: 0 });
  assert.equal(b.getStatus().queued, 1);
  const aid = b.getStatus().anonymous_id; b.reset();
  assert.notEqual(b.getStatus().anonymous_id, aid);
});

test("ULID 26 karakter ve zaman sıralı", () => {
  const ids = Array.from({ length: 50 }, () => sdk.initialize({ projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, fetch: fakeFetch(202).f, storage: mem(), flushIntervalMs: 0 }).track("page_view").event_id);
  for (const id of ids) assert.match(id, /^[0-9A-HJKMNP-TV-Z]{26}$/);
  assert.deepEqual([...ids].sort(), ids);
});

// ---- yardımcılar ----

const OPTS = { projectKey: "pk_test_abc", collectUrl: "http://c", flushIntervalMs: 0 };
const QUEUE_KEY = "fr_q_pk_test_abc";
const spyStorage = () => {
  const m = new Map(); const writes = [];
  return { writes, map: m, get: (k) => m.get(k) ?? null, set: (k, v) => { writes.push(k); m.set(k, v); }, remove: (k) => m.delete(k) };
};
const storedEvent = (id = "01JBX5Z8K3Q9R7T2V4W6Y8A0BC") => ({ event_id: id, event_name: "page_view", occurred_at: new Date().toISOString(), platform: "web", schema_version: 1, consent: { analytics: true } });
const eventsOf = (call) => JSON.parse(call.init.body).events;

/** Tarayıcı globallerini test süresince taklit eder (jsdom bağımlılığı eklememek için). */
function withBrowser(t, href = "https://site.example/p", referrer = "") {
  const saved = {};
  const registry = [];
  const on = (type, listener) => { registry.push({ type, listener }); };
  const off = (type, listener) => {
    const at = registry.findIndex((item) => item.type === type && item.listener === listener);
    if (at >= 0) registry.splice(at, 1);
  };
  const fake = {
    window: { addEventListener: on, removeEventListener: off, innerWidth: 800, innerHeight: 600 },
    document: { title: "Başlık", referrer, visibilityState: "visible", addEventListener: on, removeEventListener: off },
    location: { href },
  };
  for (const [k, v] of Object.entries(fake)) {
    saved[k] = Object.getOwnPropertyDescriptor(globalThis, k);
    Object.defineProperty(globalThis, k, { value: v, configurable: true, writable: true });
  }
  t.after(() => {
    for (const k of Object.keys(fake)) {
      if (saved[k]) Object.defineProperty(globalThis, k, saved[k]);
      else delete globalThis[k];
    }
  });
  return {
    registry,
    /** Sekme gizlenir ve sayfa kapanır; kayıtlı dinleyicilerin hepsi koşar. */
    hide() {
      fake.document.visibilityState = "hidden";
      for (const { listener } of [...registry]) listener();
    },
  };
}

/** Referans FNV-1a 64; SDK'dan bağımsız yazılmıştır ve bilinen vektörlerle doğrulanır. */
function refFnv(text) {
  let h = 0xcbf29ce484222325n;
  for (let i = 0; i < text.length; i++) h = BigInt.asUintN(64, (h ^ BigInt(text.charCodeAt(i))) * 0x100000001b3n);
  return h.toString(16).padStart(16, "0");
}

// ---- madde 7: izinsiz gönderim ----

test("izin geri çekilince flush göndermez ve kuyruğu temizler", async () => {
  const { f, calls } = fakeFetch(202);
  const s = spyStorage();
  const c = new sdk.Feralin({ ...OPTS, consent: { analytics: true }, fetch: f, storage: s });
  c.track("page_view");
  c.consent = { analytics: false }; // setConsent dışından değişse bile kapı flush'ta da uygulanır
  const r = await c.flush();
  assert.equal(r.status, 0);
  assert.equal(calls.length, 0);
  assert.equal(c.getStatus().queued, 0);
  assert.equal(s.map.has(QUEUE_KEY), false);
});

test("açık analytics=false ile açılınca depodaki eski kuyruk gönderilmez ve silinir", async () => {
  const { f, calls } = fakeFetch(202);
  const s = spyStorage();
  s.map.set(QUEUE_KEY, JSON.stringify([storedEvent()]));
  const c = new sdk.Feralin({ ...OPTS, consent: { analytics: false }, fetch: f, storage: s });
  await c.flush();
  assert.equal(calls.length, 0);
  assert.equal(c.getStatus().queued, 0);
  assert.equal(s.map.has(QUEUE_KEY), false);
});

test("izin bildirilmeden depodaki kuyruk bekletilir, izin verilince gönderilir", async () => {
  const { f, calls } = fakeFetch(202);
  const s = spyStorage();
  s.map.set(QUEUE_KEY, JSON.stringify([storedEvent()]));
  const c = new sdk.Feralin({ ...OPTS, fetch: f, storage: s });
  await c.flush(); await c.flush();
  assert.equal(calls.length, 0, "izin gelmeden gönderilmemeli");
  assert.equal(c.getStatus().queued, 1, "izin bildirilmeden silinmemeli");
  c.setConsent({ analytics: true });
  const r = await c.flush();
  assert.equal(r.status, 202);
  assert.equal(calls.length, 1);
  assert.equal(eventsOf(calls[0])[0].event_id, "01JBX5Z8K3Q9R7T2V4W6Y8A0BC");
  assert.equal(c.getStatus().queued, 0);
});

test("izin reddi bildirilince bekleyen kuyruk silinir", async () => {
  const { f, calls } = fakeFetch(202);
  const s = spyStorage();
  s.map.set(QUEUE_KEY, JSON.stringify([storedEvent()]));
  const c = new sdk.Feralin({ ...OPTS, fetch: f, storage: s });
  c.setConsent({ analytics: false });
  c.setConsent({ analytics: true });
  await c.flush();
  assert.equal(calls.length, 0);
});

// ---- madde 8: fr_aid ----

test("fr_aid izin verilmeden depoya yazılmaz, izin verilince aynı kimlik yazılır", () => {
  const s = spyStorage();
  const c = new sdk.Feralin({ ...OPTS, fetch: fakeFetch(202).f, storage: s });
  const id = c.getStatus().anonymous_id;
  assert.match(id, /^[0-9A-HJKMNP-TV-Z]{26}$/);
  c.track("page_view"); c.reset();
  assert.deepEqual(s.writes, [], "izinsiz hiçbir anahtar yazılmamalı");
  const current = c.getStatus().anonymous_id;
  c.setConsent({ analytics: true });
  assert.equal(s.map.get("fr_aid"), current);
  assert.equal(c.getStatus().anonymous_id, current);
});

test("izin başta varsa fr_aid yazılır; yeniden açılışta aynı kimlik okunur", () => {
  const s = spyStorage();
  const a = new sdk.Feralin({ ...OPTS, consent: { analytics: true }, fetch: fakeFetch(202).f, storage: s });
  assert.equal(s.map.get("fr_aid"), a.getStatus().anonymous_id);
  const b = new sdk.Feralin({ ...OPTS, consent: { analytics: true }, fetch: fakeFetch(202).f, storage: s });
  assert.equal(b.getStatus().anonymous_id, a.getStatus().anonymous_id);
});

test("izin geri çekilince fr_aid silinir; reset izinsiz kimlik yazmaz", () => {
  const s = spyStorage();
  const c = new sdk.Feralin({ ...OPTS, consent: { analytics: true }, fetch: fakeFetch(202).f, storage: s });
  c.setConsent({ analytics: false });
  assert.equal(s.map.has("fr_aid"), false);
  c.reset();
  assert.equal(s.map.has("fr_aid"), false);
});

test("önceki oturumun kimliği izin gelmeden silinmez; izin gelince korunur", () => {
  const s = spyStorage();
  s.map.set("fr_aid", "01JBX5Z8K3Q9R7T2V4W6Y8ESKI");
  const c = new sdk.Feralin({ ...OPTS, consent: { analytics: false }, fetch: fakeFetch(202).f, storage: s });
  assert.equal(s.map.get("fr_aid"), "01JBX5Z8K3Q9R7T2V4W6Y8ESKI");
  assert.deepEqual(s.writes, []);
  c.setConsent({ analytics: true });
  assert.equal(c.getStatus().anonymous_id, "01JBX5Z8K3Q9R7T2V4W6Y8ESKI");
});

// ---- madde 9: autoTrack ----

test("autoTrack: izin sonradan gelince page_view bir kez üretilir", (t) => {
  withBrowser(t);
  const c = new sdk.Feralin({ ...OPTS, fetch: fakeFetch(202).f, storage: spyStorage() });
  assert.equal(c.getStatus().queued, 0);
  c.setConsent({ analytics: true });
  assert.equal(c.getStatus().queued, 1);
  c.setConsent({ analytics: true });
  c.setConsent({ analytics: false });
  c.setConsent({ analytics: true });
  assert.equal(c.getStatus().queued, 0, "geri çekilen izin kuyruğu boşalttı; aynı sayfada yeniden üretilmemeli");
});

test("autoTrack: izin başta varsa çift üretilmez", (t) => {
  withBrowser(t);
  const c = new sdk.Feralin({ ...OPTS, consent: { analytics: true }, fetch: fakeFetch(202).f, storage: spyStorage() });
  assert.equal(c.getStatus().queued, 1);
  c.setConsent({ analytics: true, advertising: true });
  assert.equal(c.getStatus().queued, 1);
});

test("autoTrack kapalıyken izin gelince page_view üretilmez", (t) => {
  withBrowser(t);
  const c = new sdk.Feralin({ ...OPTS, autoTrack: false, fetch: fakeFetch(202).f, storage: spyStorage() });
  c.setConsent({ analytics: true });
  assert.equal(c.getStatus().queued, 0);
});

// ---- madde 10: idempotency anahtarı ----

test("referans FNV-1a 64 bilinen vektörlerle uyuşur", () => {
  assert.equal(refFnv(""), "cbf29ce484222325");
  assert.equal(refFnv("a"), "af63dc4c8601ec8c");
  assert.equal(refFnv("foobar"), "85944171f73967e8");
});

test("idempotency anahtarı tüm event_id'lerin özeti ve adettir", async () => {
  const { f, calls } = fakeFetch(202);
  const s = spyStorage();
  s.map.set(QUEUE_KEY, JSON.stringify([storedEvent("01JBX5Z8K3Q9R7T2V4W6Y8A0B2"), storedEvent("01JBX5Z8K3Q9R7T2V4W6Y8A0B1")]));
  const c = new sdk.Feralin({ ...OPTS, consent: { analytics: true }, fetch: f, storage: s });
  await c.flush();
  const key = calls[0].init.headers["idempotency-key"];
  assert.equal(key, `${refFnv("01JBX5Z8K3Q9R7T2V4W6Y8A0B1,01JBX5Z8K3Q9R7T2V4W6Y8A0B2")}-2`);
  assert.match(key, /^[\x21-\x7E]{8,128}$/, "sunucunun anahtar desenine uymalı");
});

async function keyFor(ids) {
  const { f, calls } = fakeFetch(202);
  const s = spyStorage();
  s.map.set(QUEUE_KEY, JSON.stringify(ids.map((id) => storedEvent(id))));
  await new sdk.Feralin({ ...OPTS, consent: { analytics: true }, fetch: f, storage: s }).flush();
  return calls[0].init.headers["idempotency-key"];
}

test("iki sekme: ilk olayı ve adedi aynı, içeriği farklı batch'ler farklı anahtar alır", async () => {
  const first = "01JBX5Z8K3Q9R7T2V4W6Y8A0B1";
  const tabA = await keyFor([first, "01JBX5Z8K3Q9R7T2V4W6Y8AAAA"]);
  const tabB = await keyFor([first, "01JBX5Z8K3Q9R7T2V4W6Y8BBBB"]);
  assert.notEqual(tabA, tabB);
  assert.notEqual(tabA.split("-")[0], tabB.split("-")[0]);
});

test("aynı içerik aynı anahtarı üretir (sıradan bağımsız)", async () => {
  const a = await keyFor(["01JBX5Z8K3Q9R7T2V4W6Y8A0B1", "01JBX5Z8K3Q9R7T2V4W6Y8A0B2"]);
  const b = await keyFor(["01JBX5Z8K3Q9R7T2V4W6Y8A0B2", "01JBX5Z8K3Q9R7T2V4W6Y8A0B1"]);
  assert.equal(a, b);
});

// ---- madde 11: URL temizliği ----

test("page_url ve referrer temizlenir, utm_* properties'e taşınır, şemaya uyar", async (t) => {
  withBrowser(t, "https://kisi:parola@site.example:8443/yol?token=GIZLI123&utm_source=google&utm_medium=cpc&utm_campaign=yaz&utm_term=t&utm_content=c&utm_id=GIZLI2#GIZLI3", "https://ref.example/a?sid=GIZLI4#x");
  const { f, calls } = fakeFetch(202);
  const c = new sdk.Feralin({ ...OPTS, consent: { analytics: true }, autoTrack: false, fetch: f, storage: spyStorage() });
  const e = c.track("signup_completed", { plan: "pro", utm_source: "acik" });
  assert.equal(e.context.page_url, "https://site.example:8443/yol");
  assert.equal(e.context.referrer, "https://ref.example");
  assert.deepEqual(e.properties, { plan: "pro", utm_source: "acik", utm_medium: "cpc", utm_campaign: "yaz", utm_term: "t", utm_content: "c" });
  await c.flush();
  const body = calls[0].init.body;
  assert.equal(body.includes("GIZLI"), false, "sorgu dizgisi gönderilmemeli: " + body);
  assert.equal(validateBatch(JSON.parse(body)), true, JSON.stringify(validateBatch.errors));
});

test("utm yoksa properties eklenmez; boş referrer boş kalır", (t) => {
  withBrowser(t, "https://site.example/?a=1");
  const c = new sdk.Feralin({ ...OPTS, consent: { analytics: true }, autoTrack: false, fetch: fakeFetch(202).f, storage: spyStorage() });
  const e = c.track("page_view");
  assert.equal(e.properties, undefined);
  assert.equal(e.context.page_url, "https://site.example/");
  assert.equal(e.context.referrer, "");
});

test("hostsuz sayfa adresi page_url göndermez; batch şemaya uyar", async (t) => {
  withBrowser(t, "about:blank", "bozuk referrer");
  const { f, calls } = fakeFetch(202);
  const c = new sdk.Feralin({ ...OPTS, consent: { analytics: true }, autoTrack: false, fetch: f, storage: spyStorage() });
  const e = c.track("page_view");
  assert.equal("page_url" in e.context, false);
  assert.equal(e.context.referrer, "");
  await c.flush();
  assert.equal(validateBatch(JSON.parse(calls[0].init.body)), true, JSON.stringify(validateBatch.errors));
});

test("utm eklenince şemanın 100 özellik sınırı aşılmaz", async (t) => {
  withBrowser(t, "https://site.example/?utm_source=google");
  const { f, calls } = fakeFetch(202);
  const c = new sdk.Feralin({ ...OPTS, consent: { analytics: true }, autoTrack: false, fetch: f, storage: spyStorage() });
  const many = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`k${i}`, i]));
  const e = c.track("page_view", many);
  assert.equal(Object.keys(e.properties).length, 100);
  await c.flush();
  assert.equal(validateBatch(JSON.parse(calls[0].init.body)), true, JSON.stringify(validateBatch.errors));
});

// ---- madde 12: boyut bütçesi ----

test("IIFE gzip 8 KB bütçesinde", () => {
  const gz = gzipSync(readFileSync(join(root, "dist/feralin.iife.js"))).length;
  assert.ok(gz <= 8 * 1024, `gzip ${gz} B`);
});


// --- Oturum sürekliliği (FAZ_DENETIMI madde 35): çok sayfalı sitede her sayfa yüklemesi yeni oturum sayılmaz. ---

/** Saati ileri alır; SDK oturum süresini Date.now ile ölçer. */
function withClock(run) {
  const real = Date.now;
  let offset = 0;
  Date.now = () => real() + offset;
  try { return run((ms) => { offset += ms; }); } finally { Date.now = real; }
}
const sessionClient = (storage, consent = { analytics: true }) => new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", ...(consent ? { consent } : {}), fetch: fakeFetch(202).f, storage, flushIntervalMs: 0 });

test("oturum sayfa yüklemeleri arasında sürer: aynı depoyu paylaşan iki örnek aynı session_id ile olay üretir", () => {
  const storage = mem();
  const first = sessionClient(storage);
  const a = first.track("page_view");
  // İkinci sayfa yüklemesi: yeni SDK örneği, aynı tarayıcı deposu.
  const second = sessionClient(storage);
  const b = second.track("page_view");
  assert.equal(b.session_id, a.session_id);
  assert.equal(second.getStatus().session_id, a.session_id);
  assert.match(storage.get("fr_sid"), /^[0-9A-Z]{26}\.\d{10,16}$/);
  // Kimlik de aynıdır; oturum kimliği anonim kimlikten farklı bir değerdir.
  assert.equal(b.anonymous_id, a.anonymous_id);
  assert.notEqual(a.session_id, a.anonymous_id);
});

test("30 dakika hareketsizlikten sonraki ilk olay yeni oturum başlatır; süre içindeki olay oturumu uzatır", () => {
  withClock((advance) => {
    const storage = mem();
    const c = sessionClient(storage);
    const a = c.track("page_view");
    advance(29 * 60_000);
    const b = c.track("page_view");
    assert.equal(b.session_id, a.session_id);
    // Son olaydan 29 dakika sonra: oturum uzadığı için hâlâ aynı.
    advance(29 * 60_000);
    assert.equal(c.track("page_view").session_id, a.session_id);
    advance(sdk.SESSION_IDLE_MS + 1);
    const later = c.track("page_view");
    assert.notEqual(later.session_id, a.session_id);
    // Yeni sayfa yüklemesi de yeni oturuma katılır, eskisine dönmez.
    assert.equal(sessionClient(storage).track("page_view").session_id, later.session_id);
  });
});

test("izin yokken oturum depoya yazılmaz ve depodan okunmaz; izin gelince yazılır, geri çekilince silinir", () => {
  const storage = mem();
  const prior = sessionClient(storage);
  const known = prior.track("page_view").session_id;
  // İzinsiz örnek depodaki oturuma katılmaz ve olay üretmez.
  const denied = sessionClient(storage, { analytics: false });
  assert.notEqual(denied.getStatus().session_id, known);
  assert.equal(denied.track("page_view"), null);
  denied.setConsent({ analytics: false });
  assert.equal(storage.get("fr_sid"), null);
  // İzin bildirilmemiş örnek de yazmaz.
  const empty = mem();
  const pending = sessionClient(empty, null);
  assert.equal(empty.get("fr_sid"), null);
  pending.setConsent({ analytics: true });
  assert.match(empty.get("fr_sid"), /^[0-9A-Z]{26}\.\d{10,16}$/);
  assert.equal(pending.track("page_view").session_id, empty.get("fr_sid").split(".")[0]);
  pending.optOut();
  assert.equal(empty.get("fr_sid"), null);
});

test("reset yeni oturum başlatır; bozuk ya da eski depo değeri yok sayılır; depolama hata verirse izleme sürer", () => {
  const storage = mem();
  const c = sessionClient(storage);
  const before = c.track("page_view").session_id;
  c.reset();
  assert.notEqual(c.track("page_view").session_id, before);
  for (const bad of ["degil", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "01ARZ3NDEKTSV4RRFFQ69G5FAV.abc", "<script>.1793870000000", `01ARZ3NDEKTSV4RRFFQ69G5FAV.${Date.now() - sdk.SESSION_IDLE_MS - 1}`]) {
    const dirty = mem();
    dirty.set("fr_sid", bad);
    const fresh = sessionClient(dirty).track("page_view");
    assert.notEqual(fresh.session_id, "01ARZ3NDEKTSV4RRFFQ69G5FAV", bad);
    assert.match(fresh.session_id, /^[0-9A-Z]{26}$/);
  }
  const broken = { get() { throw new Error("kapalı"); }, set() { throw new Error("kapalı"); }, remove() { throw new Error("kapalı"); } };
  const offline = sessionClient(broken);
  const one = offline.track("page_view");
  const two = offline.track("page_view");
  assert.ok(one && two);
  assert.equal(one.session_id, two.session_id);
});

test("alındı kanıtı: track olayın event_id'sini, flush toplayıcının trace_id ve batch_id'sini döndürür", async () => {
  const { f, calls } = fakeFetch(202, { batch_id: "01BATCH", trace_id: "trace-abc-123", accepted: 1, rejected: 0 });
  const c = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, fetch: f, storage: mem(), flushIntervalMs: 0, autoTrack: false });
  const e = c.track("sdk_verify");
  assert.match(e.event_id, /^[0-9A-Za-z-]{16,64}$/);
  const r = await c.flush();
  assert.deepEqual({ status: r.status, batch_id: r.batch_id, trace_id: r.trace_id, accepted: r.accepted }, { status: 202, batch_id: "01BATCH", trace_id: "trace-abc-123", accepted: 1 });
  // Gönderilen gövdedeki olay, track'in döndürdüğü kimliği taşır: doğrulama bu kimlikle yapılır.
  assert.deepEqual(JSON.parse(calls[0].init.body).events.map((x) => x.event_id), [e.event_id]);
  // Toplayıcı iz kimliği döndürmezse alan uydurulmaz.
  const bare = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, fetch: fakeFetch(202, { batch_id: "01B", accepted: 1, rejected: 0 }).f, storage: mem(), flushIntervalMs: 0, autoTrack: false });
  bare.track("sdk_verify");
  assert.equal((await bare.flush()).trace_id, undefined);
});

// ---- Dayanıklılık sözleşmesi (capability-matrix §3) ----

const RETRY_OPTS = { projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, storage: mem(), flushIntervalMs: 0, autoTrack: false };

test("yanıt kaybolunca batch sabitlenir: araya giren olay anahtarı değiştirmez ve ayrı batch'te gider", async () => {
  const calls = [];
  let lose = true;
  const f = async (_url, init) => {
    calls.push(init);
    if (lose) { lose = false; throw new Error("yanıt kayboldu"); }
    return { status: 202, json: async () => ({ accepted: 1, rejected: 0 }) };
  };
  const c = new sdk.Feralin({ ...RETRY_OPTS, storage: mem(), fetch: f });
  const first = c.track("order_shipped");
  assert.equal((await c.flush()).status, 0);
  const next = c.track("order_refunded");
  assert.equal((await c.flush()).status, 202);
  assert.equal(calls[0].headers["idempotency-key"], calls[1].headers["idempotency-key"]);
  assert.deepEqual(JSON.parse(calls[1].body).events.map((e) => e.event_id), [first.event_id]);
  assert.equal((await c.flush()).status, 202);
  assert.deepEqual(JSON.parse(calls[2].body).events.map((e) => e.event_id), [next.event_id]);
  assert.equal(c.getStatus().queued, 0);
});

test("izin istek sürerken geri çekilirse başarısız batch yeniden sabitlenmez, gönderilmez", async () => {
  const calls = [];
  let fail;
  const f = (_url, init) => { calls.push(init); return new Promise((_resolve, reject) => { fail = reject; }); };
  const c = new sdk.Feralin({ ...RETRY_OPTS, storage: mem(), fetch: f });
  c.track("order_shipped");
  const pending = c.flush();
  c.setConsent({ analytics: false });
  fail(new Error("ağ"));
  await pending;
  c.setConsent({ analytics: true });
  assert.equal((await c.flush()).status, 0);
  assert.equal(calls.length, 1);
  assert.equal(c.getStatus().queued, 0);
});

test("arka plan gönderimi geçici hatadan sonra geri çekilir; açık flush beklemez, başarı sıfırlar", async () => {
  const calls = [];
  let status = 503;
  const f = async (_url, init) => { calls.push(init); return { status, headers: { get: () => null }, json: async () => ({}) }; };
  const c = new sdk.Feralin({ ...RETRY_OPTS, storage: mem(), fetch: f, flushIntervalMs: 5 });
  c.track("page_view");
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(calls.length, 1, "en az 500 ms geçmeden yeniden deneme olmamalı");
  status = 202;
  assert.equal((await c.flush()).status, 202);
  assert.equal(calls.length, 2);
  c.destroy();
});

test("Retry-After yarım jitter'ın altına düşürülmez", async () => {
  const f = async () => ({ status: 429, headers: { get: (name) => (name === "retry-after" ? "120" : null) }, json: async () => ({}) });
  const c = new sdk.Feralin({ ...RETRY_OPTS, storage: mem(), fetch: f });
  c.track("page_view");
  const before = Date.now();
  await c.flush();
  assert.ok(c.notBefore - before >= 120_000);
  assert.ok(c.notBefore - before <= 121_000);
});

// ---- destroy: yok edilen örnek hiçbir şey göndermez ve depoya yazmaz ----

const LIFE_OPTS = { ...OPTS, autoTrack: false, consent: { analytics: true } };

test("destroy dinleyicileri kaldırır: sekme gizlenince eski örnek göndermez", async (t) => {
  const browser = withBrowser(t);
  const { f, calls } = fakeFetch(202);
  const c = new sdk.Feralin({ ...LIFE_OPTS, fetch: f, storage: spyStorage() });
  assert.equal(browser.registry.length, 2);
  c.track("order_shipped");
  c.destroy();
  assert.equal(browser.registry.length, 0, "pagehide ve visibilitychange kalmamalı");
  browser.hide();
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(calls.length, 0);
  c.destroy();
});

test("yeniden initialize: yeni örnekte optOut sonrası eski örnek göndermez, silinen kuyruğu yeniden yazmaz", async (t) => {
  const browser = withBrowser(t);
  const storage = spyStorage();
  const oldFetch = fakeFetch(202);
  const old = sdk.initialize({ ...LIFE_OPTS, fetch: oldFetch.f, storage });
  old.track("order_shipped");
  const next = sdk.initialize({ ...LIFE_OPTS, fetch: fakeFetch(202).f, storage });
  next.optOut();
  assert.equal(storage.map.has(QUEUE_KEY), false);
  browser.hide();
  await old.flush();
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(oldFetch.calls.length, 0, "eski izinle gönderim olmamalı");
  assert.equal(storage.map.has(QUEUE_KEY), false, "eski örnek kuyruğu geri yazmamalı");
  assert.equal(storage.map.has("fr_aid"), false);
});

test("istek sürerken destroy: yanıt gelince ack depoya yazmaz, yeni örneğin silişini geri almaz", async () => {
  for (const finish of [(res, _rej) => res({ status: 202, json: async () => ({ accepted: 2, rejected: 0 }) }), (res, _rej) => res({ status: 400, json: async () => ({}) }), (_res, rej) => rej(new Error("ağ"))]) {
    const storage = spyStorage();
    let resolveFetch; let rejectFetch;
    const f = () => new Promise((resolve, reject) => { resolveFetch = resolve; rejectFetch = reject; });
    const old = new sdk.Feralin({ ...LIFE_OPTS, fetch: f, storage });
    old.track("order_shipped");
    const pending = old.flush();
    // Yanıt gelince ack bu olayı bellekten depoya geri yazardı.
    old.track("order_refunded");
    old.destroy();
    const next = new sdk.Feralin({ ...LIFE_OPTS, fetch: fakeFetch(202).f, storage });
    next.optOut();
    storage.writes.length = 0;
    finish(resolveFetch, rejectFetch);
    await pending;
    assert.equal(storage.map.has(QUEUE_KEY), false, "süren istek biterken kuyruk geri yazılmamalı");
    assert.deepEqual(storage.writes, []);
  }
});

test("istek sürerken destroy: yanıt kuyruğu daraltmaz, kuyruk yeni örnekte durur", async () => {
  const storage = spyStorage();
  let resolveFetch;
  const old = new sdk.Feralin({ ...LIFE_OPTS, fetch: () => new Promise((resolve) => { resolveFetch = resolve; }), storage });
  const first = old.track("order_shipped");
  const pending = old.flush();
  old.destroy();
  resolveFetch({ status: 202, json: async () => ({ accepted: 1, rejected: 0 }) });
  await pending;
  assert.deepEqual(JSON.parse(storage.map.get(QUEUE_KEY)).map((e) => e.event_id), [first.event_id], "at-least-once: tekrar event_id ile tekilleşir");
});

test("yok edilen örnek track, flush, setConsent ve reset ile ağa ve depoya dokunmaz", async () => {
  const { f, calls } = fakeFetch(202);
  const storage = spyStorage();
  const c = new sdk.Feralin({ ...LIFE_OPTS, fetch: f, storage });
  c.track("order_shipped");
  c.destroy();
  const before = new Map(storage.map);
  storage.writes.length = 0;
  assert.equal(c.track("order_refunded"), null);
  assert.equal(c.page(), null);
  assert.deepEqual(await c.flush(), { sent: 0, status: 0 });
  c.setConsent({ analytics: true, advertising: true });
  c.setConsent({ analytics: false });
  c.optOut();
  c.reset();
  await c.flush();
  assert.equal(calls.length, 0);
  assert.deepEqual(storage.writes, []);
  assert.deepEqual([...storage.map], [...before], "depo aynı kalmalı; yok etme kuyruğu silmez");
  // İzni reddedilmiş örneğin flush'ı kuyruğu siler; yok edildikten sonra ortak depodaki kuyruğa dokunmaz.
  const shared = spyStorage();
  const denied = new sdk.Feralin({ ...OPTS, autoTrack: false, consent: { analytics: false }, fetch: f, storage: shared });
  denied.destroy();
  shared.map.set(QUEUE_KEY, JSON.stringify([storedEvent()]));
  await denied.flush();
  assert.equal(shared.map.has(QUEUE_KEY), true);
});

test("destroy kuyruğu silmez: ortak depoda bellekteki son olaylar ve sabitlenmiş batch yeni örneğe geçer", async () => {
  const storage = spyStorage();
  const old = new sdk.Feralin({ ...LIFE_OPTS, fetch: fakeFetch(503, {}).f, storage });
  const pinned = old.track("order_shipped");
  await old.flush();
  const last = old.track("order_refunded");
  old.destroy();
  const { f, calls } = fakeFetch(202);
  const next = new sdk.Feralin({ ...LIFE_OPTS, fetch: f, storage });
  assert.equal(next.getStatus().queued, 2);
  assert.equal((await next.flush()).status, 202);
  assert.deepEqual(eventsOf(calls[0]).map((e) => e.event_id), [pinned.event_id, last.event_id]);
  assert.equal(storage.map.has(QUEUE_KEY), false);
  assert.equal(next.getStatus().anonymous_id, old.getStatus().anonymous_id);
});

// ---- proje anahtarı: yalnız public (pk_) ----

test("anahtar kırpılır ve pk_ öneki zorunludur", async () => {
  for (const key of [" sk_live_gizli", "\tsk_live_gizli", "SK_LIVE_gizli", "Sk_live_gizli"]) {
    assert.throws(() => new sdk.Feralin({ ...OPTS, projectKey: key, storage: mem() }), /gizli anahtar/, key);
  }
  for (const key of ["rk_live_gizli", " rk_live_gizli", "PK_LIVE_buyuk", "pk_", "pk_kisa", "anahtar", "   ", 42]) {
    assert.throws(() => new sdk.Feralin({ ...OPTS, projectKey: key, storage: mem() }), /pk_|zorunlu/, String(key));
  }
  const { f, calls } = fakeFetch(202);
  const storage = spyStorage();
  const c = new sdk.Feralin({ ...LIFE_OPTS, projectKey: "  pk_test_abc\n", fetch: f, storage });
  c.track("order_shipped");
  assert.equal(storage.map.has(QUEUE_KEY), true, "kuyruk anahtarı kırpılmış değerle aynı");
  await c.flush();
  assert.equal(calls[0].init.headers["x-feralin-project-key"], "pk_test_abc");
  assert.equal(sdk.assertProjectKey(" pk_test_abc "), "pk_test_abc");
  assert.throws(() => sdk.assertProjectKey(" sk_live_gizli"), /gizli anahtar/);
});

// ---- izin geri çekilince kimlik yenilenir ----

test("izin geri çekilip yeniden verilince eski anonim kimlik ve oturum geri gelmez", () => {
  const storage = spyStorage();
  const c = new sdk.Feralin({ ...LIFE_OPTS, fetch: fakeFetch(202).f, storage });
  const first = c.track("order_shipped");
  c.setConsent({ analytics: false });
  const withdrawn = c.getStatus();
  assert.notEqual(withdrawn.anonymous_id, first.anonymous_id, "getStatus eski kimliği göstermemeli");
  assert.notEqual(withdrawn.session_id, first.session_id);
  assert.equal(storage.map.has("fr_aid"), false);
  assert.equal(storage.map.has("fr_sid"), false);

  c.setConsent({ analytics: true });
  const second = c.track("order_shipped");
  assert.notEqual(second.anonymous_id, first.anonymous_id);
  assert.notEqual(second.session_id, first.session_id);
  assert.equal(second.anonymous_id, withdrawn.anonymous_id, "izinsiz dönemde üretilen kimlik izinle yazılır");
  assert.equal(storage.map.get("fr_aid"), second.anonymous_id);
  assert.equal(storage.map.get("fr_sid").split(".")[0], second.session_id);
  assert.equal(JSON.stringify([...storage.map.values()]).includes(first.anonymous_id), false);

  // optOut da aynı yoldur; yalnız reklam izni değişince kimlik korunur.
  c.setConsent({ analytics: true, advertising: true });
  assert.equal(c.getStatus().anonymous_id, second.anonymous_id);
  c.optOut();
  assert.notEqual(c.getStatus().anonymous_id, second.anonymous_id);
});

test("fr_click yalnız açık reklam izniyle gider", () => {
  const c = new sdk.Feralin({ ...RETRY_OPTS, storage: mem(), fetch: fakeFetch(202).f });
  assert.equal(c.track("order", { fr_click: "clk", plan: "pro" }).properties.fr_click, undefined);
  c.setConsent({ analytics: true, advertising: false });
  assert.equal(c.track("order", { fr_click: "clk", plan: "pro" }).properties.fr_click, undefined);
  c.setConsent({ analytics: true, advertising: true });
  assert.equal(c.track("order", { fr_click: "clk" }).properties.fr_click, "clk");
});

test("trackRevenue: feralin_purchase sözleşmesi; verified düşer, geçersiz girdi olay üretmez, şemaya uyar", async () => {
  const { f, calls } = fakeFetch(202);
  const c = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, fetch: f, storage: mem(), flushIntervalMs: 0 });
  const e = c.trackRevenue({ transactionId: "ord_1", amountMinor: 4999, currency: "TRY", productId: "pro", receipt: { provider: "stripe", token: "tok_1" }, properties: { verified: true, receipt_digest: "x", plan: "pro" } });
  assert.equal(e.event_name, sdk.REVENUE_EVENT_NAME);
  assert.equal(e.properties.transaction_id, "ord_1");
  assert.equal(e.properties.amount_minor, 4999);
  assert.equal(e.properties.currency, "TRY");
  assert.equal(e.properties.quantity, 1);
  assert.equal(e.properties.purchase_type, "purchase");
  assert.deepEqual(e.properties.receipt, { provider: "stripe", token: "tok_1" });
  assert.equal(e.properties.plan, "pro");
  assert.equal("verified" in e.properties, false);
  assert.equal("receipt_digest" in e.properties, false);
  assert.equal("verified" in e, false);
  // Abonelik iptali tutar taşımaz; sıfır tutarlı iptal geçerlidir.
  assert.equal(c.trackRevenue({ transactionId: "sub_1", amountMinor: 0, currency: "TRY", purchaseType: "subscription_cancel" }).properties.purchase_type, "subscription_cancel");
  await c.flush();
  assert.equal(validateBatch(JSON.parse(calls[0].init.body)), true, JSON.stringify(validateBatch.errors));
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
  assert.equal(c.getStatus().queued, 0);
});

// Ölçüm denetimi madde 15: sekmeler aynı depoyu paylaşır; son yazan kazanmaz, bir sekmenin onayladığı olay yeniden gitmez.
const sentIds = (calls) => calls.flatMap((c) => JSON.parse(c.init.body).events.map((e) => e.event_id));

test("iki sekme aynı kuyruğa yazar: biri diğerinin gönderilmemiş olayını silmez", async () => {
  const storage = mem();
  const a = fakeFetch(202); const b = fakeFetch(202);
  const opts = { projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, storage, flushIntervalMs: 0, autoTrack: false };
  const tabA = new sdk.Feralin({ ...opts, fetch: a.f });
  const tabB = new sdk.Feralin({ ...opts, fetch: b.f });
  const e1 = tabA.track("a_event");
  const e2 = tabB.track("b_event");
  await tabA.flush(); await tabB.flush();
  const delivered = [...sentIds(a.calls), ...sentIds(b.calls)];
  assert.ok(delivered.includes(e1.event_id), "A'nın olayı B'nin yazımıyla ezilmemeli");
  assert.ok(delivered.includes(e2.event_id));
  assert.equal(new Set(delivered).size, delivered.length, "hiçbir olay iki kez gönderilmemeli");
  assert.equal(tabA.getStatus().queued, 0);
});

test("yeni sekme önceki sekmenin gönderilmemiş olayını gönderir, eski sekme onu yeniden göndermez", async () => {
  const storage = mem();
  const a = fakeFetch(202); const b = fakeFetch(202);
  const opts = { projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, storage, flushIntervalMs: 0, autoTrack: false };
  const tabA = new sdk.Feralin({ ...opts, fetch: a.f });
  const e1 = tabA.track("a_event");
  const tabB = new sdk.Feralin({ ...opts, fetch: b.f });
  await tabB.flush();
  assert.deepEqual(sentIds(b.calls), [e1.event_id]);
  await tabA.flush();
  assert.equal(a.calls.length, 0, "B'nin onayladığı olayı A tekrar göndermemeli");
});

test("202 yanıtındaki red listesi sonuca taşınır ve batch tekrar gönderilmez", async () => {
  const body = { batch_id: "01TEST", accepted: 1, rejected: 1, rejected_events: [{ index: 1, event_id: "x", reason: "invalid_event" }] };
  const c = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", consent: { analytics: true }, fetch: fakeFetch(202, body).f, storage: mem(), flushIntervalMs: 0, autoTrack: false });
  c.track("a"); c.track("b");
  const r = await c.flush();
  assert.equal(r.status, 202);
  assert.deepEqual(r.rejected_events, body.rejected_events);
  assert.equal(c.getStatus().queued, 0);
});

test("kurulum eşleştirme kodu yalnız izinden sonraki ilk olaya eklenir; geçersiz kod yok sayılır", () => {
  const c = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", fetch: fakeFetch(202).f, storage: mem(), flushIntervalMs: 0, autoTrack: false, installCode: " K7M2-Q9XR4 " });
  assert.equal(c.track("ilk_olay"), null, "izin yokken olay ve kod gitmez");
  c.setConsent({ analytics: true });
  const first = c.track("ilk_olay", { a: 1 });
  assert.equal(first.properties.fr_install_code, "K7M2-Q9XR4");
  assert.equal(first.properties.a, 1);
  const second = c.track("ikinci_olay");
  assert.equal(second.properties?.fr_install_code, undefined);
  const bad = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", fetch: fakeFetch(202).f, storage: mem(), flushIntervalMs: 0, autoTrack: false, consent: { analytics: true }, installCode: "x;DROP" });
  assert.equal(bad.track("olay").properties?.fr_install_code, undefined);
});
