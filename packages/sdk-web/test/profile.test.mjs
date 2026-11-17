// Kimlik yöntemleri (UTP §8.2): group, setUserProperties, setGlobalProperties. Kurallar toplayıcının profile_filter.go dosyasıyla aynıdır.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
execFileSync(process.execPath, [join(root, "scripts/build.mjs")], { stdio: "pipe" });
const sdk = await import(join(root, "dist/feralin.mjs").replace(/\\/g, "/").replace(/^([A-Za-z]):/, "file:///$1:"));

const schemasRoot = join(root, "../schemas/utp/v1");
const ajv = new Ajv2020({ strict: true, allErrors: true });
addFormats(ajv);
ajv.addSchema(JSON.parse(readFileSync(join(schemasRoot, "event.schema.json"), "utf8")));
const validateBatch = ajv.compile(JSON.parse(readFileSync(join(schemasRoot, "batch.schema.json"), "utf8")));

const mem = () => {
  const m = new Map();
  return { get: (k) => m.get(k) ?? null, set: (k, v) => m.set(k, v), remove: (k) => m.delete(k) };
};
function client() {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init });
    return { status: 202, json: async () => ({ batch_id: "01TEST", accepted: 1, rejected: 0 }) };
  };
  const c = new sdk.Feralin({ projectKey: "pk_test_profile", collectUrl: "http://c", consent: { analytics: true }, fetch, storage: mem(), flushIntervalMs: 0, autoTrack: false });
  return { c, calls };
}

test("PII'ye benzeyen anahtar kuralı toplayıcıyla aynı", () => {
  for (const key of ["email", "userEmail", "e_mail_address", "phone", "phoneNumber", "mobile", "ip", "userIP", "ipv4", "client_ip", "firstName", "last_name", "fullname", "name", "Name", "username", "displayName", "isim", "ad", "soyad", "adSoyad", "eposta", "telefon", "home_address", "birthDate", "dob", "tckn", "passport", "password", "iban"]) {
    assert.equal(sdk.isPIILikeKey(key), true, key);
  }
  for (const key of ["plan", "tier", "zip_bucket", "hotel_class", "membership", "plan_name", "ad_network", "shipping_tier", "signup_week"]) {
    assert.equal(sdk.isPIILikeKey(key), false, key);
  }
});

test("setUserProperties: PII, ayrılmış alan, uzun değer, nesne ve geçersiz anahtar düşer", () => {
  const { c } = client();
  const e = c.setUserProperties({
    plan: "pro",
    tier: 2,
    beta: true,
    email: "a@b.co",
    phoneNumber: "+905551112233",
    verified: true,
    receipt: "x",
    note: "x".repeat(257),
    contact: "biri@example.com",
    nested: { a: 1 },
    list: [1, 2],
    nothing: null,
    nan: Number.NaN,
    "bad key": 1,
  });
  assert.equal(e.event_name, "fr_user_properties");
  assert.deepEqual(e.properties, { plan: "pro", tier: 2, beta: true });
});

test("setUserProperties: geçerli özellik yoksa olay üretilmez", () => {
  const { c } = client();
  assert.equal(c.setUserProperties({ email: "a@b.co", obj: {} }), null);
  assert.equal(c.getStatus().queued, 0);
});

test("setUserProperties: çağrı başına en çok 50 özellik", () => {
  const { c } = client();
  const input = Object.fromEntries(Array.from({ length: 60 }, (_, i) => [`k${i}`, i]));
  const e = c.setUserProperties(input);
  assert.equal(Object.keys(e.properties).length, 50);
});

test("group: fr_group, group_id ve temizlenmiş özellikler; geçersiz kimlik olay üretmez", async () => {
  const { c, calls } = client();
  const e = c.group("acme-team", { plan: "team", email: "x@y.zz", group_id: "spoof" });
  assert.equal(e.event_name, "fr_group");
  assert.deepEqual(e.properties, { plan: "team", group_id: "acme-team" });
  for (const bad of ["", "   ", "a".repeat(129), "owner@acme.com", "tab\tid", 42, undefined]) {
    assert.equal(c.group(bad), null, String(bad));
  }
  assert.equal(c.getStatus().queued, 1);
  await c.flush();
  assert.equal(validateBatch(JSON.parse(calls[0].init.body)), true, JSON.stringify(validateBatch.errors));
});

test("global özellikler: birleşir, olay özelliği ezer, null siler, fr_ olayına eklenmez", () => {
  const { c } = client();
  c.setGlobalProperties({ app_release: "e2e", plan: "free", email: "x@y.zz" });
  c.setGlobalProperties({ theme: "dark" });
  const a = c.track("signup", { plan: "pro" });
  assert.deepEqual(a.properties, { plan: "pro", app_release: "e2e", theme: "dark" });
  c.setGlobalProperties({ theme: null });
  const b = c.track("open");
  assert.deepEqual(b.properties, { app_release: "e2e", plan: "free" });
  const group = c.group("g1");
  assert.deepEqual(group.properties, { group_id: "g1" });
  const user = c.setUserProperties({ tier: 1 });
  assert.deepEqual(user.properties, { tier: 1 });
  const page = c.page();
  assert.equal(page.properties.app_release, "e2e");
});

test("global özellikler: en çok 50 anahtar, clear ve reset temizler", () => {
  const { c } = client();
  c.setGlobalProperties(Object.fromEntries(Array.from({ length: 50 }, (_, i) => [`g${i}`, i])));
  c.setGlobalProperties({ extra: 1, g0: "yeni" });
  const e = c.track("x");
  assert.equal(Object.keys(e.properties).length, 50);
  assert.equal(e.properties.extra, undefined);
  assert.equal(e.properties.g0, "yeni");
  c.clearGlobalProperties();
  assert.equal(c.track("y").properties, undefined);
  c.setGlobalProperties({ a: 1 });
  c.reset();
  assert.equal(c.track("z").properties, undefined);
});

test("global özellik ve olay özelliği birlikte şema sınırını (100) aşmaz", async () => {
  const { c, calls } = client();
  c.setGlobalProperties(Object.fromEntries(Array.from({ length: 50 }, (_, i) => [`g${i}`, i])));
  const e = c.track("big", Object.fromEntries(Array.from({ length: 80 }, (_, i) => [`p${i}`, i])));
  assert.equal(Object.keys(e.properties).length, 100);
  await c.flush();
  assert.equal(validateBatch(JSON.parse(calls[0].init.body)), true, JSON.stringify(validateBatch.errors));
});

test("modül düzeyi işlevler singleton üzerinden çalışır", () => {
  const storage = mem();
  sdk.initialize({ projectKey: "pk_test_profile2", collectUrl: "http://c", consent: { analytics: true }, fetch: async () => ({ status: 202, json: async () => ({}) }), storage, flushIntervalMs: 0, autoTrack: false });
  sdk.setGlobalProperties({ app_release: "1" });
  assert.equal(sdk.track("a").properties.app_release, "1");
  sdk.clearGlobalProperties();
  assert.equal(sdk.track("b").properties, undefined);
  assert.equal(sdk.group("team-1").event_name, "fr_group");
  assert.equal(sdk.setUserProperties({ plan: "x" }).event_name, "fr_user_properties");
});
