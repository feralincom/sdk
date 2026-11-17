// Temiz kurulumdan çalışan tüketici: `npm pack` çıktısı boş dizine kurulur, bu dosya oraya kopyalanır ve gerçek
// services/collect ile konuşur. Denetim satırları outbox_check.go ile PostgreSQL üzerinde doğrulanır.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { appendFileSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { FeralinClient, idempotencyKeyFor, SDK_VERSION } from "@feralin/node";

const collectUrl = process.env.FERALIN_E2E_COLLECT_URL;
const projectKey = process.env.FERALIN_E2E_PROJECT_KEY;
const out = process.env.FERALIN_E2E_CHECKS;
assert.ok(collectUrl && projectKey && out, "FERALIN_E2E_COLLECT_URL, FERALIN_E2E_PROJECT_KEY, FERALIN_E2E_CHECKS zorunlu");

const expect = (line) => appendFileSync(out, line + "\n");
const report = (name, detail) => console.log(`  OK ${name}: ${JSON.stringify(detail)}`);
const make = (extra = {}) => new FeralinClient({ projectKey, collectUrl, flushIntervalMs: 0, ...extra });

// Çökme alt süreci (`node e2e-consumer.mjs crash-child <dizin>`): kalıcı kuyrukla olay üretir; ilk batch toplayıcıya yazılır ama yanıt
// yolda kaybolur, ikinci olay hiç gönderilmez; süreç `close` çağırmadan çıkar. Kimlikler ve kullanılan anahtar stdout'a yazılır.
if (process.argv[2] === "crash-child") {
  const keys = [];
  const lossy = async (url, init) => {
    keys.push(init.headers["idempotency-key"]);
    const res = await fetch(url, init);
    await res.arrayBuffer();
    throw new Error("yanıt yolda kayboldu");
  };
  const c = make({ storageDirectory: process.argv[3], fetch: lossy, consent: { analytics: true } });
  const pinned = [c.track("order_completed", { order_id: "ord_node_crash_1" }).event_id, c.track("order_shipped", { order_id: "ord_node_crash_1" }).event_id];
  const lost = await c.flush();
  assert.deepEqual([lost.status, lost.retained], [0, 2]);
  const unsent = c.track("order_refunded", { order_id: "ord_node_crash_1" }).event_id;
  process.stdout.write(JSON.stringify({ pinned, unsent, key: keys[0], pid: process.pid }));
  process.exit(0);
}

// CommonJS girişi de kurulu paketten yüklenir.
const cjs = createRequire(import.meta.url)("@feralin/node");
assert.equal(cjs.SDK_VERSION, SDK_VERSION);
report("cjs-esm", { version: SDK_VERSION });

// 202 + outbox satırı + fr_click reklam izniyle
{
  const c = make({ consent: { analytics: true, advertising: true } });
  const e = c.track("order_completed", { order_id: "ord_node_1", fr_click: "clk_node_1" }, { userId: "user_node_1" });
  const r = await c.flush();
  assert.deepEqual([r.status, r.accepted, r.rejected, r.retained], [202, 1, 0, 0]);
  expect(`frclick ${r.batch_id}`);
  expect(`once ${e.event_id}`);
  report("202-outbox-frclick", { status: r.status, batch_id: r.batch_id });
}

// Reklam izni yok: fr_click çıkarılır
{
  const c = make({ consent: { analytics: true, advertising: false } });
  const e = c.track("order_completed", { order_id: "ord_node_2", fr_click: "clk_node_2" });
  assert.equal(e.properties.fr_click, undefined);
  const r = await c.flush();
  assert.equal(r.status, 202);
  expect(`nofrclick ${r.batch_id}`);
  report("frclick-izinsiz-cikarildi", { status: r.status });
}

// İzinsiz: SDK olay üretmez ve istek yapmaz
{
  let requests = 0;
  const c = make({ fetch: (...args) => { requests++; return fetch(...args); } });
  assert.equal(c.track("order_completed"), null);
  const r = await c.flush();
  assert.deepEqual([r.sent, requests], [0, 0]);
  report("izinsiz-sdk-uretmez", { sent: r.sent, requests });
}

// İzinsiz ham istek: toplayıcı olay düzeyinde reddeder, outbox'a yazmaz
{
  const id = `01JCNODE${Date.now().toString(36).toUpperCase().padStart(18, "0")}`.slice(0, 26);
  const event = { event_id: id, event_name: "denied_event", occurred_at: new Date().toISOString(), platform: "node", schema_version: 1, consent: { analytics: false } };
  const res = await fetch(`${collectUrl}/v1/batch`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-feralin-project-key": projectKey, "idempotency-key": idempotencyKeyFor([id]) },
    body: JSON.stringify({ events: [event] }),
  });
  const body = await res.json();
  assert.equal(res.status, 202);
  assert.deepEqual([body.accepted, body.rejected, body.rejected_reasons.consent_denied], [0, 1, 1]);
  expect(`absent ${id}`);
  report("izinsiz-toplayici-red", { status: res.status, rejected_reasons: body.rejected_reasons });
}

// Yanlış anahtar: 401, olay atılır, uygulama düşmez
{
  const c = make({ projectKey: "pk_test_wrong_key_000", consent: { analytics: true } });
  const e = c.track("order_completed", { order_id: "ord_node_wrong" });
  const r = await c.flush();
  assert.deepEqual([r.status, r.rejected, r.retained], [401, 1, 0]);
  expect(`absent ${e.event_id}`);
  report("yanlis-anahtar-401", { status: r.status, rejected: r.rejected });
}

// Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar aynı batch_id ve tek outbox satırı
{
  let first = true;
  const keys = [];
  const lossy = async (url, init) => {
    keys.push(init.headers["idempotency-key"]);
    const res = await fetch(url, init);
    if (first) {
      first = false;
      await res.arrayBuffer();
      throw new Error("yanıt yolda kayboldu");
    }
    return res;
  };
  const c = make({ fetch: lossy, consent: { analytics: true } });
  const e = c.track("order_completed", { order_id: "ord_node_retry" });
  const lost = await c.flush();
  assert.deepEqual([lost.status, lost.retained], [0, 1]);
  // Araya giren olay yeniden denenen batch'in içeriğini ve anahtarını değiştirmemeli.
  const next = c.track("order_shipped", { order_id: "ord_node_retry" });
  const retried = await c.flush();
  assert.equal(retried.status, 202);
  assert.equal(keys[0], keys[1]);
  assert.equal(retried.retained, 0);
  expect(`once ${e.event_id}`);
  expect(`once ${next.event_id}`);
  report("idempotency-tekrar", { key: keys[0], key_ayni: keys[0] === keys[1], accepted: retried.accepted });

  // Doğrudan tekrar: aynı gövde ve anahtar aynı batch_id döndürür.
  const raw = make({ consent: { analytics: true } });
  const captured = [];
  const capturing = make({ consent: { analytics: true }, fetch: async (u, i) => { captured.push(i); return fetch(u, i); } });
  const once = capturing.track("order_refunded", { order_id: "ord_node_replay" });
  const original = await capturing.flush();
  const replay = await fetch(`${collectUrl}/v1/batch`, captured[0]);
  const replayBody = await replay.json();
  assert.equal(replay.status, 202);
  assert.equal(replayBody.batch_id, original.batch_id);
  // Tekrar yanıtı ilk kabulün olay sayısını taşır (ölçüm denetimi madde 32); yeni olay yazılmaz (aşağıda tek outbox satırı).
  assert.equal(replayBody.accepted, original.accepted);
  expect(`once ${once.event_id}`);
  await raw.close();
  report("idempotency-ayni-batch", { batch_id: replayBody.batch_id, accepted: replayBody.accepted });
}

// Çoklu olay, kapanışta gönderim
{
  const c = make({ consent: { analytics: true } });
  const events = ["cart_viewed", "checkout_started", "order_completed"].map((name) => c.track(name, { source: "e2e" }));
  const r = await c.close();
  assert.deepEqual([r.status, r.accepted], [202, 3]);
  for (const e of events) expect(`once ${e.event_id}`);
  report("close-batch", { accepted: r.accepted });
}

// Kalıcı kuyruk: çöken alt süreç sunucuya yazılan ama yanıtı kaybolan batch'i ve hiç gönderilmeyen olayı diskte bırakır. Yeniden
// başlayan süreç aynı dizini açar: kaybolan batch aynı Idempotency-Key ile gider (ikinci outbox satırı yazılmaz), kalan olay da
// gönderilir; kuyruk boşalınca günlük silinir. npm'deki 0.1.0 bu seçeneği taşımaz: registry koşusunda senaryo açıkça atlanır.
if (!("storage" in make().getStatus())) {
  console.log("  ATLANDI kalici-kuyruk: kurulu paket storageDirectory desteklemiyor (npm'deki 0.1.0)");
} else {
  const dir = mkdtempSync(join(tmpdir(), "feralin-node-e2e-queue-"));
  try {
    const crashed = spawnSync(process.execPath, [fileURLToPath(import.meta.url), "crash-child", dir], { encoding: "utf8", env: process.env });
    assert.equal(crashed.status, 0, crashed.stderr);
    const child = JSON.parse(crashed.stdout);
    assert.equal(child.key, idempotencyKeyFor(child.pinned));
    assert.equal(readdirSync(dir).filter((name) => name.endsWith(".jsonl")).length, 1, "çöken süreç günlüğü diskte bırakır");
    const keys = [];
    const c = make({ storageDirectory: dir, consent: { analytics: false }, fetch: (url, init) => { keys.push(init.headers["idempotency-key"]); return fetch(url, init); } });
    assert.equal(c.getStatus().queued, 3, "devralınan olaylar kuyrukta");
    const r = await c.close();
    assert.deepEqual([r.status, r.retained], [202, 0]);
    assert.equal(keys[0], child.key, "kaybolan batch aynı anahtarla yeniden gönderildi");
    assert.equal(keys.length, 2);
    assert.deepEqual(readdirSync(dir), [], "boş kuyrukta günlük silinir");
    for (const id of [...child.pinned, child.unsent]) expect(`once ${id}`);
    report("kalici-kuyruk-cokme-yeniden-baslama", { child_pid: child.pid, key_ayni: keys[0] === child.key, istek: keys.length });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
// Kimlik yöntemleri (UTP §8.2): toplayıcı izin listesi run.mjs'te `plan,tier`; liste dışı anahtar sunucuda düşer.
{
  const profileOut = process.env.FERALIN_E2E_PROFILE_CHECKS;
  assert.ok(profileOut, "FERALIN_E2E_PROFILE_CHECKS zorunlu");
  const expectProfile = (line) => appendFileSync(profileOut, line + "\n");
  const c = make({ consent: { analytics: true } });
  c.setGlobalProperties({ app_release: "e2e" });
  const tracked = c.track("profile_e2e_opened", {}, { userId: "user_node_profile" });
  const user = c.setUserProperties({ plan: "pro", tier: 2, secret_note: "x", email: "kisi@example.com" }, { userId: "user_node_profile" });
  assert.equal(user.properties.email, undefined, "PII anahtarı istemcide düşmeli");
  const group = c.group("acme-team", { plan: "team" }, { userId: "user_node_profile" });
  assert.equal(c.group("owner@acme.com"), null);
  const r = await c.close();
  assert.deepEqual([r.status, r.accepted, r.rejected], [202, 3, 0]);
  expectProfile(`prop ${tracked.event_id} app_release="e2e"`);
  expectProfile(`name fr_user_properties:${user.event_id}`);
  expectProfile(`prop ${user.event_id} plan="pro"`);
  expectProfile(`prop ${user.event_id} tier=2`);
  expectProfile(`noprop ${user.event_id} secret_note`);
  expectProfile(`noprop ${user.event_id} app_release`);
  expectProfile(`name fr_group:${group.event_id}`);
  expectProfile(`prop ${group.event_id} group_id="acme-team"`);
  expectProfile(`prop ${group.event_id} plan="team"`);
  report("kimlik-yontemleri", { accepted: r.accepted });
}
console.log("node tüketici: tüm senaryolar geçti");
