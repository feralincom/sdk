// Replay/heatmap modülü birim testleri (F4-E02-T02): maskeleme kapatılamaz ve metin/değer okumaz, izin kapısı çift,
// olay gövdesi toplayıcının izin listesine birebir uyar, görünüm alanı sınıf olarak gider, kaydırma derinliği 10'luk adımdır.
import test from "node:test";
import assert from "node:assert/strict";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
execFileSync(process.execPath, [join(root, "scripts/build.mjs")], { stdio: "pipe" });
const replay = await import(join(root, "dist/feralin-replay.mjs").replace(/\\/g, "/").replace(/^([A-Za-z]):/, "file:///$1:"));

/** Yalnız modülün dokunduğu kadar DOM: etiket, öznitelik, kardeş ve ata ilişkisi. Metin ve değer alanları bilerek tuzaklıdır. */
class FakeElement {
  constructor(tag, attrs = {}, children = []) {
    this.tagName = tag.toUpperCase();
    this.attrs = attrs;
    this.children = children;
    this.parentElement = null;
    this.textContent = "GİZLİ METİN";
    this.innerText = "GİZLİ METİN";
    this.value = "gizli-deger";
    for (const child of children) child.parentElement = this;
  }
  getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; }
  hasAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name); }
  get previousElementSibling() {
    if (!this.parentElement) return null;
    const siblings = this.parentElement.children;
    const index = siblings.indexOf(this);
    return index > 0 ? siblings[index - 1] : null;
  }
}
globalThis.Element = FakeElement;

function listenerBag() {
  const map = new Map();
  return {
    map,
    addEventListener(type, fn) { map.set(type, [...(map.get(type) ?? []), fn]); },
    removeEventListener(type, fn) { map.set(type, (map.get(type) ?? []).filter((f) => f !== fn)); },
    fire(type, event) { for (const fn of map.get(type) ?? []) fn(event); },
  };
}

function fakeWorld({ width = 800, height = 600, scrollHeight = 3000 } = {}) {
  const body = new FakeElement("body");
  const html = new FakeElement("html", {}, [body]);
  const docBag = listenerBag();
  const winBag = listenerBag();
  const doc = {
    documentElement: { clientWidth: width, clientHeight: height, scrollHeight, scrollTop: 0 },
    body: { scrollHeight },
    querySelectorAll: () => [],
    ...docBag,
  };
  const win = { innerWidth: width, innerHeight: height, scrollY: 0, ...winBag };
  return { doc, win, body, html };
}

function fakeClient(consent) {
  const events = [];
  return {
    events,
    consent,
    track(name, props) { events.push({ name, props }); return { event_name: name }; },
    getStatus() { return { consent: this.consent }; },
  };
}

test("maskedSelector: yalnız etiket, güvenli id ve nth-of-type; sınıf, metin, href ve değer hiç yazılmaz", () => {
  const button = new FakeElement("button", { class: "btn primary", "data-user": "ali@example.test" });
  const span = new FakeElement("span", { class: "x" });
  const li2 = new FakeElement("li", {}, [span]);
  const ul = new FakeElement("ul", {}, [new FakeElement("li"), li2, new FakeElement("li")]);
  const main = new FakeElement("main", { id: "app" }, [ul, button]);
  new FakeElement("body", {}, [main]);
  assert.equal(replay.maskedSelector(span), "main#app > ul:nth-of-type(1) > li:nth-of-type(2) > span");
  assert.equal(replay.maskedSelector(button), "main#app > button:nth-of-type(1)");
  // Sipariş numarası ya da e-posta gibi görünen id düşer, zincir yukarı devam eder.
  const risky = new FakeElement("div", { id: "order-12345678" });
  const wrap = new FakeElement("section", { id: "pricing" }, [risky]);
  assert.equal(replay.maskedSelector(risky), "section#pricing > div");
  assert.equal(replay.maskedSelector(new FakeElement("div", { id: "user@site" })), "div");
  void wrap;
});

test("maskedSelector: data-fr-mask zinciri keser, form öğeleri yalnız tür yazar, uzunluk sınırlıdır", () => {
  const input = new FakeElement("input", { type: "password", name: "pwd", value: "s3cret" });
  const form = new FakeElement("form", { "data-fr-mask": "" }, [input]);
  const main = new FakeElement("main", {}, [form]);
  void main;
  assert.equal(replay.maskedSelector(input), "input[type=password]");
  const inner = new FakeElement("span");
  const masked = new FakeElement("div", { "data-fr-mask": "" }, [inner]);
  new FakeElement("main", {}, [masked]);
  assert.equal(replay.maskedSelector(inner), "[masked] > span");
  const textarea = new FakeElement("textarea");
  new FakeElement("div", {}, [textarea]);
  assert.equal(replay.maskedSelector(textarea), "textarea");
  // Derin ağaç: en çok 6 ata, en çok 200 karakter.
  let el = new FakeElement("i");
  let cur = el;
  for (let i = 0; i < 12; i++) { const parent = new FakeElement("custom-elementname-longtag", {}, [new FakeElement("b"), cur]); cur = parent; }
  const selector = replay.maskedSelector(el);
  assert.ok(selector.length <= replay.SELECTOR_MAX_LENGTH);
  assert.ok(!/GİZLİ|gizli|s3cret|btn|example/.test(selector));
});

test("viewportClass piksel yerine sınıf verir", () => {
  assert.deepEqual([320, 600, 800, 1100, 1900].map(replay.viewportClass), ["xs", "sm", "md", "lg", "xl"]);
});

test("izin kapısı: session_replay yoksa ya da false ise tıklama ve kaydırma olayı üretilmez, DOM okunmaz; izin gelince akar, geri çekilince durur", () => {
  const { doc, win, body } = fakeWorld();
  const client = fakeClient({ analytics: true });
  const handle = replay.startReplay({ client, document: doc, window: win });
  const target = new FakeElement("button", { id: "cta" });
  body.children.push(target); target.parentElement = body;
  let reads = 0;
  Object.defineProperty(target, "tagName", { get() { reads++; return "BUTTON"; } });
  doc.fire("click", { target, clientX: 400, clientY: 300 });
  win.scrollY = 1500; win.fire("scroll");
  assert.equal(client.events.length, 0);
  assert.equal(reads, 0, "izin yokken DOM okunmamalı");
  client.consent = { analytics: true, session_replay: true };
  doc.fire("click", { target, clientX: 400, clientY: 300 });
  assert.deepEqual(client.events[0], { name: "fr_replay_click", props: { sel: "button#cta", x: 50, y: 50, vp: "md" } });
  client.consent = { analytics: true, session_replay: false };
  doc.fire("click", { target, clientX: 10, clientY: 10 });
  assert.equal(client.events.length, 1, "izin geri çekilince olay durmalı");
  // Analitik izni yokken replay izni tek başına yetmez.
  client.consent = { analytics: false, session_replay: true };
  doc.fire("click", { target, clientX: 10, clientY: 10 });
  assert.equal(client.events.length, 1);
  handle.stop();
});

test("kaydırma: en derin yüzde 10'luk adımla, aynı derinlik iki kez gitmez; stop son derinliği gönderir", async () => {
  const { doc, win } = fakeWorld({ height: 600, scrollHeight: 3000 });
  const client = fakeClient({ analytics: true, session_replay: true });
  const handle = replay.startReplay({ client, document: doc, window: win });
  win.scrollY = 600; win.fire("scroll");
  await new Promise((resolve) => setTimeout(resolve, 600));
  assert.deepEqual(client.events.at(-1), { name: "fr_replay_scroll", props: { depth: 40, vp: "md" } });
  win.scrollY = 500; win.fire("scroll");
  await new Promise((resolve) => setTimeout(resolve, 600));
  assert.equal(client.events.filter((e) => e.name === "fr_replay_scroll").length, 1, "daha sığ kaydırma yeni olay üretmez");
  win.scrollY = 2400; win.fire("scroll");
  handle.stop();
  assert.deepEqual(client.events.at(-1), { name: "fr_replay_scroll", props: { depth: 100, vp: "md" } });
  // stop sonrası dinleyici yok.
  win.fire("scroll"); doc.fire("click", { target: new FakeElement("a"), clientX: 0, clientY: 0 });
  assert.equal(client.events.length, 2);
});

test("olay gövdeleri toplayıcı izin listesiyle birebir: yalnız sel/x/y/vp ve depth/vp anahtarları", () => {
  const { doc, win, body } = fakeWorld();
  const client = fakeClient({ analytics: true, session_replay: true });
  const handle = replay.startReplay({ client, document: doc, window: win });
  const target = new FakeElement("a", { href: "https://example.test/?token=abc" });
  body.children.push(target); target.parentElement = body;
  doc.fire("click", { target, clientX: 1200, clientY: -5 });
  const click = client.events[0];
  assert.deepEqual(Object.keys(click.props).sort(), ["sel", "vp", "x", "y"]);
  assert.equal(click.props.x, 100, "koordinat 0..100 aralığına kırpılır");
  assert.equal(click.props.y, 0);
  assert.ok(!JSON.stringify(click.props).includes("token"));
  handle.stop();
});
