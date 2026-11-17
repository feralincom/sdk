// Temiz kurulumdan çalışan @feralin/web tüketicisi: npm pack çıktısı boş dizine kurulur, paket adıyla içe aktarılır (ESM ve
// CommonJS, alt yollar, IIFE dosyası), jsdom penceresinde gerçek services/collect'e olay gönderilir. Gerçek tarayıcı değildir;
// gerçek tarayıcı akışı Playwright ve canlı duman testindedir.
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { env, installDom, runWebScenarios } from "./web-scenarios.mjs";

const require = createRequire(import.meta.url);

// CommonJS girişi ve paket haritası: kurulu paket kaynak ağaca değil node_modules altına çözülmeli.
const cjs = require("@feralin/web");
assert.equal(typeof cjs.initialize, "function");
const entry = require.resolve("@feralin/web");
assert.ok(/node_modules[\\/]@feralin[\\/]web[\\/]dist[\\/]/.test(entry), `paket node_modules altından çözülmeli: ${entry}`);
// package.json paket haritasında dışa açık değildir; kurulu kopyanın dosyası doğrudan okunur.
const manifest = JSON.parse(readFileSync(new URL("./node_modules/@feralin/web/package.json", import.meta.url), "utf8"));
assert.ok(existsSync(require.resolve("@feralin/web/snippet")), "IIFE dosyası pakette olmalı");
console.log(`  OK cjs-esm-paket: ${manifest.name}@${manifest.version}`);

// Window yokken (SSR, Node) kurulum olay üretmez ve atmaz.
const { collectUrl, projectKey } = env();
const web = await import("@feralin/web");
assert.equal(web.version, manifest.version);
const headless = web.initialize({ projectKey, collectUrl, consent: { analytics: true }, flushIntervalMs: 0 });
assert.equal(headless.getStatus().queued, 0);
headless.destroy();
console.log("  OK window-yok-sayfa-goruntulemesi-yok");

// Alt modüller ayrı giriş noktalarıdır; pakette gerçekten bulunmalı.
for (const sub of ["auto", "errors", "vitals", "flags", "replay"]) {
  const mod = await import(`@feralin/web/${sub}`);
  assert.ok(Object.keys(mod).length > 0, `@feralin/web/${sub} boş`);
}
console.log("  OK alt-moduller: auto errors vitals flags replay");

installDom();

// Çekirdek tekil örnek kullanır: yeniden initialize öncekini yok eder. `active` bağdaştırıcılardaki tutamağın karşılığıdır.
let current;
async function mount(options) {
  const client = web.initialize(options);
  current = client;
  Object.defineProperty(client, "active", { get: () => current === client });
  return client;
}
async function release() {
  current?.destroy();
  current = undefined;
}

await runWebScenarios({ mount, release, label: "web" });
console.log("web tüketici: tüm senaryolar geçti");
process.exit(0);
