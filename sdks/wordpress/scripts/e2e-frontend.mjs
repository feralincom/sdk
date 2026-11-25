// Gerçek WordPress sayfası jsdom'da açılır: eklentinin eklediği Web SDK betiği ve başlangıç kodu sitenin kendi HTML'inden yüklenir.
// İzin kararı yokken olay üretilmediği, izinden sonra sayfa görüntülemesinin gerçek toplayıcıya gittiği denetlenir. Gerçek tarayıcı değildir.
//
//   node e2e-frontend.mjs <site_adresi>   (FERALIN_E2E_* ortam değişkenleri run.mjs'ten gelir)
import assert from "node:assert/strict";
import { get } from "node:http";
import { JSDOM, VirtualConsole } from "jsdom";

const site = process.argv[2];
const projectKey = process.env.FERALIN_E2E_PROJECT_KEY;
const collectUrl = process.env.FERALIN_E2E_COLLECT_URL;
assert.ok(site && projectKey && collectUrl, "site adresi ve FERALIN_E2E_* ortamı gerekli");

// PHP yerleşik sunucusu için düz http (Node fetch bağlantı kapanışında takılabiliyor).
const html = await new Promise((resolve, reject) => {
  get(site, (res) => { let body = ""; res.setEncoding("utf8"); res.on("data", (c) => (body += c)); res.on("end", () => resolve(body)); }).on("error", reject);
});
assert.match(html, /wp-content\/plugins\/feralin\/assets\/feralin\.iife\.js/, "eklenti Web SDK betiğini sayfaya eklemedi");
assert.ok(html.includes(JSON.stringify(projectKey)) && html.includes(JSON.stringify(collectUrl)), "başlangıç kodu ayarlardaki anahtar ve adresi taşımıyor");
assert.ok(!html.includes("sk_"), "sayfada gizli anahtar var");
console.log("  OK eklenti betiği ve başlangıç kodu sayfada");

const sent = [];
const virtualConsole = new VirtualConsole();
virtualConsole.on("jsdomError", (error) => console.error("jsdom:", error.message));
const dom = await JSDOM.fromURL(site, {
  runScripts: "dangerously",
  resources: "usable",
  pretendToBeVisual: true,
  virtualConsole,
  beforeParse(window) {
    // jsdom'da fetch yok; gerçek ağ isteği Node fetch ile yapılır ve gönderilen her gövde kaydedilir.
    window.fetch = async (url, init) => {
      if (String(url).startsWith(collectUrl)) sent.push(String(init?.body ?? ""));
      return fetch(url, init);
    };
  },
});
const { window } = dom;
await new Promise((resolve) => (window.document.readyState === "complete" ? resolve() : window.addEventListener("load", resolve)));
for (let i = 0; i < 50 && !window.feralin; i++) await new Promise((r) => setTimeout(r, 100));
assert.ok(window.feralin, "Web SDK yüklenmedi");

// Karar yokken SDK olay üretmez ve göndermez.
window.feralin.track("e2e_before_consent");
await window.feralin.flush?.();
await new Promise((r) => setTimeout(r, 500));
assert.equal(sent.length, 0, "izin kararı yokken toplayıcıya istek gitti");
console.log("  OK izin yokken olay yok");

window.feralin.setConsent({ analytics: true, advertising: false });
window.feralin.page();
window.feralin.track("wp_e2e_frontend", { source: "wordpress-e2e" });
await window.feralin.flush?.();
for (let i = 0; i < 50 && sent.length === 0; i++) await new Promise((r) => setTimeout(r, 100));
assert.ok(sent.length > 0, "izinden sonra toplayıcıya istek gitmedi");
const events = sent.flatMap((body) => JSON.parse(body).events ?? []);
const names = events.map((e) => e.event_name ?? e.name);
assert.ok(names.includes("wp_e2e_frontend"), `özel olay gönderilmedi: ${names.join(", ")}`);
assert.ok(!names.includes("e2e_before_consent"), "izinsiz olay sonradan gönderildi");
for (const event of events) assert.equal(event.platform, "web");
console.log(`  OK izinden sonra ${events.length} olay gönderildi (${names.join(", ")})`);
process.stdout.write(`FRONTEND_EVENTS ${events.map((e) => e.event_id).join(" ")}\n`);
window.close();
process.exit(0);
