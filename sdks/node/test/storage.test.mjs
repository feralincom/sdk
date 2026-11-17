// Kalıcı kuyruk (`storageDirectory`) birim testleri. Çökme gerçek alt süreçle sınanır: alt süreç olay üretir ve `close` çağırmadan
// `process.exit` ile çıkar; ana süreç aynı dizinle açılıp olayları devralır. Ağ sahte fetch'tir; gerçek toplayıcı testi
// scripts/sdk-e2e/run.mjs node içindedir.
import test from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { FeralinClient, idempotencyKeyFor } from "../dist/esm/index.js";

const KEY = "pk_test_node_storage_01";
const URL_BASE = "http://collector.test";
const GRANTED = { analytics: true };
const DIST = pathToFileURL(join(import.meta.dirname, "../dist/esm/index.js")).href;

function tempDir(t) {
  const dir = mkdtempSync(join(tmpdir(), "feralin-node-storage-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function fakeFetch(responses = []) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ key: init.headers["idempotency-key"], ids: JSON.parse(init.body).events.map((e) => e.event_id) });
    const next = responses.length ? responses.shift() : { status: 202 };
    if (next instanceof Error) throw next;
    return new Response(JSON.stringify({ batch_id: `b${calls.length}`, accepted: calls.at(-1).ids.length, rejected: 0 }), { status: next.status });
  };
  return { impl, calls };
}

function client(dir, fetchImpl, extra = {}) {
  return new FeralinClient({ projectKey: KEY, collectUrl: URL_BASE, flushIntervalMs: 0, consent: GRANTED, storageDirectory: dir, fetch: fetchImpl, ...extra });
}

/** Alt süreçte betik koşar: `make(extra)` istemci kurar; betik sonunda `close` çağrılmadan çıkılır (çökme). Çıktı JSON satırıdır. */
function child(dir, body) {
  const script = `
    import { FeralinClient } from ${JSON.stringify(DIST)};
    const dir = ${JSON.stringify(dir)};
    const calls = [];
    const fetchImpl = async (url, init) => { calls.push(init.headers["idempotency-key"]); throw new Error("ağ yok"); };
    const make = (extra = {}) => new FeralinClient({ projectKey: ${JSON.stringify(KEY)}, collectUrl: ${JSON.stringify(URL_BASE)}, flushIntervalMs: 0, consent: { analytics: true }, storageDirectory: dir, fetch: fetchImpl, ...extra });
    const out = {};
    ${body}
    process.stdout.write(JSON.stringify(out));
    process.exit(0);
  `;
  const result = spawnSync(process.execPath, ["--input-type=module", "-e", script], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

function journals(dir) {
  return readdirSync(dir).filter((name) => name.endsWith(".jsonl"));
}

test("çöken süreçteki olaylar sonraki açılışta gönderilir; gönderilen olay tekrar gitmez", async (t) => {
  const dir = tempDir(t);
  const out = child(dir, `
    const c = make({ fetch: async () => new Response('{"accepted":1}', { status: 202 }) });
    out.sent = c.track("order_completed", { order_id: "o1" }).event_id;
    await c.flush();
    out.pending = [c.track("order_shipped").event_id, c.track("order_refunded").event_id];
  `);
  assert.equal(journals(dir).length, 1, "çöken süreç günlüğü diskte bırakır");
  const { impl, calls } = fakeFetch();
  const c = client(dir, impl);
  assert.equal(c.getStatus().queued, 2);
  const r = await c.flush();
  assert.deepEqual([r.status, r.accepted], [202, 2]);
  assert.deepEqual(calls[0].ids, out.pending, "sıra korunur");
  assert.ok(!calls.flatMap((call) => call.ids).includes(out.sent), "kabul edilen olay yeniden gönderilmez");
  await c.close();
  assert.deepEqual(journals(dir), [], "boş kuyrukla kapanış günlüğü siler");
});

test("yanıtı kaybolan batch çöküşten sonra aynı bileşim ve aynı Idempotency-Key ile gider", async (t) => {
  const dir = tempDir(t);
  const out = child(dir, `
    const c = make();
    const ids = [c.track("a_event").event_id, c.track("b_event").event_id];
    await c.flush();
    out.ids = ids;
    out.key = calls[0];
    out.later = c.track("c_event").event_id;
  `);
  assert.equal(out.key, idempotencyKeyFor(out.ids));
  const { impl, calls } = fakeFetch();
  const c = client(dir, impl);
  assert.equal(c.getStatus().queued, 3);
  await c.flush();
  assert.equal(calls[0].key, out.key, "sunucu bu anahtarla ikinci outbox satırı yazmaz");
  assert.deepEqual(calls[0].ids, out.ids);
  assert.deepEqual(calls[1].ids, [out.later]);
  await c.close();
});

test("yaş sınırını aşan olay devralınmaz, sayaca yazılır", async (t) => {
  const dir = tempDir(t);
  child(dir, `
    const c = make({ now: () => Date.now() - 60_000 });
    c.track("old_event");
  `);
  const { impl, calls } = fakeFetch();
  const c = client(dir, impl, { storageMaxAgeMs: 30_000 });
  assert.deepEqual([c.getStatus().queued, c.getStatus().dropped], [0, 1]);
  await c.flush();
  assert.equal(calls.length, 0);
  await c.close();
});

test("boyut sınırı: disk kuyruğu storageMaxBytes içinde kalır, en eski olay atılır", async (t) => {
  const dir = tempDir(t);
  const warnings = [];
  const { impl, calls } = fakeFetch();
  const c = client(dir, impl, { storageMaxBytes: 2048, logger: { warn: (m) => warnings.push(m) } });
  const ids = [];
  for (let i = 0; i < 20; i++) ids.push(c.track("bulk_event", { pad: "x".repeat(200), i }).event_id);
  const status = c.getStatus();
  assert.ok(status.storage.bytes <= 2048, `bayt ${status.storage.bytes}`);
  assert.equal(status.queued + status.dropped, 20);
  assert.ok(status.dropped > 0 && warnings.some((m) => m.includes("kuyruk sınırı")));
  await c.flush();
  assert.deepEqual(calls.flatMap((call) => call.ids), ids.slice(status.dropped), "kalanlar en yeni olaylardır");
  await c.close();
});

test("gönderilemeyen kuyruk kapanışta diskte kalır ve sonraki örnekte gider", async (t) => {
  const dir = tempDir(t);
  const failing = fakeFetch([{ status: 503 }]);
  const first = client(dir, failing.impl);
  const id = first.track("order_completed").event_id;
  const closed = await first.close();
  assert.equal(closed.retained, 1);
  assert.equal(journals(dir).length, 1);
  const { impl, calls } = fakeFetch();
  const second = client(dir, impl);
  await second.flush();
  assert.deepEqual(calls[0].ids, [id]);
  assert.equal(calls[0].key, failing.calls[0].key, "kapanıştan önce sabitlenen batch anahtarı korunur");
  await second.close();
});

test("aynı süreçteki canlı istemcinin günlüğü devralınmaz", async (t) => {
  const dir = tempDir(t);
  const a = client(dir, fakeFetch().impl);
  a.track("a_event");
  const b = client(dir, fakeFetch().impl);
  assert.equal(b.getStatus().queued, 0);
  assert.equal(journals(dir).length, 2, "her örnek kendi dosyasına yazar");
  await b.close();
  await a.close();
});

test("izin geri çekilince disk kuyruğu da silinir", async (t) => {
  const dir = tempDir(t);
  child(dir, `
    const c = make();
    c.track("a_event");
    c.optOut();
  `);
  const c = client(dir, fakeFetch().impl);
  assert.equal(c.getStatus().queued, 0);
  await c.close();
});

test("bozuk satır ve yarım kalan son satır atlanır; geri kalan olaylar okunur", async (t) => {
  const dir = tempDir(t);
  const host = createHash("sha256").update(hostname()).digest("hex").slice(0, 8);
  const event = (id) => JSON.stringify({ event_id: id, event_name: "kept_event", occurred_at: new Date().toISOString(), platform: "node", schema_version: 1, consent: GRANTED });
  const at = Date.now();
  // pid 2147483646 yaşayan bir süreç değildir: günlük aynı konakta ölü sürecin günlüğü sayılır ve hemen devralınır.
  writeFileSync(
    join(dir, `fq-${host}-2147483646-test1.jsonl`),
    `e ${at} ${event("01JC0000000000000000000001")}\n` + `e ${at} {bozuk\n` + `x tanınmayan\n` + `e ${at} ${event("01JC0000000000000000000002")}\n` + `e ${at} {"event_id":"01JC00000000000`,
  );
  const { impl, calls } = fakeFetch();
  const c = client(dir, impl);
  await c.flush();
  assert.deepEqual(calls[0].ids, ["01JC0000000000000000000001", "01JC0000000000000000000002"]);
  await c.close();
  assert.deepEqual(journals(dir), []);
});

test("iki süreç aynı sahipsiz günlüğü aynı anda devralmaya çalışırsa her olay tek sürece düşer", async (t) => {
  const dir = tempDir(t);
  const host = createHash("sha256").update(hostname()).digest("hex").slice(0, 8);
  const at = Date.now();
  const ids = Array.from({ length: 40 }, (_, i) => `01JC00000000000000000000${String(i).padStart(2, "0")}`);
  const lines = ids.map((id) => `e ${at} ${JSON.stringify({ event_id: id, event_name: "race_event", occurred_at: new Date().toISOString(), platform: "node", schema_version: 1, consent: GRANTED })}\n`);
  // Olaylar iki ölü sürecin günlüğüne bölünür: yarış hem tek dosya hem dosyalar arası denenir.
  writeFileSync(join(dir, `fq-${host}-2147483645-race1.jsonl`), lines.slice(0, 20).join(""));
  writeFileSync(join(dir, `fq-${host}-2147483644-race2.jsonl`), lines.slice(20).join(""));
  const script = `
    import { FeralinClient } from ${JSON.stringify(DIST)};
    const seen = [];
    const c = new FeralinClient({ projectKey: ${JSON.stringify(KEY)}, collectUrl: ${JSON.stringify(URL_BASE)}, flushIntervalMs: 0, storageDirectory: ${JSON.stringify(dir)},
      fetch: async (url, init) => { seen.push(...JSON.parse(init.body).events.map((e) => e.event_id)); return new Response("{}", { status: 202 }); } });
    await c.close();
    process.stdout.write(JSON.stringify(seen));
  `;
  const runChild = () =>
    new Promise((resolve, reject) => {
      const proc = spawn(process.execPath, ["--input-type=module", "-e", script], { stdio: ["ignore", "pipe", "pipe"] });
      let stdout = "";
      let stderr = "";
      proc.stdout.on("data", (d) => (stdout += d));
      proc.stderr.on("data", (d) => (stderr += d));
      proc.on("exit", (code) => (code === 0 ? resolve(JSON.parse(stdout)) : reject(new Error(stderr))));
    });
  const [first, second] = await Promise.all([runChild(), runChild()]);
  const all = [...first, ...second].sort();
  assert.deepEqual(all, ids, "kayıp ya da çift gönderim yok");
  assert.deepEqual(journals(dir), []);
});

test("yazılamayan dizin kurucuda fırlatır; anahtar ve yol hata metnine girmez", (t) => {
  const dir = tempDir(t);
  const file = join(dir, "dosya");
  writeFileSync(file, "x");
  assert.throws(() => client(join(file, "alt"), fakeFetch().impl), (err) => /storageDirectory kullanılamıyor/.test(err.message) && !err.message.includes(dir));
  assert.throws(() => client("  ", fakeFetch().impl), /storageDirectory/);
});

test("disk dosyası yalnız olay gövdelerini taşır; proje anahtarı yazılmaz", async (t) => {
  const dir = tempDir(t);
  const failing = fakeFetch([{ status: 503 }]);
  const c = client(dir, failing.impl);
  c.track("order_completed", { order_id: "o_disk" });
  await c.close();
  const [name] = journals(dir);
  const text = readFileSync(join(dir, name), "utf8");
  assert.ok(text.includes("o_disk"));
  assert.ok(!text.includes(KEY));
});
