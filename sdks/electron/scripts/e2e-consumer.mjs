// Temiz kurulumdan çalışan tüketici: paketin ana süreç ve preload kodu + gerçek services/collect. Electron kurulu değil:
// IPC ve contextBridge test/fake-electron.mjs ile taklit edilir, gerçek Electron süreci KOŞMAZ.
import assert from "node:assert/strict";
import { appendFileSync } from "node:fs";
import { createRequire } from "node:module";
import { createFeralinMain } from "@feralin/electron/main";
import { exposeFeralin } from "@feralin/electron/preload";
import { fakeElectron } from "./fake-electron.mjs";

const collectUrl = process.env.FERALIN_E2E_COLLECT_URL;
const projectKey = process.env.FERALIN_E2E_PROJECT_KEY;
const out = process.env.FERALIN_E2E_CHECKS;
assert.ok(collectUrl && projectKey && out, "FERALIN_E2E_COLLECT_URL, FERALIN_E2E_PROJECT_KEY, FERALIN_E2E_CHECKS zorunlu");

assert.equal(typeof createRequire(import.meta.url)("@feralin/electron/main").createFeralinMain, "function");
console.log("  OK cjs-esm");

const expect = (line) => appendFileSync(out, line + "\n");
const report = (name, detail) => console.log(`  OK ${name}: ${JSON.stringify(detail)}`);

/** Köprü olay kimliği döndürmez: web görünümüne iç ayrıntı açılmaz. Denetim için ana sürecin isteği dinlenir. */
function boot(extra = {}) {
  const electron = fakeElectron();
  const sent = [];
  const baseFetch = extra.fetch ?? fetch;
  const spy = async (url, init) => {
    const res = await baseFetch(url, init);
    const copy = res.clone();
    sent.push({ events: JSON.parse(init.body).events, ack: await copy.json().catch(() => ({})) });
    return res;
  };
  const main = createFeralinMain({ ipcMain: electron.ipcMain, projectKey, collectUrl, flushIntervalMs: 0, ...extra, fetch: spy });
  exposeFeralin(electron);
  return { bridge: electron.world.feralin, main, sent };
}

// 202 + outbox satırı + fr_click reklam izniyle; izin web görünümünden köprüyle gelir
const { bridge, main, sent } = boot();
{
  await bridge.setConsent({ analytics: true, advertising: true });
  assert.equal(await bridge.track("order_completed", { order_id: "ord_electron_1", fr_click: "clk_electron_1" }), true);
  const r = await bridge.flush();
  assert.deepEqual([r.status, r.accepted, r.rejected], [202, 1, 0]);
  const last = sent.at(-1);
  expect(`frclick ${last.ack.batch_id}`);
  expect(`once ${last.events[0].event_id}`);
  expect(`platform node:${last.events[0].event_id}`);
  report("202-outbox-frclick", { status: r.status, batch_id: last.ack.batch_id });
}

// Reklam izni yok: fr_click çıkarılır
{
  await bridge.setConsent({ analytics: true, advertising: false });
  await bridge.track("order_completed", { order_id: "ord_electron_2", fr_click: "clk_electron_2" });
  const r = await bridge.flush();
  assert.equal(r.status, 202);
  const last = sent.at(-1);
  assert.equal("fr_click" in last.events[0].properties, false);
  expect(`nofrclick ${last.ack.batch_id}`);
  report("frclick-izinsiz-cikarildi", { status: r.status });
}

// İzinsiz: SDK olay üretmez ve istek yapmaz
{
  const before = sent.length;
  await bridge.setConsent({ analytics: false });
  assert.equal(await bridge.track("order_completed"), false);
  await bridge.flush();
  assert.equal(sent.length, before);
  report("izinsiz-sdk-uretmez", { requests: sent.length - before });
}
await main.close();

// İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
{
  const id = `01JCELECTRON${Date.now().toString(36).toUpperCase().padStart(26, "0")}`.slice(0, 26);
  const res = await fetch(`${collectUrl}/v1/batch`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-feralin-project-key": projectKey, "idempotency-key": `denied-${id}` },
    body: JSON.stringify({ events: [{ event_id: id, event_name: "denied_event", occurred_at: new Date().toISOString(), platform: "node", schema_version: 1, consent: { analytics: false } }] }),
  });
  const body = await res.json();
  assert.deepEqual([res.status, body.accepted, body.rejected_reasons.consent_denied], [202, 0, 1]);
  expect(`absent ${id}`);
  report("izinsiz-toplayici-red", body.rejected_reasons);
}

// Yanlış anahtar: 401, olay atılır, uygulama düşmez
{
  const electron = fakeElectron();
  const captured = [];
  const wrong = createFeralinMain({
    ipcMain: electron.ipcMain,
    projectKey: "pk_test_wrong_key_000",
    collectUrl,
    flushIntervalMs: 0,
    consent: { analytics: true },
    fetch: (url, init) => {
      captured.push(JSON.parse(init.body).events[0].event_id);
      return fetch(url, init);
    },
  });
  exposeFeralin(electron);
  await electron.world.feralin.track("order_completed", { order_id: "ord_electron_wrong" });
  const r = await electron.world.feralin.flush();
  assert.deepEqual([r.status, r.rejected, r.retained], [401, 1, 0]);
  expect(`absent ${captured[0]}`);
  report("yanlis-anahtar-401", { status: r.status });
  await wrong.close();
}

// Idempotency: yanıt kayboldu; araya olay girse de aynı anahtarla tek outbox satırı
{
  let first = true;
  const keys = [];
  const lossy = async (url, init) => {
    keys.push(init.headers["idempotency-key"]);
    const res = await fetch(url, init);
    if (first) {
      first = false;
      await res.arrayBuffer();
      throw new Error("yanıt yolda kayboldu");
    }
    return res;
  };
  const c = boot({ fetch: lossy, consent: { analytics: true } });
  await c.bridge.track("order_completed", { order_id: "ord_electron_retry" });
  assert.equal((await c.bridge.flush()).retained, 1);
  await c.bridge.track("order_shipped", { order_id: "ord_electron_retry" });
  const r = await c.bridge.flush();
  assert.equal(r.status, 202);
  assert.equal(keys[0], keys[1]);
  // Kaybolan istek de sunucuya ulaştı; yeniden denenen batch aynı olayı taşır, ikinci olay sonraki batch'tedir.
  const ids = new Set(c.sent.flatMap((entry) => entry.events.map((event) => event.event_id)));
  assert.equal(ids.size, 2);
  for (const id of ids) expect(`once ${id}`);
  report("idempotency-tekrar", { key: keys[0], key_ayni: keys[0] === keys[1], olay: ids.size });
  await c.main.close();
}
console.log("electron tüketici: tüm senaryolar geçti (Electron süreci koşmadı, IPC taklit)");
process.exit(0);
