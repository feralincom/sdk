// Sayfada görünür süre ölçümü (fr_page_engagement) birim testleri: yalnız görünür süre sayılır, gizli süre sayılmaz, olay sayfa
// gizlenince gönderimden önce kuyruğa girer, sonraki page_view'dan önce ÖNCEKİ sayfanın adresi ve başlığıyla yazılır, bir saniyenin
// altındaki birikim devreder, izin yokken olay üretilmez ve `pageEngagement: false` ölçümü kapatır.
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
const ajv = new Ajv2020({ strict: true, allErrors: true }); addFormats(ajv);
ajv.addSchema(JSON.parse(readFileSync(join(schemasRoot, "event.schema.json"), "utf8")));
const validateBatch = ajv.compile(JSON.parse(readFileSync(join(schemasRoot, "batch.schema.json"), "utf8")));

const NAME = "fr_page_engagement";
const QUEUE_KEY = "fr_q_pk_test_abc";

/** Sahte tarayıcı ve dondurulmuş saat: yalnız `advance` Date.now'ı ilerletir, `hide`/`show` görünürlüğü değiştirip dinleyicileri koşturur. */
function setup(t, options = {}) {
  const registry = [];
  const on = (type, listener) => { registry.push({ type, listener }); };
  const off = (type, listener) => {
    const at = registry.findIndex((item) => item.type === type && item.listener === listener);
    if (at >= 0) registry.splice(at, 1);
  };
  const fake = {
    window: { addEventListener: on, removeEventListener: off, innerWidth: 800, innerHeight: 600 },
    document: { title: "İlk sayfa", referrer: "", visibilityState: "visible", addEventListener: on, removeEventListener: off },
    location: { href: "https://site.example/ilk?utm_source=google&token=GIZLI" },
  };
  const saved = {};
  for (const [k, v] of Object.entries(fake)) {
    saved[k] = Object.getOwnPropertyDescriptor(globalThis, k);
    Object.defineProperty(globalThis, k, { value: v, configurable: true, writable: true });
  }
  const realNow = Date.now;
  // Saat dondurulur: gerçek zamanın ilerlemesi milisaniyelik beklentileri oynatmasın.
  const base = realNow();
  let offset = 0;
  Date.now = () => base + offset;
  t.after(() => {
    Date.now = realNow;
    for (const k of Object.keys(fake)) {
      if (saved[k]) Object.defineProperty(globalThis, k, saved[k]);
      else delete globalThis[k];
    }
  });
  const store = new Map();
  const storage = { get: (k) => store.get(k) ?? null, set: (k, v) => store.set(k, v), remove: (k) => store.delete(k) };
  const calls = [];
  const fetch = async (url, init) => { calls.push({ url, init }); return { status: 202, json: async () => ({}) }; };
  const client = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", flushIntervalMs: 0, consent: { analytics: true }, fetch, storage, ...options });
  const fire = (type) => { for (const item of [...registry]) if (item.type === type) item.listener(); };
  return {
    client, calls, fake, registry,
    advance(ms) { offset += ms; },
    hide() { fake.document.visibilityState = "hidden"; fire("visibilitychange"); },
    show() { fake.document.visibilityState = "visible"; fire("visibilitychange"); },
    pagehide() { fire("pagehide"); },
    navigate(href, title) { fake.location.href = href; fake.document.title = title; },
    /** Depodaki kuyruk: üretilen ama henüz onaylanmamış olaylar. */
    queued() { return JSON.parse(store.get(QUEUE_KEY) ?? "[]"); },
    sent() { return calls.flatMap((c) => JSON.parse(c.init.body).events); },
  };
}
const engagement = (events) => events.filter((e) => e.event_name === NAME);
const settle = () => new Promise((resolve) => setTimeout(resolve, 5));

test("sabitler dışa aktarılır", () => {
  assert.equal(sdk.PAGE_ENGAGEMENT_EVENT_NAME, NAME);
  assert.equal(sdk.PAGE_ENGAGEMENT_MAX_MS, 3_600_000);
  assert.equal(sdk.PAGE_ENGAGEMENT_MIN_MS, 1_000);
});

test("görünür süre sayılır ve sayfa gizlenince gönderimden önce kuyruğa girer: aynı istekle çıkar, şemaya uyar", async (t) => {
  const b = setup(t);
  b.advance(4200);
  b.hide();
  await settle();
  assert.equal(b.calls.length, 1, "page_view ve süre olayı tek istekte gitmeli");
  assert.equal(b.calls[0].init.keepalive, true);
  const body = JSON.parse(b.calls[0].init.body);
  assert.deepEqual(body.events.map((e) => e.event_name), ["page_view", NAME]);
  const [view, eng] = body.events;
  assert.deepEqual(eng.properties, { visible_ms: 4200 });
  assert.equal(eng.context.page_url, "https://site.example/ilk");
  assert.equal(eng.context.page_title, "İlk sayfa");
  assert.equal(eng.session_id, view.session_id);
  assert.equal(eng.anonymous_id, view.anonymous_id);
  assert.equal(validateBatch(body), true, JSON.stringify(validateBatch.errors));
  assert.equal(b.calls[0].init.body.includes("GIZLI"), false);
});

test("gizli süre sayılmaz; yeniden görünür olunca saat kaldığı yerden değil sıfırdan başlar", async (t) => {
  const b = setup(t);
  b.advance(2000);
  b.hide();
  b.advance(60_000);
  b.show();
  b.advance(3000);
  b.hide();
  await settle();
  assert.deepEqual(engagement(b.queued().concat(b.sent())).map((e) => e.properties.visible_ms).sort(), [2000, 3000]);
});

test("sayfa gizliyken izlenen page_view'da saat görünür olana dek başlamaz", (t) => {
  const b = setup(t, { autoTrack: false });
  b.fake.document.visibilityState = "hidden";
  b.client.page();
  b.advance(30_000);
  b.show();
  b.advance(1500);
  b.hide();
  assert.deepEqual(engagement(b.queued()).map((e) => e.properties.visible_ms), [1500]);
});

test("pagehide de süre olayını gönderimden önce yazar ve saati durdurur", async (t) => {
  const b = setup(t);
  b.advance(1800);
  b.pagehide();
  b.advance(50_000);
  b.hide();
  await settle();
  const first = JSON.parse(b.calls[0].init.body).events;
  assert.deepEqual(first.map((e) => e.event_name), ["page_view", NAME]);
  assert.equal(first[1].properties.visible_ms, 1800);
  assert.equal(engagement(b.sent().concat(b.queued())).length, 1, "pagehide sonrası geçen süre sayılmamalı");
});

test("sonraki page_view'dan önce önceki sayfanın adresi ve başlığıyla yazılır (SPA)", (t) => {
  const b = setup(t);
  b.advance(5000);
  // Yönlendirici adresi ve başlığı değiştirdikten sonra page() çağrılır.
  b.navigate("https://site.example/ikinci?utm_source=bulten", "İkinci sayfa");
  b.client.page();
  const events = b.queued();
  assert.deepEqual(events.map((e) => e.event_name), ["page_view", NAME, "page_view"]);
  const [, eng, next] = events;
  assert.deepEqual(eng.properties, { visible_ms: 5000 }, "yeni adresin utm değeri süre olayına eklenmemeli");
  assert.equal(eng.context.page_url, "https://site.example/ilk");
  assert.equal(eng.context.page_title, "İlk sayfa");
  assert.equal(next.context.page_url, "https://site.example/ikinci");
  assert.equal(next.context.page_title, "İkinci sayfa");
  // Yeni sayfanın saati sıfırdan başlar ve kendi bağlamını taşır.
  b.advance(2500);
  b.hide();
  const last = engagement(b.queued()).at(-1);
  assert.equal(last.properties.visible_ms, 2500);
  assert.equal(last.context.page_url, "https://site.example/ikinci");
  assert.equal(last.context.page_title, "İkinci sayfa");
});

test("bir saniyenin altındaki birikim gönderilmez, aynı sayfanın sonraki gönderimine devreder", (t) => {
  const b = setup(t);
  b.advance(600);
  b.hide();
  assert.equal(engagement(b.queued()).length, 0);
  b.advance(10_000);
  b.show();
  b.advance(700);
  b.hide();
  assert.deepEqual(engagement(b.queued()).map((e) => e.properties.visible_ms), [1300]);
  // Gönderilen süre yeniden sayılmaz.
  b.show();
  b.advance(400);
  b.hide();
  assert.equal(engagement(b.queued()).length, 1);
});

test("tek olay bir saate kırpılır", (t) => {
  const b = setup(t);
  b.advance(5 * 3_600_000);
  b.hide();
  assert.deepEqual(engagement(b.queued()).map((e) => e.properties.visible_ms), [3_600_000]);
});

test("oturum hareketsizlikten yenilense de süre olayı ölçülen page_view'ın oturumunu taşır ve oturumu uzatmaz", (t) => {
  const b = setup(t);
  const sessionId = b.client.getStatus().session_id;
  b.advance(sdk.SESSION_IDLE_MS + 60_000);
  b.hide();
  const [eng] = engagement(b.queued());
  assert.equal(eng.session_id, sessionId);
  const next = b.client.track("signup_completed");
  assert.notEqual(next.session_id, sessionId, "süre olayı oturumu canlı tutmamalı");
});

test("izin yokken süre olayı üretilmez; izin geri çekilince birikim silinir", async (t) => {
  const none = setup(t, { consent: { analytics: false } });
  none.advance(8000);
  none.hide();
  await settle();
  assert.equal(none.queued().length, 0);
  assert.equal(none.calls.length, 0);
});

test("izin geri çekilince birikim silinir: yeniden izin verilse de eski süre gönderilmez", async (t) => {
  const b = setup(t);
  b.advance(8000);
  b.client.setConsent({ analytics: false });
  b.advance(4000);
  b.hide();
  await settle();
  assert.equal(b.calls.length, 0);
  b.show();
  b.client.setConsent({ analytics: true });
  b.advance(4000);
  b.hide();
  await settle();
  assert.equal(engagement(b.sent().concat(b.queued())).length, 0, "izinsiz dönemin ve öncesinin süresi gitmemeli");
  // Yeni page_view ile ölçüm yeniden başlar.
  b.show();
  b.client.page();
  b.advance(2000);
  b.hide();
  assert.deepEqual(engagement(b.queued()).map((e) => e.properties.visible_ms), [2000]);
});

test("reset birikimi siler: süre yeni kimliğe bağlanmaz", (t) => {
  const b = setup(t);
  b.advance(8000);
  b.client.reset();
  b.advance(2000);
  b.hide();
  assert.equal(engagement(b.queued()).length, 0);
});

test("destroy sonrası süre olayı üretilmez", async (t) => {
  const b = setup(t);
  b.advance(8000);
  b.client.destroy();
  assert.equal(b.registry.length, 0);
  b.hide();
  b.client.page();
  await settle();
  assert.equal(engagement(b.queued()).length, 0);
  assert.equal(b.calls.length, 0);
});

test("pageEngagement: false ölçümü kapatır", async (t) => {
  const b = setup(t, { pageEngagement: false });
  b.advance(8000);
  b.navigate("https://site.example/ikinci", "İkinci sayfa");
  b.client.page();
  b.advance(8000);
  b.hide();
  b.pagehide();
  await settle();
  const names = b.sent().concat(b.queued()).map((e) => e.event_name);
  assert.deepEqual(names, ["page_view", "page_view"]);
});

test("global özellikler süre olayına eklenmez (fr_ kuralı)", (t) => {
  const b = setup(t);
  b.client.setGlobalProperties({ plan: "pro" });
  b.advance(3000);
  b.hide();
  assert.deepEqual(engagement(b.queued())[0].properties, { visible_ms: 3000 });
});

test("tarayıcı dışında (SSR/Node) page_view süre ölçümü başlatmaz", () => {
  const store = new Map();
  const storage = { get: (k) => store.get(k) ?? null, set: (k, v) => store.set(k, v), remove: (k) => store.delete(k) };
  const c = new sdk.Feralin({ projectKey: "pk_test_abc", collectUrl: "http://c", flushIntervalMs: 0, consent: { analytics: true }, fetch: async () => ({ status: 202, json: async () => ({}) }), storage });
  c.page();
  c.page();
  assert.deepEqual(JSON.parse(store.get(QUEUE_KEY)).map((e) => e.event_name), ["page_view", "page_view"]);
});
