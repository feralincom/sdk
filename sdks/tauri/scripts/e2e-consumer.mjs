// Temiz kurulumdan çalışan tüketici: jsdom ve elle konan Tauri işareti üzerinde gerçek services/collect. Gerçek Tauri penceresi değildir.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { createFeralinTauri, isTauri, releaseFeralin } from "@feralin/tauri";
import { env, installDom, runWebScenarios } from "./web-scenarios.mjs";

const cjs = createRequire(import.meta.url)("@feralin/tauri");
assert.equal(typeof cjs.createFeralinTauri, "function");
console.log("  OK cjs-esm");

const { collectUrl, projectKey } = env();
assert.equal(createFeralinTauri({ projectKey, collectUrl, consent: { analytics: true } }).active, false);
console.log("  OK window-yok");

installDom();
window.__TAURI_INTERNALS__ = {};
assert.equal(isTauri(), true);

await runWebScenarios({
  // Senaryo autoTrack'i açıkça belirtir; verilmeyen ilk kurulumda sayfa görüntülemesi bekler.
  mount: async (options) => createFeralinTauri({ autoTrack: true, ...options }),
  release: async (options) => releaseFeralin(options),
  label: "tauri",
});
console.log("tauri tüketici: tüm senaryolar geçti");
process.exit(0);
