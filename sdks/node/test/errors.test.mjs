// captureError (`fr_error`) birim testleri: sözleşme alanları, PII temizliği, parmak izi kararlılığı, sınır ve izin kapısı.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { ErrorLimiter, FeralinClient, buildErrorProperties, fnv1a64, normalizeFrames, scrubErrorMessage, sourcePositions } from "../dist/esm/index.js";

const require = createRequire(import.meta.url);
const Ajv2020 = require("ajv/dist/2020").default;
const addFormats = require("ajv-formats").default ?? require("ajv-formats");
const eventSchema = JSON.parse(readFileSync(new URL("../../../packages/schemas/utp/v1/event.schema.json", import.meta.url), "utf8"));
const ajv = new Ajv2020({ strict: false });
addFormats(ajv);
const validateEvent = ajv.compile(eventSchema);

const KEY = "pk_test_node_errors_01";
const STACK = [
  "TypeError: Cannot read properties of undefined (reading 'id')",
  "    at loadOrder (/home/deploy/app/src/orders.js:42:17)",
  "    at async Router.handle [as handler] (/home/deploy/app/node_modules/express/lib/router.js:120:5)",
  "    at process.processTicksAndRejections (node:internal/process/task_queues:95:5)",
].join("\n");

function client(extra = {}) {
  return new FeralinClient({ projectKey: KEY, collectUrl: "http://collector.test", flushIntervalMs: 0, fetch: async () => new Response("", { status: 202 }), consent: { analytics: true }, ...extra });
}

test("fnv1a64 Web SDK ile aynı değeri üretir", () => {
  assert.equal(fnv1a64(""), "cbf29ce484222325");
  assert.equal(fnv1a64("a"), "af63dc4c8601ec8c");
});

test("mesaj temizliği: URL, e-posta, UUID, belirteç ve uzun sayı etiketlenir, 200 karaktere kırpılır", () => {
  const out = scrubErrorMessage("fail https://x.example.com/a?b=1 for ali@example.com id 123e4567-e89b-12d3-a456-426614174000 tok abcdefghijklmnopqrstuvwx1234 tel +90 555 123 45 67 v1.4.2");
  assert.equal(out, "fail [url] for [email] id [id] tok [token] tel [num] v1.4.2");
  assert.equal(scrubErrorMessage("x".repeat(500)).length, 200);
});

test("çerçeveler: işlev@dosya, dizin ve satır yok, Node iç çerçeveleri atlanır", () => {
  assert.deepEqual(normalizeFrames(STACK), ["loadOrder@orders.js", "Router.handle@router.js"]);
  const positions = sourcePositions(STACK);
  assert.deepEqual(positions[0], { file: "orders.js", line: 42, column: 17, function: "loadOrder" });
  assert.equal(positions.length, 2);
});

test("gövde: sözleşme alanları, yığın izi ve yol gitmez", () => {
  const error = new TypeError("Cannot read user ali@example.com");
  error.stack = STACK;
  const props = buildErrorProperties(error, "handled", { appVersion: "2.3.1" });
  assert.equal(props.error_type, "TypeError");
  assert.equal(props.message, "Cannot read user [email]");
  assert.match(props.fingerprint, /^[0-9a-f]{16}$/);
  assert.equal(props.top_frame, "loadOrder@orders.js");
  assert.equal(props.frame_count, 2);
  assert.equal(props.app_version, "2.3.1");
  assert.equal(props.handled, true);
  assert.equal(props.fatal, false);
  assert.equal(props.origin, "handled");
  assert.ok(!JSON.stringify(props).includes("/home/deploy"));
  assert.equal(buildErrorProperties(error, "handled", { appVersion: "x".repeat(33) }).app_version, undefined);
  assert.equal(buildErrorProperties(error, "handled", { sourcePositions: false }).frames, undefined);
});

test("parmak izi satır kaymasından ve mesajdaki sayılardan etkilenmez", () => {
  const a = buildErrorProperties({ name: "Error", message: "x", stack: STACK }, "handled");
  const b = buildErrorProperties({ name: "Error", message: "y", stack: STACK.replace(":42:17", ":99:3") }, "handled");
  assert.equal(a.fingerprint, b.fingerprint);
  const c = buildErrorProperties("timeout after 30 ms", "manual");
  const d = buildErrorProperties("timeout after 45 ms", "manual");
  assert.equal(c.fingerprint, d.fingerprint);
  assert.equal(c.error_type, "Error");
});

test("captureError şemadan geçer, izinsiz olay ve sayaç harcanmaz", () => {
  const c = client({ consent: { analytics: false }, errors: { maxEvents: 1 } });
  const error = new Error("boom");
  assert.equal(c.captureError(error), null);
  c.setConsent({ analytics: true });
  const event = c.captureError(error, { userId: "u_1" });
  assert.ok(event);
  assert.equal(event.event_name, "fr_error");
  assert.equal(event.user_id, "u_1");
  assert.equal(validateEvent(event), true, JSON.stringify(validateEvent.errors));
  assert.ok(!("stack" in event.properties));
});

test("captureError: köken ve ölümcüllük, geçersiz köken handled olur", () => {
  const c = client();
  const fatal = c.captureError(new RangeError("x"), { origin: "uncaught_exception", fatal: true });
  assert.equal(fatal.properties.origin, "uncaught_exception");
  assert.equal(fatal.properties.handled, false);
  assert.equal(fatal.properties.fatal, true);
  const odd = c.captureError(new RangeError("y"), { origin: "bogus" });
  assert.equal(odd.properties.origin, "handled");
});

test("sınır: aynı parmak izi en çok 3, toplam en çok 20; pencere dolunca sıfırlanır", () => {
  let now = 1_000;
  const limiter = new ErrorLimiter({ windowMs: 60_000 }, () => now);
  assert.deepEqual([1, 2, 3, 4].map(() => limiter.allow("a")), [true, true, true, false]);
  for (let i = 0; i < 17; i++) assert.equal(limiter.allow(`f${i}`), true);
  assert.equal(limiter.allow("yeni"), false);
  now += 60_000;
  assert.equal(limiter.allow("a"), true);
  const sampled = new ErrorLimiter({ sampleRate: 0.5 }, () => 0, () => 0.9);
  assert.equal(sampled.allow("x"), false);
});

test("captureError fırlatmaz; app_version istemci ayarından", () => {
  const c = client({ errors: { appVersion: "9.9.9" } });
  const weird = { get message() { throw new Error("getter"); } };
  assert.doesNotThrow(() => c.captureError(weird));
  assert.equal(c.captureError(null)?.properties.error_type, "Error");
  assert.equal(c.captureError(new Error("v"))?.properties.app_version, "9.9.9");
});

test("installCode: biçime uyan kod ilk uygun olaya bir kez eklenir; fr_error atlanır, geçersiz kod yok sayılır", () => {
  const c = client({ installCode: " 7K3M-9QX2-PA " });
  const error = c.captureError(new Error("ilk"));
  assert.equal("fr_install_code" in error.properties, false);
  const first = c.track("app_opened", { a: 1 });
  assert.equal(first.properties.fr_install_code, "7K3M-9QX2-PA");
  assert.equal(validateEvent(first), true);
  assert.equal("fr_install_code" in (c.track("app_opened", { a: 1 }).properties ?? {}), false);
  const full = client({ installCode: "7K3M9QX2PA" });
  const props = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`p${i}`, i]));
  const big = full.track("big_event", props);
  assert.equal(Object.keys(big.properties).length, 100);
  assert.equal(big.properties.fr_install_code, "7K3M9QX2PA");
  assert.equal("fr_install_code" in (client({ installCode: "ILOU-ILOU-IL" }).track("x_event", { a: 1 }).properties), false);
});
