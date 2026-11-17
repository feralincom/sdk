// Otomatik olay modülü birim testleri (K6): SPA rota değişiminde page_view, dış bağlantı, dosya indirme, 404, site içi arama.
// Her davranış ayrı kapatılabilir, izin geri çekilince modül susar, History API sarmalayıcıları durdurulunca geri konur.
import test from "node:test";
import assert from "node:assert/strict";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
execFileSync(process.execPath, [join(root, "scripts/build.mjs")], { stdio: "pipe" });
const auto = await import(join(root, "dist/feralin-auto.mjs").replace(/\\/g, "/").replace(/^([A-Za-z]):/, "file:///$1:"));

function bag() {
  const map = new Map();
  return {
    addEventListener(type, fn) { map.set(type, [...(map.get(type) ?? []), fn]); },
    removeEventListener(type, fn) { map.set(type, (map.get(type) ?? []).filter((f) => f !== fn)); },
    fire(type, event) { for (const fn of map.get(type) ?? []) fn(event); },
    count(type) { return (map.get(type) ?? []).length; },
  };
}

function world(href = "https://acme.test/") {
  const docBag = bag();
  const winBag = bag();
  const metas = {};
  const loc = new URL(href);
  const win = {
    ...winBag,
    location: loc,
    history: {
      pushState(_s, _t, url) { const u = new URL(url, loc.href); loc.pathname = u.pathname; loc.search = u.search; loc.hash = u.hash; },
      replaceState(_s, _t, url) { const u = new URL(url, loc.href); loc.pathname = u.pathname; loc.search = u.search; loc.hash = u.hash; },
    },
  };
  const doc = {
    ...docBag,
    title: "Ana sayfa",
    querySelector(sel) {
      return sel.includes("feralin:status") && metas.status !== undefined ? { getAttribute: () => metas.status } : null;
    },
  };
  return { doc, win, docBag, winBag, metas, loc };
}

function client(consent = { analytics: true }) {
  const events = [];
  const c = {
    events,
    consent,
    referrers: [],
    track(name, props) { events.push({ name, props }); return { event_name: name }; },
    page() { events.push({ name: "page_view" }); return {}; },
    setReferrer(url) { c.referrers.push(url); },
    getStatus() { return { consent: c.consent }; },
  };
  return c;
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const click = (href) => ({ target: { closest: () => ({ getAttribute: () => href }) } });

test("SPA: rota (yol) değişince page_view ve önceki sayfa yönlendiren olur; yalnız sorgu değişimi sayılmaz", async () => {
  const w = world();
  const c = client();
  const h = auto.startAutoEvents({ client: c, document: w.doc, window: w.win, notFound: false });
  w.win.history.pushState({}, "", "/fiyatlar");
  await wait(80);
  assert.deepEqual(c.events.map((e) => e.name), ["page_view"]);
  assert.deepEqual(c.referrers, ["https://acme.test/"]);
  w.win.history.replaceState({}, "", "/fiyatlar?sirala=ucret");
  await wait(80);
  assert.equal(c.events.length, 1, "aynı yolda sorgu değişimi yeni sayfa değildir");
  w.win.history.pushState({}, "", "/iletisim#form");
  await wait(80);
  assert.equal(c.events.length, 2);
  h.stop();
});

test("SPA kapalıyken rota değişimi olay üretmez; durdurulunca History API geri konur", async () => {
  const w = world();
  const originalPush = w.win.history.pushState;
  const c = client();
  const h = auto.startAutoEvents({ client: c, document: w.doc, window: w.win, spa: false, notFound: false });
  assert.notEqual(w.win.history.pushState, originalPush, "sarmalayıcı takılmalı");
  w.win.history.pushState({}, "", "/a");
  await wait(80);
  assert.equal(c.events.length, 0);
  h.stop();
  assert.equal(w.win.history.pushState, originalPush, "durdurunca özgün işlev dönmeli");
  assert.equal(w.winBag.count("popstate"), 0);
  assert.equal(w.docBag.count("click"), 0);
});

test("dış bağlantı yalnız alan adıyla; iç bağlantı ve mailto sayılmaz", () => {
  const w = world();
  const c = client();
  const h = auto.startAutoEvents({ client: c, document: w.doc, window: w.win, notFound: false });
  w.docBag.fire("click", click("https://partner.example/yol?token=gizli#x"));
  w.docBag.fire("click", click("/fiyatlar"));
  w.docBag.fire("click", click("https://acme.test/blog"));
  w.docBag.fire("click", click("mailto:a@b.test"));
  assert.deepEqual(c.events, [{ name: "fr_outbound_click", props: { link_host: "partner.example" } }]);
  assert.equal(JSON.stringify(c.events).includes("gizli"), false);
  h.stop();
});

test("dosya indirme: izinli uzantı, dosya adı; sorgu dizgisi yok; uzantı listesi özelleştirilebilir", () => {
  const w = world();
  const c = client();
  const h = auto.startAutoEvents({ client: c, document: w.doc, window: w.win, notFound: false });
  w.docBag.fire("click", click("/files/Rapor.PDF?token=gizli"));
  w.docBag.fire("click", click("/files/sayfa.html"));
  assert.deepEqual(c.events, [{ name: "fr_file_download", props: { file_extension: "pdf", file_name: "Rapor.PDF" } }]);
  h.stop();

  const c2 = client();
  const h2 = auto.startAutoEvents({ client: c2, document: w.doc, window: w.win, notFound: false, downloads: ["torrent"] });
  w.docBag.fire("click", click("/a.pdf"));
  w.docBag.fire("click", click("/a.torrent"));
  assert.deepEqual(c2.events.map((e) => e.props.file_extension), ["torrent"]);
  h2.stop();

  const c3 = client();
  const h3 = auto.startAutoEvents({ client: c3, document: w.doc, window: w.win, notFound: false, downloads: false, outbound: false });
  w.docBag.fire("click", click("/a.pdf"));
  w.docBag.fire("click", click("https://partner.example/"));
  assert.equal(c3.events.length, 0);
  h3.stop();
});

test("404: meta işareti, başlık sezgisi ve özel işlev; sayfa başına bir kez", async () => {
  const w = world("https://acme.test/yok");
  w.metas.status = "404";
  const c = client();
  const h = auto.startAutoEvents({ client: c, document: w.doc, window: w.win });
  await wait(80);
  assert.deepEqual(c.events.map((e) => e.name), ["fr_not_found"]);
  h.stop();

  const w2 = world("https://acme.test/x");
  w2.doc.title = "Sayfa bulunamadı - 404";
  const c2 = client();
  const h2 = auto.startAutoEvents({ client: c2, document: w2.doc, window: w2.win });
  await wait(80);
  assert.equal(c2.events.length, 1);
  h2.stop();

  const w3 = world("https://acme.test/x");
  w3.doc.title = "Sipariş 1404 numaralı";
  const c3 = client();
  const h3 = auto.startAutoEvents({ client: c3, document: w3.doc, window: w3.win });
  await wait(80);
  assert.equal(c3.events.length, 0, "404 başka sayının parçasıysa işaretlenmez");
  h3.stop();

  const w4 = world("https://acme.test/x");
  const c4 = client();
  const h4 = auto.startAutoEvents({ client: c4, document: w4.doc, window: w4.win, notFound: () => true });
  await wait(80);
  assert.equal(c4.events.length, 1);
  h4.stop();
});

test("site içi arama varsayılan kapalı; açılınca parametre ve kırpılmış metin gider", async () => {
  const w = world("https://acme.test/ara?q=ayakkabi&utm_source=x");
  const c = client();
  const h = auto.startAutoEvents({ client: c, document: w.doc, window: w.win, notFound: false });
  await wait(80);
  assert.equal(c.events.length, 0, "varsayılan kapalı");
  h.stop();

  const long = "a".repeat(300);
  const w2 = world(`https://acme.test/ara?s=${long}`);
  const c2 = client();
  const h2 = auto.startAutoEvents({ client: c2, document: w2.doc, window: w2.win, notFound: false, siteSearch: true });
  await wait(80);
  assert.equal(c2.events.length, 1);
  assert.equal(c2.events[0].props.search_param, "s");
  assert.equal(c2.events[0].props.search_term.length, 100);
  h2.stop();

  const w3 = world("https://acme.test/ara?kelime=bot&q=gorulmez");
  const c3 = client();
  const h3 = auto.startAutoEvents({ client: c3, document: w3.doc, window: w3.win, notFound: false, siteSearch: ["kelime"] });
  await wait(80);
  assert.deepEqual(c3.events[0].props, { search_term: "bot", search_param: "kelime" });
  h3.stop();
});

test("izin yokken ya da geri çekilince hiçbir olay üretilmez", async () => {
  const w = world();
  const c = client({ analytics: false });
  const h = auto.startAutoEvents({ client: c, document: w.doc, window: w.win, siteSearch: true });
  w.docBag.fire("click", click("https://partner.example/"));
  w.docBag.fire("click", click("/a.pdf"));
  w.win.history.pushState({}, "", "/b");
  await wait(80);
  assert.equal(c.events.length, 0);
  c.consent = { analytics: true };
  w.docBag.fire("click", click("https://partner.example/"));
  assert.equal(c.events.length, 1);
  c.consent = { analytics: false };
  w.docBag.fire("click", click("https://partner.example/"));
  assert.equal(c.events.length, 1, "izin geri çekilince susmalı");
  h.stop();
});

test("pencere ya da belge yoksa (SSR) etkisiz tutamaç döner", () => {
  const h = auto.startAutoEvents({ client: client() });
  assert.doesNotThrow(() => h.stop());
});
