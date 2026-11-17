// Bayrak istemcisi birim testleri (F4-E02-T03): özne kimliği, gövde ve başlık, önbellek, maruz kalma olayı bir kez,
// bilinmeyen anahtar varsayılanı, ağ hatasında eski sonuç, gizli anahtar reddi.
import test from "node:test";
import assert from "node:assert/strict";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
execFileSync(process.execPath, [join(root, "scripts/build.mjs")], { stdio: "pipe" });
const mod = await import(join(root, "dist/feralin-flags.mjs").replace(/\\/g, "/").replace(/^([A-Za-z]):/, "file:///$1:"));

function fakeClient(status) {
  const events = [];
  return { events, status, track(name, props) { if (!this.status.consent.analytics) return null; events.push({ name, props }); return {}; }, getStatus() { return this.status; } };
}

function fakeFetch(status, body) {
  const calls = [];
  return { calls, fetch: async (url, init) => { calls.push({ url, init }); return { status, json: async () => body }; } };
}

const response = { flags: [{ key: "new_checkout", enabled: true, variant: "b", reason: "enabled" }, { key: "dark_mode", enabled: false, variant: null, reason: "rollout_miss" }], unknown_keys: ["eski"], evaluated_at: "2026-11-09T10:00:00Z" };

test("gizli anahtar ve eksik seçenek reddedilir", () => {
  const client = fakeClient({ consent: { analytics: true }, anonymous_id: "ANON-0000", user_id: null });
  assert.throws(() => new mod.FeralinFlags({ client, apiUrl: "http://api", projectKey: "sk_live_x" }));
  assert.throws(() => new mod.FeralinFlags({ client, apiUrl: "", projectKey: "pk_live_x" }));
});

test("özne: user_id varsa o, yoksa anonymous_id; istek POST gövdede, anahtar Bearer başlığında, URL'de kimlik yok", async () => {
  const client = fakeClient({ consent: { analytics: true }, anonymous_id: "ANON-0001", user_id: null });
  const { calls, fetch } = fakeFetch(200, response);
  const flags = new mod.FeralinFlags({ client, apiUrl: "http://api/", projectKey: " pk_live_abc ", keys: ["new_checkout", "dark_mode", "Geçersiz Anahtar"], fetch });
  await flags.load();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "http://api/v1/flags/evaluate");
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers.authorization, "Bearer pk_live_abc");
  assert.deepEqual(JSON.parse(calls[0].init.body), { subject: "ANON-0001", keys: ["new_checkout", "dark_mode"] });
  assert.ok(!calls[0].url.includes("ANON-0001"));
  client.status = { consent: { analytics: true }, anonymous_id: "ANON-0001", user_id: "user-0009" };
  await flags.load(true);
  assert.deepEqual(JSON.parse(calls[1].init.body).subject, "user-0009");
  // Analitik izni yokken kullanıcı kimliği gitmez, yalnız anonim kimlik; kısa ya da e-posta biçimli kullanıcı kimliği de anonime düşer.
  client.status = { consent: { analytics: false }, anonymous_id: "ANON-0001", user_id: "user-0009" };
  await flags.load(true);
  assert.equal(JSON.parse(calls[2].init.body).subject, "ANON-0001");
  client.status = { consent: { analytics: true }, anonymous_id: "ANON-0001", user_id: "ali@example.test" };
  await flags.load(true);
  assert.equal(JSON.parse(calls[3].init.body).subject, "ANON-0001");
});

test("okuma: sonuç ve varsayılan; maruz kalma olayı anahtar başına bir kez, analitik izni yokken hiç", async () => {
  const client = fakeClient({ consent: { analytics: true }, anonymous_id: "ANON-0001", user_id: null });
  const flags = new mod.FeralinFlags({ client, apiUrl: "http://api", projectKey: "pk_live_abc", fetch: fakeFetch(200, response).fetch });
  assert.equal(flags.isEnabled("new_checkout"), false, "yüklenmeden varsayılan");
  assert.equal(flags.isEnabled("new_checkout", true), true);
  assert.equal(client.events.length, 0, "yüklenmemiş sonuç maruz kalma üretmez");
  await flags.load();
  assert.equal(flags.isEnabled("new_checkout"), true);
  assert.equal(flags.variant("new_checkout"), "b");
  assert.equal(flags.isEnabled("dark_mode"), false);
  assert.equal(flags.variant("dark_mode", "a"), "a", "kapalı bayrakta varsayılan varyant");
  assert.equal(flags.isEnabled("eski", true), true, "bilinmeyen anahtar varsayılanını korur");
  assert.deepEqual(client.events.map((e) => [e.name, e.props.flag_key, e.props.variant, e.props.enabled]), [["fr_flag_exposure", "new_checkout", "b", true], ["fr_flag_exposure", "dark_mode", "", false]]);
  flags.isEnabled("new_checkout");
  assert.equal(client.events.length, 2, "maruz kalma tekrar etmez");
  client.status = { consent: { analytics: false }, anonymous_id: "ANON-0002", user_id: null };
  await flags.load(true);
  flags.isEnabled("new_checkout");
  assert.equal(client.events.length, 2, "analitik izni yokken olay üretilmez");
});

test("önbellek: TTL içinde yeniden istek yok, zorlanınca var; eşzamanlı yükleme tek istek; ağ hatası eski sonucu korur", async () => {
  const client = fakeClient({ consent: { analytics: true }, anonymous_id: "ANON-0001", user_id: null });
  const { calls, fetch } = fakeFetch(200, response);
  const flags = new mod.FeralinFlags({ client, apiUrl: "http://api", projectKey: "pk_live_abc", fetch, ttlMs: 60_000 });
  await Promise.all([flags.load(), flags.load(), flags.load()]);
  assert.equal(calls.length, 1);
  await flags.load();
  assert.equal(calls.length, 1, "TTL içinde yeniden sorulmaz");
  const failing = new mod.FeralinFlags({ client, apiUrl: "http://api", projectKey: "pk_live_abc", fetch: async () => { throw new Error("ağ"); } });
  await failing.load();
  assert.deepEqual(failing.snapshot(), []);
  const broken = new mod.FeralinFlags({ client, apiUrl: "http://api", projectKey: "pk_live_abc", fetch: fakeFetch(429, {}).fetch });
  await broken.load();
  assert.equal(broken.isEnabled("new_checkout", true), true, "hatalı yanıt varsayılanı bozmaz");
});

test("429 ve 5xx sonrası bekleme: Retry-After alt sınırdır, bekleme boyunca zorlanan yükleme bile sunucuya gitmez", async () => {
  const client = fakeClient({ consent: { analytics: true }, anonymous_id: "ANON-0001", user_id: null });
  const calls = [];
  const fetch = async (url, init) => { calls.push({ url, init }); return { status: 429, headers: { get: (name) => (name === "retry-after" ? "120" : null) }, json: async () => ({}) }; };
  const flags = new mod.FeralinFlags({ client, apiUrl: "http://api", projectKey: "pk_live_abc", fetch });
  await flags.load();
  await flags.load(true);
  await flags.load(true);
  assert.equal(calls.length, 1, "429 sonrası yeniden sorulmaz");
  assert.equal(flags.isEnabled("new_checkout", true), true, "varsayılan korunur");
});
