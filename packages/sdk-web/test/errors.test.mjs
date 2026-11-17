// Hata yakalama modülü birim testleri (X4): yığın izi normalize edilir ve gitmez, parmak izi kararlıdır, PII mesajdan temizlenir,
// örnekleme ve sınırlar uygulanır, olay gövdesi toplayıcı sözleşmesine (fr_error) uyar.
import test from "node:test";
import assert from "node:assert/strict";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
execFileSync(process.execPath, [join(root, "scripts/build.mjs")], { stdio: "pipe" });
const errors = await import(join(root, "dist/feralin-errors.mjs").replace(/\\/g, "/").replace(/^([A-Za-z]):/, "file:///$1:"));

const CHROME_STACK = `TypeError: x is undefined
    at submitOrder (https://cdn.example.com/assets/checkout.3f9a1b2c.js:10:20)
    at HTMLButtonElement.onClick (https://cdn.example.com/assets/app.js?v=12:5:3)`;
const FIREFOX_STACK = `submitOrder@https://cdn.example.com/assets/checkout.3f9a1b2c.js:10:20
onClick@https://cdn.example.com/assets/app.js?v=12:5:3`;

function fakeWindow() {
  const handlers = new Map();
  return {
    handlers,
    addEventListener(type, fn) { handlers.set(type, [...(handlers.get(type) ?? []), fn]); },
    removeEventListener(type, fn) { handlers.set(type, (handlers.get(type) ?? []).filter((f) => f !== fn)); },
    fire(type, event) { for (const fn of handlers.get(type) ?? []) fn(event); },
  };
}

function fakeClient() {
  const events = [];
  return { events, track(name, props) { events.push({ name, props }); return null; }, getStatus() { return { consent: { analytics: true } }; } };
}

test("yığın izi normalize edilir: satır, sütun, sorgu, derleme özeti ve dizin gitmez", () => {
  for (const stack of [CHROME_STACK, FIREFOX_STACK]) {
    const frames = errors.normalizeFrames(stack);
    assert.deepEqual(frames.slice(0, 2), ["submitOrder@checkout.js", frames[1]]);
    assert.ok(frames[1].endsWith("@app.js"), frames[1]);
    for (const frame of frames) assert.doesNotMatch(frame, /\d{2,}|https?:|\?|3f9a1b2c/);
  }
});

test("aynı hata kod kaysa da aynı parmak izini üretir; farklı hata farklı parmak izi", () => {
  const a = errors.buildErrorProperties({ name: "TypeError", message: "x is undefined", stack: CHROME_STACK }, "window_onerror");
  const shifted = CHROME_STACK.replace(":10:20", ":99:7").replace("3f9a1b2c", "aabbccdd");
  const b = errors.buildErrorProperties({ name: "TypeError", message: "x is undefined", stack: shifted }, "window_onerror");
  assert.equal(a.fingerprint, b.fingerprint);
  assert.match(a.fingerprint, /^[0-9a-f]{16}$/);
  const c = errors.buildErrorProperties({ name: "RangeError", message: "x is undefined", stack: CHROME_STACK }, "window_onerror");
  assert.notEqual(a.fingerprint, c.fingerprint);
  assert.equal(a.top_frame, "submitOrder@checkout.js");
  assert.equal(a.fatal, false);
  assert.equal(a.handled, false);
});

test("mesajdaki e-posta, URL, uzun sayı ve belirteç temizlenir; ham yığın olaya girmez", () => {
  const props = errors.buildErrorProperties({ name: "Error", message: "ali@example.com sipariş 5551234567 https://x.test/a?t=1 eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", stack: CHROME_STACK }, "window_onerror");
  assert.doesNotMatch(props.message, /ali@|5551234567|x\.test|eyJ/);
  assert.match(props.message, /\[email\]/);
  assert.equal(Object.hasOwn(props, "stack"), false);
  assert.ok(props.message.length <= 200);
});

test("olay gövdesi toplayıcı şemasına (fr_error) uyar", () => {
  const ajv = new Ajv2020({ strict: true, allErrors: true });
  addFormats(ajv);
  ajv.addSchema(JSON.parse(readFileSync(join(root, "../schemas/utp/v1/event.schema.json"), "utf8")));
  const validate = ajv.compile(JSON.parse(readFileSync(join(root, "../schemas/utp/v1/batch.schema.json"), "utf8")));
  const props = errors.buildErrorProperties(new TypeError("boom"), "window_onerror", "1.4.2");
  const event = { event_id: "01JBX5Z8K3Q9R7T2V4W6Y8A0BC", event_name: "fr_error", occurred_at: "2026-11-03T10:00:00Z", platform: "web", schema_version: 1, consent: { analytics: true }, properties: props };
  assert.equal(validate({ events: [event] }), true, JSON.stringify(validate.errors));
  assert.equal(props.app_version, "1.4.2");
});

test("window error ve unhandledrejection dinlenir; kapatılınca susar", () => {
  const win = fakeWindow();
  const client = fakeClient();
  const handle = errors.captureErrors({ client, window: win, appVersion: "2.0.0" });
  win.fire("error", { error: Object.assign(new TypeError("a"), { stack: CHROME_STACK }) });
  win.fire("unhandledrejection", { reason: new Error("b") });
  win.fire("unhandledrejection", { reason: "düz metin neden" });
  assert.equal(client.events.length, 3);
  assert.ok(client.events.every((e) => e.name === "fr_error"));
  assert.deepEqual(client.events.map((e) => e.props.origin), ["window_onerror", "unhandledrejection", "unhandledrejection"]);
  assert.equal(client.events[2].props.error_type, "UnhandledRejection");
  handle.stop();
  win.fire("error", { error: new Error("c") });
  assert.equal(client.events.length, 3);
});

test("çapraz kaynaklı betik hatası (error alanı boş) dosya adından parmak izi üretir", () => {
  const win = fakeWindow();
  const client = fakeClient();
  errors.captureErrors({ client, window: win });
  win.fire("error", { error: null, message: "Script error.", filename: "https://thirdparty.example/lib.min.4f3e2d1c.js" });
  const props = client.events[0].props;
  assert.equal(props.error_type, "ScriptError");
  assert.equal(props.top_frame, "<anonymous>@lib.min.js");
});

test("sınırlar: aynı parmak izi en çok 3, toplam en çok maxEvents; örnekleme uygulanır", () => {
  const win = fakeWindow();
  const client = fakeClient();
  errors.captureErrors({ client, window: win, maxEvents: 4 });
  const same = Object.assign(new TypeError("a"), { stack: CHROME_STACK });
  for (let i = 0; i < 10; i++) win.fire("error", { error: same });
  assert.equal(client.events.length, 3);
  for (let i = 0; i < 10; i++) win.fire("error", { error: Object.assign(new Error(`e${i}`), { stack: `at f${i} (https://a.test/x${i}.js:1:1)` }) });
  assert.equal(client.events.length, 4);

  const sampledClient = fakeClient();
  const sampledWin = fakeWindow();
  errors.captureErrors({ client: sampledClient, window: sampledWin, sampleRate: 0.5, random: () => 0.9 });
  sampledWin.fire("error", { error: new Error("x") });
  assert.equal(sampledClient.events.length, 0);
});

test("elle bildirim: handled true ve origin handled", () => {
  const client = fakeClient();
  const handle = errors.captureErrors({ client, window: fakeWindow() });
  assert.equal(handle.capture(new RangeError("kapsam")), true);
  assert.equal(client.events[0].props.handled, true);
  assert.equal(client.events[0].props.origin, "handled");
});
