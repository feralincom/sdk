// Smart Script birim testleri (Adjust karşılaştırması madde 15): sayfadaki UTM ve tıklama kimlikleri kısa linke eklenir, linkin kendi
// parametresi korunur, geçersiz değer ve https olmayan link reddedilir, oturum boyunca parametre korunur, tıklama kimliği listesi link
// yönlendiricisinin taşıdığı listeyle birebir aynıdır.
import test from "node:test";
import assert from "node:assert/strict";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
execFileSync(process.execPath, [join(root, "scripts/build.mjs")], { stdio: "pipe" });
const toUrl = (p) => p.replace(/\\/g, "/").replace(/^([A-Za-z]):/, "file:///$1:");
const smart = await import(toUrl(join(root, "dist/feralin-smart.mjs")));

function memoryStorage() {
  const data = new Map();
  return { getItem: (k) => (data.has(k) ? data.get(k) : null), setItem: (k, v) => data.set(k, String(v)), data };
}

function fakeDocument(nodes, referrer = "") {
  return {
    referrer,
    querySelectorAll() {
      return nodes;
    },
  };
}

function node(tagName, attrs = {}) {
  const map = new Map(Object.entries(attrs));
  return { tagName, getAttribute: (n) => (map.has(n) ? map.get(n) : null), setAttribute: (n, v) => map.set(n, v), attrs: map };
}

test("UTM ve tıklama kimlikleri kısa linke eklenir; linkin kendi parametresi korunur", () => {
  const params = smart.collectSmartParams("https://site.example/indir?utm_source=google&utm_campaign=bahar&gclid=Cj0Kabc&diger=1", "");
  assert.deepEqual(params, { utm_source: "google", utm_campaign: "bahar", gclid: "Cj0Kabc" });
  const url = smart.buildSmartUrl("https://feralin.com/l/abc123?utm_campaign=kendi", params);
  const parsed = new URL(url);
  assert.equal(parsed.searchParams.get("utm_campaign"), "kendi");
  assert.equal(parsed.searchParams.get("utm_source"), "google");
  assert.equal(parsed.searchParams.get("gclid"), "Cj0Kabc");
  assert.equal(parsed.searchParams.has("diger"), false);
});

test("geçersiz değer ve https olmayan link reddedilir", () => {
  assert.deepEqual(smart.collectSmartParams("https://site.example/?utm_source=bo%C5%9Fluk%20var&fbclid=" + "x".repeat(300), ""), {});
  assert.equal(smart.buildSmartUrl("http://feralin.com/l/abc", { utm_source: "a" }), null);
  assert.equal(smart.buildSmartUrl("javascript:alert(1)", {}), null);
  assert.equal(smart.buildSmartUrl("bozuk", {}), null);
});

test("yönlendiren yalnız açıkça istenirse kaynak olur; aynı site yönlendiren sayılmaz", () => {
  assert.deepEqual(smart.collectSmartParams("https://site.example/", "https://www.arama.example/sonuc?q=gizli"), {});
  assert.deepEqual(smart.collectSmartParams("https://site.example/", "https://www.arama.example/sonuc?q=gizli", { referrerAsSource: true }), { utm_source: "www.arama.example", utm_medium: "referral" });
  assert.deepEqual(smart.collectSmartParams("https://site.example/b", "https://site.example/a", { referrerAsSource: true }), {});
});

test("parametreler oturum boyunca korunur; sayfadaki yeni parametre eskisinin yerine geçer", () => {
  const storage = memoryStorage();
  assert.deepEqual(smart.visitParams("https://site.example/?utm_source=meta", "", {}, storage), { utm_source: "meta" });
  assert.deepEqual(smart.visitParams("https://site.example/fiyat", "", {}, storage), { utm_source: "meta" });
  assert.deepEqual(smart.visitParams("https://site.example/?utm_source=tiktok", "", {}, storage), { utm_source: "tiktok" });
  assert.deepEqual(smart.visitParams("https://site.example/", "", {}, null), {});
});

test("öğeler yeniden yazılır ve işaretlenir; bağlantı olmayan öğeye data-href yazılır", () => {
  const a = node("A", { href: "https://apps.apple.com/app/id1" });
  const button = node("BUTTON");
  const doc = fakeDocument([a, button]);
  const count = smart.applySmartScript({ link: "https://feralin.com/l/abc123" }, doc, "https://site.example/?utm_source=google&ttclid=T1", memoryStorage());
  assert.equal(count, 2);
  assert.equal(a.attrs.get("href"), "https://feralin.com/l/abc123?utm_source=google&ttclid=T1");
  assert.equal(button.attrs.get("data-href"), "https://feralin.com/l/abc123?utm_source=google&ttclid=T1");
  assert.equal(a.attrs.get("data-feralin-smart-applied"), "1");
  assert.equal(smart.applySmartScript({ link: "http://feralin.com/l/abc" }, doc, "https://site.example/", memoryStorage()), 0);
});

test("tıklama kimliği listesi link yönlendiricisinin taşıdığı listeyle aynıdır", () => {
  const go = readFileSync(join(root, "../../services/link-router/internal/target/passthrough.go"), "utf8");
  const match = go.match(/var PassClickIDParams = \[\]string\{([^}]*)\}/);
  assert.ok(match, "PassClickIDParams bulunamadı");
  const routerList = [...match[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual([...smart.SMART_CLICK_IDS], routerList);
});
