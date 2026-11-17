// Gerçek Express ve gerçek HTTP; yalnız toplayıcıya giden fetch enjekte edilir.
import test from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { FeralinClient } from "@feralin/node";
import { feralinMiddleware } from "../dist/esm/index.js";

const KEY = "pk_test_express_unit_01";
const COLLECT = "http://collector.test";

function collector(status = 202) {
  const batches = [];
  const fetchImpl = async (url, init) => {
    batches.push({ url, headers: init.headers, events: JSON.parse(init.body).events });
    return new Response(JSON.stringify({ batch_id: "b1", accepted: 1, rejected: 0 }), { status });
  };
  return { batches, fetch: fetchImpl };
}

async function serve(app, fn) {
  const server = await new Promise((resolve) => {
    const s = app.listen(0, "127.0.0.1", () => resolve(s));
  });
  try {
    return await fn(`http://127.0.0.1:${server.address().port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

function appWith(options, route) {
  const app = express();
  const middleware = feralinMiddleware({ projectKey: KEY, collectUrl: COLLECT, flushIntervalMs: 0, ...options });
  app.use(middleware);
  app.get("/siparis/:id", route);
  return { app, middleware };
}

test("izin yokken olay üretmez, istek de başarılı döner", async () => {
  const c = collector();
  const { app, middleware } = appWith({ fetch: c.fetch }, (req, res) => res.json({ event: req.feralin.track("order_completed") }));
  await serve(app, async (base) => {
    const res = await fetch(`${base}/siparis/1`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { event: null });
  });
  assert.equal((await middleware.client.flush()).sent, 0);
  assert.equal(c.batches.length, 0);
});

test("istek başına izin, kimlik ve temiz bağlam olaya geçer; başlık ve IP sızmaz", async () => {
  const c = collector();
  const { app, middleware } = appWith(
    {
      fetch: c.fetch,
      resolveConsent: (req) => ({ analytics: req.get("x-izin") === "evet", advertising: req.get("x-reklam") === "evet" }),
      resolveUserId: () => "user_42",
    },
    (req, res) => {
      req.feralin.track("order_completed", { order_id: req.params.id, fr_click: "clk_1" });
      res.end();
    },
  );
  await serve(app, async (base) => {
    await fetch(`${base}/siparis/1?token=GIZLI&utm_source=e2e`, { headers: { "x-izin": "evet", "x-reklam": "evet", referer: "https://ref.example.test/a?b=GIZLI", "accept-language": "tr-TR,tr;q=0.9" } });
    await fetch(`${base}/siparis/2`, { headers: { "x-izin": "evet" } });
    await fetch(`${base}/siparis/3`);
  });
  await middleware.client.flush();
  assert.equal(c.batches.length, 1);
  const [first, second] = c.batches[0].events;
  assert.equal(c.batches[0].events.length, 2);
  assert.equal(c.batches[0].url, "http://collector.test/v1/batch");
  assert.equal(c.batches[0].headers["x-feralin-project-key"], KEY);
  assert.match(c.batches[0].headers["idempotency-key"], /^[0-9a-f]{16}-2$/);
  assert.equal(first.user_id, "user_42");
  assert.equal(first.properties.fr_click, "clk_1");
  assert.equal(first.properties.utm_source, "e2e");
  assert.equal(first.context.referrer, "https://ref.example.test");
  assert.equal(first.context.locale, "tr-TR");
  assert.match(first.context.page_url, /\/siparis\/1$/);
  assert.equal("fr_click" in second.properties, false);
  const raw = JSON.stringify(c.batches[0].events);
  assert.equal(raw.includes("GIZLI"), false);
  assert.equal(raw.includes("verified"), false);
});

test("çözümleyici hata atarsa izin yok sayılır, uygulama düşmez", async () => {
  const warnings = [];
  const c = collector();
  const { app } = appWith(
    {
      fetch: c.fetch,
      logger: { warn: (message) => warnings.push(message) },
      resolveConsent: () => {
        throw new Error("CMP yok");
      },
    },
    (req, res) => res.json({ consent: req.feralin.consent, event: req.feralin.track("x") }),
  );
  await serve(app, async (base) => {
    const res = await fetch(`${base}/siparis/1`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { consent: { analytics: false }, event: null });
  });
  assert.equal(warnings.length, 1);
});

test("trackRequests rota kalıbını gönderir, kimlik içeren yolu göndermez", async () => {
  const c = collector();
  const { app, middleware } = appWith({ fetch: c.fetch, trackRequests: true, includeContext: false, resolveConsent: () => ({ analytics: true }) }, (req, res) => res.status(201).end());
  await serve(app, async (base) => {
    await fetch(`${base}/siparis/12345`);
    await fetch(`${base}/yok`);
  });
  await new Promise((resolve) => setTimeout(resolve, 20));
  await middleware.client.flush();
  const events = c.batches[0].events;
  assert.deepEqual(
    events.map((e) => [e.event_name, e.properties.method, e.properties.route, e.properties.status_code]),
    [
      ["http_request", "GET", "/siparis/:id", 201],
      ["http_request", "GET", "unmatched", 404],
    ],
  );
  assert.equal(JSON.stringify(events).includes("12345"), false);
  assert.equal(events[0].context, undefined);
});

test("401 kuyruğu atar, ağ hatası kuyrukta tutar ve aynı anahtarla yeniden dener", async () => {
  const rejected = collector(401);
  const client = new FeralinClient({ projectKey: KEY, collectUrl: COLLECT, flushIntervalMs: 0, fetch: rejected.fetch, consent: { analytics: true } });
  const app = express();
  app.use(feralinMiddleware({ client, resolveConsent: () => ({ analytics: true }) }));
  app.get("/", (req, res) => {
    req.feralin.track("order_completed");
    res.end();
  });
  await serve(app, (base) => fetch(`${base}/`));
  const result = await client.flush();
  assert.deepEqual([result.status, result.rejected, result.retained], [401, 1, 0]);

  const keys = [];
  let fail = true;
  const flaky = async (_url, init) => {
    keys.push(init.headers["idempotency-key"]);
    if (fail) {
      fail = false;
      throw new Error("ağ yok");
    }
    return new Response("{}", { status: 202 });
  };
  const second = feralinMiddleware({ projectKey: KEY, collectUrl: COLLECT, flushIntervalMs: 0, fetch: flaky, resolveConsent: () => ({ analytics: true }) });
  const app2 = express();
  app2.use(second);
  app2.get("/", async (req, res) => {
    req.feralin.track("order_completed");
    res.json(await req.feralin.flush());
  });
  await serve(app2, async (base) => {
    const lost = await (await fetch(`${base}/`)).json();
    assert.deepEqual([lost.status, lost.retained], [0, 1]);
  });
  const retried = await second.close();
  assert.equal(retried.status, 202);
  assert.equal(keys[0], keys[1]);
});

test("iki eşzamanlı istek: izin ve kimlik sızmaz, ret paylaşılan istemciyi durdurmaz", async () => {
  const c = collector();
  let arrived = 0;
  let open;
  const opened = new Promise((resolve) => (open = resolve));
  const { app, middleware } = appWith(
    {
      fetch: c.fetch,
      resolveConsent: (req) => ({ analytics: req.get("x-izin") === "evet" }),
      resolveUserId: (req) => req.get("x-kim"),
    },
    async (req, res) => {
      if (++arrived === 2) open();
      await opened;
      await new Promise((resolve) => setTimeout(resolve, 5));
      res.json({ event: req.feralin.track("order_completed"), consent: req.feralin.consent });
    },
  );
  await serve(app, async (base) => {
    const [ali, ayse] = await Promise.all([
      fetch(`${base}/siparis/1`, { headers: { "x-kim": "ali", "x-izin": "evet" } }).then((res) => res.json()),
      fetch(`${base}/siparis/2`, { headers: { "x-kim": "ayse", "x-izin": "hayir" } }).then((res) => res.json()),
    ]);
    assert.equal(ali.event.user_id, "ali");
    assert.equal(ayse.event, null);
    assert.deepEqual(ayse.consent, { analytics: false });
  });
  const status = middleware.client.getStatus();
  assert.equal(status.optedOut, false);
  assert.equal(status.queued, 1);
  await middleware.close();
  assert.deepEqual(c.batches[0].events.map((event) => event.user_id), ["ali"]);
});

test("gizli anahtar açılışta reddedilir", () => {
  assert.throws(() => feralinMiddleware({ projectKey: "sk_live_gizli_0001", collectUrl: COLLECT }), /gizli anahtar/);
});
