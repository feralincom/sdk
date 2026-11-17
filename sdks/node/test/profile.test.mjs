// Kimlik yöntemleri (UTP §8.2): group, setUserProperties, setGlobalProperties. Kurallar toplayıcının profile_filter.go dosyasıyla aynıdır.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { FeralinClient, isPIILikeKey } from "../dist/esm/index.js";

const require = createRequire(import.meta.url);
const Ajv2020 = require("ajv/dist/2020").default;
const addFormats = require("ajv-formats").default ?? require("ajv-formats");

const ajv = new Ajv2020({ strict: false });
addFormats(ajv);
ajv.addSchema(JSON.parse(readFileSync(new URL("../../../packages/schemas/utp/v1/event.schema.json", import.meta.url), "utf8")));
const validateBatch = ajv.compile(JSON.parse(readFileSync(new URL("../../../packages/schemas/utp/v1/batch.schema.json", import.meta.url), "utf8")));

function client(warnings = []) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push(JSON.parse(init.body));
    return new Response(JSON.stringify({ batch_id: "b1", accepted: 1, rejected: 0 }), { status: 202 });
  };
  const c = new FeralinClient({
    projectKey: "pk_test_node_profile_01",
    collectUrl: "http://collector.test",
    flushIntervalMs: 0,
    fetch,
    consent: { analytics: true },
    logger: { warn: (message, fields) => warnings.push({ message, fields }) },
  });
  return { c, calls };
}

test("PII'ye benzeyen anahtar kuralı toplayıcıyla aynı", () => {
  for (const key of ["email", "userEmail", "phoneNumber", "ip", "userIP", "ipv6", "firstName", "last_name", "name", "username", "displayName", "isim", "ad", "adSoyad", "eposta", "telefon", "home_address", "birthDate", "dob", "tckn", "iban"]) {
    assert.equal(isPIILikeKey(key), true, key);
  }
  for (const key of ["plan", "tier", "zip_bucket", "hotel_class", "membership", "plan_name", "ad_network", "signup_week"]) {
    assert.equal(isPIILikeKey(key), false, key);
  }
});

test("setUserProperties: kimlik options ile, düşen anahtarlar uyarıya yalnız adla yazılır", () => {
  const warnings = [];
  const { c } = client(warnings);
  const e = c.setUserProperties(
    { plan: "pro", tier: 2, email: "a@b.co", verified: true, note: "x".repeat(257), contact: "biri@example.com", nested: {}, nothing: null, inf: Infinity },
    { userId: "u_1", anonymousId: "anon_1" },
  );
  assert.equal(e.event_name, "fr_user_properties");
  assert.equal(e.user_id, "u_1");
  assert.equal(e.anonymous_id, "anon_1");
  assert.deepEqual(e.properties, { plan: "pro", tier: 2 });
  const dropped = warnings.find((w) => w.message === "özellik düştü");
  assert.ok(dropped);
  assert.ok(dropped.fields.dropped.includes("email:pii_like"));
  assert.ok(dropped.fields.dropped.includes("verified:reserved"));
  assert.ok(!JSON.stringify(warnings).includes("a@b.co"), "değer loga yazılmamalı");
});

test("setUserProperties: geçerli özellik yoksa null, en çok 50 özellik", () => {
  const { c } = client();
  assert.equal(c.setUserProperties({ phone: "1" }), null);
  const e = c.setUserProperties(Object.fromEntries(Array.from({ length: 70 }, (_, i) => [`k${i}`, i])));
  assert.equal(Object.keys(e.properties).length, 50);
});

test("group: geçerli kimlikle fr_group, geçersizde null", async () => {
  const { c, calls } = client();
  const e = c.group("acme-team", { plan: "team", phone: "1", group_id: "spoof" }, { userId: "u_1" });
  assert.equal(e.event_name, "fr_group");
  assert.deepEqual(e.properties, { plan: "team", group_id: "acme-team" });
  for (const bad of ["", " ", "a".repeat(129), "x@y.z", "a\nb", null, 5]) assert.equal(c.group(bad), null);
  assert.equal(c.getStatus().queued, 1);
  await c.flush();
  assert.equal(validateBatch(calls[0]), true, JSON.stringify(validateBatch.errors));
});

test("global özellikler: birleşir, olay özelliği ezer, null siler, fr_ olaylarına eklenmez, 50 sınırı", () => {
  const { c } = client();
  c.setGlobalProperties({ app_release: "e2e", plan: "free", email: "x@y.zz" });
  const a = c.track("signup", { plan: "pro" });
  assert.deepEqual(a.properties, { plan: "pro", app_release: "e2e" });
  c.setGlobalProperties({ plan: null });
  assert.deepEqual(c.track("open").properties, { app_release: "e2e" });
  assert.deepEqual(c.group("g1").properties, { group_id: "g1" });
  assert.deepEqual(c.setUserProperties({ tier: 1 }).properties, { tier: 1 });
  c.clearGlobalProperties();
  c.setGlobalProperties(Object.fromEntries(Array.from({ length: 55 }, (_, i) => [`g${i}`, i])));
  assert.equal(Object.keys(c.track("x").properties).length, 50);
  c.reset();
  assert.equal(c.track("y").properties, undefined);
});

test("global ve olay özellikleri birlikte şema sınırını aşmaz", async () => {
  const { c, calls } = client();
  c.setGlobalProperties(Object.fromEntries(Array.from({ length: 50 }, (_, i) => [`g${i}`, i])));
  const e = c.track("big", Object.fromEntries(Array.from({ length: 90 }, (_, i) => [`p${i}`, i])));
  assert.equal(Object.keys(e.properties).length, 100);
  await c.flush();
  assert.equal(validateBatch(calls[0]), true, JSON.stringify(validateBatch.errors));
});
