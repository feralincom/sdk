// App Banner birim testleri (FAZ_DENETIMI madde 35): platform seçimi, seçenek doğrulama, DOM'a yalnız metin yazma,
// kapatma tercihi, ölçüm ve depolama yokluğu.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { gzipSync } from "node:zlib";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
execFileSync(process.execPath, [join(root, "scripts/build.mjs")], { stdio: "pipe" });
const banner = await import(join(root, "dist/feralin-banner.mjs").replace(/\\/g, "/").replace(/^([A-Za-z]):/, "file:///$1:"));

const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const ANDROID = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36";
const DESKTOP = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
const IPAD_DESKTOP = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

/** Yalnız şeridin kullandığı kadar DOM: öğe ağacı, öznitelik, stil, metin ve tıklama. */
function fakeDocument() {
  const element = (tag) => {
    const node = {
      tag,
      attributes: {},
      children: [],
      listeners: {},
      parent: null,
      textContent: "",
      innerHTMLWrites: 0,
      style: { rules: {}, setProperty(name, value) { this.rules[name] = value; } },
      setAttribute(name, value) { this.attributes[name] = String(value); },
      getAttribute(name) { return this.attributes[name] ?? null; },
      appendChild(child) { child.parent = this; this.children.push(child); return child; },
      addEventListener(type, handler) { this.listeners[type] = handler; },
      remove() { if (this.parent) this.parent.children = this.parent.children.filter((item) => item !== this); this.parent = null; },
      click() { this.listeners.click?.(); },
    };
    Object.defineProperty(node, "innerHTML", { set() { node.innerHTMLWrites += 1; }, get() { return ""; } });
    return node;
  };
  const body = element("body");
  const walk = (node, visit) => { visit(node); node.children.forEach((child) => walk(child, visit)); };
  return {
    body,
    createElement: element,
    querySelector(selector) {
      assert.equal(selector, "[data-feralin-banner]");
      let found = null;
      walk(body, (node) => { if (!found && "data-feralin-banner" in node.attributes) found = node; });
      return found;
    },
    all() { const nodes = []; walk(body, (node) => nodes.push(node)); return nodes; },
  };
}

const memory = () => { const map = new Map(); return { getItem: (key) => map.get(key) ?? null, setItem: (key, value) => map.set(key, value), map }; };
const data = { link: "https://go.example.test/yaz-indirimi", title: "Uygulamada daha hızlı", text: "Siparişlerinizi tek dokunuşla izleyin", cta: "Uygulamayı aç", closeLabel: "Kapat" };

test("platform yalnız User-Agent'tan okunur; masaüstü ve masaüstü kipindeki iPad tanınmaz", () => {
  assert.equal(banner.bannerPlatform(IPHONE), "ios");
  assert.equal(banner.bannerPlatform(ANDROID), "android");
  assert.equal(banner.bannerPlatform(DESKTOP), null);
  assert.equal(banner.bannerPlatform(IPAD_DESKTOP), null);
  assert.equal(banner.bannerPlatform(""), null);
});

test("seçenekler doğrulanır: yalnız https bağlantı, zorunlu alanlar, sınırlar ve varsayılanlar", () => {
  const options = banner.resolveBannerOptions(data);
  assert.deepEqual(options, { link: "https://go.example.test/yaz-indirimi", title: "Uygulamada daha hızlı", text: "Siparişlerinizi tek dokunuşla izleyin", cta: "Uygulamayı aç", closeLabel: "Kapat", platforms: ["ios", "android"], position: "bottom" });
  for (const link of ["javascript:alert(1)", "http://go.example.test/x", "//go.example.test/x", "data:text/html,x", "https://kullanici:parola@go.example.test/x", "", undefined, "intent://x"]) {
    assert.equal(banner.resolveBannerOptions({ ...data, link }), null, String(link));
  }
  assert.equal(banner.resolveBannerOptions({ ...data, title: "  " }), null);
  assert.equal(banner.resolveBannerOptions({ ...data, cta: undefined }), null);
  const trimmed = banner.resolveBannerOptions({ ...data, title: "a".repeat(200), text: "b".repeat(500), cta: "c".repeat(100), platforms: "Android, masaustu", position: "top", closeLabel: "" });
  assert.equal(trimmed.title.length, 60);
  assert.equal(trimmed.text.length, 120);
  assert.equal(trimmed.cta.length, 24);
  assert.deepEqual(trimmed.platforms, ["android"]);
  assert.equal(trimmed.position, "top");
  assert.equal(trimmed.closeLabel, "Kapat");
  // Görünmeyen biçim karakterleri atılır.
  assert.equal(banner.resolveBannerOptions({ ...data, title: "İndir‮​ şimdi" }).title, "İndir şimdi");
});

test("şerit hedef platformda çizilir: bölge rolü, bağlantı, kapatma düğmesi; içerik yalnız metin olarak yazılır", () => {
  const doc = fakeDocument();
  const hostile = banner.resolveBannerOptions({ ...data, title: "<img src=x onerror=alert(1)>", text: "<script>alert(1)</script>" });
  const node = banner.mountBanner(hostile, { document: doc, userAgent: IPHONE, storage: memory() });
  assert.ok(node);
  assert.equal(node.getAttribute("role"), "region");
  assert.equal(node.getAttribute("data-feralin-banner"), "ios");
  assert.equal(node.getAttribute("aria-label"), "<img src=x onerror=alert(1)>");
  assert.equal(doc.body.children.length, 1);
  const nodes = doc.all();
  // Hiçbir öğeye HTML yazılmaz; düşmanca metin etiket olarak değil metin olarak kalır.
  assert.equal(nodes.reduce((sum, item) => sum + item.innerHTMLWrites, 0), 0);
  assert.deepEqual(nodes.map((item) => item.tag), ["body", "div", "div", "strong", "span", "a", "button"]);
  assert.equal(nodes.find((item) => item.tag === "strong").textContent, "<img src=x onerror=alert(1)>");
  const link = nodes.find((item) => item.tag === "a");
  assert.equal(link.getAttribute("href"), "https://go.example.test/yaz-indirimi");
  assert.equal(link.getAttribute("rel"), "noopener");
  assert.equal(link.textContent, "Uygulamayı aç");
  const close = nodes.find((item) => item.tag === "button");
  assert.equal(close.getAttribute("type"), "button");
  assert.equal(close.getAttribute("aria-label"), "Kapat");
  assert.equal(node.style.rules.position, "fixed");
  assert.equal(node.style.rules.bottom, "0");
});

test("hedef dışı platformda, masaüstünde ve ikinci çağrıda şerit çizilmez", () => {
  const options = banner.resolveBannerOptions({ ...data, platforms: "android" });
  for (const userAgent of [IPHONE, DESKTOP, IPAD_DESKTOP]) {
    const doc = fakeDocument();
    assert.equal(banner.mountBanner(options, { document: doc, userAgent, storage: memory() }), null);
    assert.equal(doc.body.children.length, 0);
  }
  const doc = fakeDocument();
  assert.ok(banner.mountBanner(options, { document: doc, userAgent: ANDROID, storage: memory() }));
  assert.equal(banner.mountBanner(options, { document: doc, userAgent: ANDROID, storage: memory() }), null);
  assert.equal(doc.body.children.length, 1);
});

test("kapatma şeridi kaldırır ve tercih yalnız sekme deposunda tek anahtarla hatırlanır; depolama yoksa da çalışır", () => {
  const options = banner.resolveBannerOptions(data);
  const storage = memory();
  const doc = fakeDocument();
  const node = banner.mountBanner(options, { document: doc, userAgent: ANDROID, storage });
  // Gösterim depoya hiçbir şey yazmaz.
  assert.equal(storage.map.size, 0);
  doc.all().find((item) => item.tag === "button").click();
  assert.equal(doc.body.children.length, 0);
  assert.deepEqual([...storage.map.entries()], [[banner.BANNER_DISMISS_KEY, "1"]]);
  assert.equal(node.parent, null);
  // Aynı sekmede yeniden çizilmez.
  assert.equal(banner.mountBanner(options, { document: fakeDocument(), userAgent: ANDROID, storage }), null);
  // Depolama kapalı ya da hata veriyorsa şerit yine çizilir ve kapanır.
  const broken = { getItem() { throw new Error("kapalı"); }, setItem() { throw new Error("kapalı"); } };
  for (const store of [null, undefined, broken]) {
    const page = fakeDocument();
    assert.ok(banner.mountBanner(options, { document: page, userAgent: IPHONE, storage: store }));
    page.all().find((item) => item.tag === "button").click();
    assert.equal(page.body.children.length, 0);
  }
});

test("elle çağrıda da aynı denetim geçer: https olmayan bağlantı çizilmez, sınırı aşan metin kırpılır", () => {
  for (const link of ["javascript:alert(document.cookie)", "http://go.example.test/x", "data:text/html,<script>alert(1)</script>", "", undefined]) {
    const doc = fakeDocument();
    assert.equal(banner.mountBanner({ link, title: "Başlık", cta: "Aç", closeLabel: "Kapat", platforms: ["ios", "android"], position: "bottom" }, { document: doc, userAgent: IPHONE, storage: memory() }), null, String(link));
    assert.equal(doc.body.children.length, 0);
  }
  for (const broken of [null, undefined, {}, { link: "https://go.example.test/x" }, { link: "https://go.example.test/x", title: "Başlık" }]) {
    const doc = fakeDocument();
    assert.equal(banner.mountBanner(broken, { document: doc, userAgent: IPHONE, storage: memory() }), null);
  }
  const doc = fakeDocument();
  const node = banner.mountBanner({ link: "https://go.example.test/x", title: "a".repeat(300), cta: "Aç", platforms: "hepsi", position: "ust" }, { document: doc, userAgent: ANDROID, storage: memory() });
  assert.ok(node);
  assert.equal(doc.all().find((item) => item.tag === "strong").textContent.length, 60);
  assert.equal(doc.all().find((item) => item.tag === "a").getAttribute("href"), "https://go.example.test/x");
  assert.equal(node.style.rules.bottom, "0");
});

test("betik ölçüm yapmaz: ağ çağrısı, çerez, kalıcı depolama ve cihaz sinyali kullanmaz; boyut bütçesi içindedir", () => {
  const source = readFileSync(join(root, "dist/feralin-banner.iife.js"), "utf8");
  for (const forbidden of ["fetch(", "XMLHttpRequest", "sendBeacon", "document.cookie", "localStorage", "indexedDB", "navigator.platform", "deviceMemory", "hardwareConcurrency", "screen.", "canvas", "innerHTML", "eval("]) {
    assert.ok(!source.includes(forbidden), forbidden);
  }
  assert.ok(source.includes("sessionStorage"));
  assert.ok(gzipSync(Buffer.from(source)).length <= 3 * 1024);
  // Ölçüm SDK'sı şeritten bağımsızdır: şerit SDK'yı içermez.
  assert.ok(!source.includes("/v1/batch"));
});
