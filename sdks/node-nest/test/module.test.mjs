// Gerçek NestJS uygulaması ve gerçek HTTP; yalnız toplayıcıya giden fetch enjekte edilir. Dekoratörler derleyicisiz, elle uygulanır.
import "reflect-metadata";
import test from "node:test";
import assert from "node:assert/strict";
import { Controller, Get, Injectable, Module, Req } from "@nestjs/common";
import { NestFactory } from "@nestjs/core";
import { CurrentFeralin, FeralinModule, FeralinService } from "../dist/esm/index.js";

const KEY = "pk_test_nest_unit_0001";
const COLLECT = "http://collector.test";

function collector() {
  const batches = [];
  const fetchImpl = async (url, init) => {
    batches.push({ url, headers: init.headers, events: JSON.parse(init.body).events });
    return new Response(JSON.stringify({ batch_id: "b1", accepted: 1, rejected: 0 }), { status: 202 });
  };
  return { batches, fetch: fetchImpl };
}

function apply(decorators, target, key) {
  const descriptor = Object.getOwnPropertyDescriptor(target, key);
  for (const decorator of decorators) decorator(target, key, descriptor);
}

function controllerClass() {
  class Orders {
    create(feralin) {
      return { event: feralin.track("order_completed", { order_id: "o1", fr_click: "clk_1" }) };
    }
    raw(req) {
      return { hasContext: req.feralin !== undefined };
    }
  }
  apply([Get("siparis")], Orders.prototype, "create");
  CurrentFeralin()(Orders.prototype, "create", 0);
  apply([Get("ham")], Orders.prototype, "raw");
  Req()(Orders.prototype, "raw", 0);
  Controller()(Orders);
  return Orders;
}

async function startApp(moduleConfig) {
  const Orders = controllerClass();
  class AppModule {}
  Module({ imports: [moduleConfig], controllers: [Orders] })(AppModule);
  const app = await NestFactory.create(AppModule, { logger: false });
  await app.listen(0, "127.0.0.1");
  return { app, base: await app.getUrl() };
}

test("istek başına izin ve kimlik geçer, reklam izni yoksa fr_click çıkarılır, kapanışta gönderilir", async () => {
  const c = collector();
  const { app, base } = await startApp(
    FeralinModule.forRoot({
      projectKey: KEY,
      collectUrl: COLLECT,
      flushIntervalMs: 0,
      fetch: c.fetch,
      resolveConsent: (req) => ({ analytics: req.headers["x-izin"] === "evet", advertising: req.headers["x-reklam"] === "evet" }),
      resolveUserId: () => "user_42",
    }),
  );
  const none = await (await fetch(`${base}/siparis`)).json();
  assert.equal(none.event, null);
  const full = await (await fetch(`${base}/siparis`, { headers: { "x-izin": "evet", "x-reklam": "evet" } })).json();
  assert.equal(full.event.properties.fr_click, "clk_1");
  assert.equal(full.event.user_id, "user_42");
  const noAds = await (await fetch(`${base}/siparis`, { headers: { "x-izin": "evet" } })).json();
  assert.equal("fr_click" in noAds.event.properties, false);
  assert.deepEqual(await (await fetch(`${base}/ham`)).json(), { hasContext: true });

  assert.equal(app.get(FeralinService).getStatus().queued, 2);
  await app.close();
  assert.equal(c.batches.length, 1);
  assert.equal(c.batches[0].events.length, 2);
  assert.equal(c.batches[0].url, "http://collector.test/v1/batch");
  assert.equal(c.batches[0].headers["x-feralin-project-key"], KEY);
  assert.equal(JSON.stringify(c.batches[0].events).includes("verified"), false);
});

test("çözümleyici hatası izin yok sayılır, uygulama düşmez", async () => {
  const warnings = [];
  const { app, base } = await startApp(
    FeralinModule.forRoot({
      projectKey: KEY,
      collectUrl: COLLECT,
      flushIntervalMs: 0,
      fetch: collector().fetch,
      logger: { warn: (message) => warnings.push(message) },
      resolveConsent: () => {
        throw new Error("CMP yok");
      },
    }),
  );
  const res = await fetch(`${base}/siparis`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { event: null });
  assert.equal(warnings.length, 1);
  await app.close();
});

test("forRootAsync ve başka modülden enjeksiyon çalışır", async () => {
  const c = collector();
  class Worker {
    constructor(feralin) {
      this.feralin = feralin;
    }
  }
  Injectable()(Worker);
  Reflect.defineMetadata("design:paramtypes", [FeralinService], Worker);
  class FeatureModule {}
  Module({ providers: [Worker], exports: [Worker] })(FeatureModule);
  class AppModule {}
  Module({
    imports: [
      FeralinModule.forRootAsync({
        useFactory: async () => ({ projectKey: KEY, collectUrl: COLLECT, flushIntervalMs: 0, fetch: c.fetch }),
      }),
      FeatureModule,
    ],
  })(AppModule);
  const app = await NestFactory.createApplicationContext(AppModule, { logger: false });
  const worker = app.get(Worker);
  assert.equal(worker.feralin.track("job_done"), null);
  const event = worker.feralin.track("job_done", { ok: true }, { consent: { analytics: true } });
  assert.equal(event.event_name, "job_done");
  await app.close();
  assert.equal(c.batches[0].events.length, 1);
});

/** Servisi enjekte eden denetleyici: iki istek de buluşma noktasına gelmeden yanıt dönmez, böylece gerçekten eşzamanlı sürerler. */
function scopedApp(moduleConfig, handler) {
  class Scoped {
    constructor(feralin) {
      this.feralin = feralin;
    }
    run(req) {
      return handler(this.feralin, req);
    }
  }
  Reflect.defineMetadata("design:paramtypes", [FeralinService], Scoped);
  apply([Get("kapsam")], Scoped.prototype, "run");
  Req()(Scoped.prototype, "run", 0);
  Controller()(Scoped);
  class AppModule {}
  Module({ imports: [moduleConfig], controllers: [Scoped] })(AppModule);
  return AppModule;
}

function meetingPoint(parties) {
  let arrived = 0;
  let open;
  const opened = new Promise((resolve) => (open = resolve));
  return async () => {
    if (++arrived === parties) open();
    await opened;
    // Olay döngüsü dönsün: eşzamanlı kod zinciri tesadüfen bitişik kalmasın.
    await new Promise((resolve) => setTimeout(resolve, 5));
  };
}

async function listen(AppModule, t) {
  const app = await NestFactory.create(AppModule, { logger: false });
  // Doğrulama düşse de sunucu açık kalıp test sürecini asmasın.
  t.after(() => app.close().catch(() => {}));
  await app.listen(0, "127.0.0.1");
  return { app, base: await app.getUrl() };
}

test("iki eşzamanlı istek: identify ve setConsent birbirine ve paylaşılan istemciye sızmaz", async (t) => {
  const c = collector();
  const meet = meetingPoint(2);
  const AppModule = scopedApp(
    FeralinModule.forRoot({ projectKey: KEY, collectUrl: COLLECT, flushIntervalMs: 0, fetch: c.fetch, resolveConsent: () => ({ analytics: true }) }),
    async (feralin, req) => {
      const who = req.headers["x-kim"];
      feralin.identify(who);
      feralin.setConsent({ analytics: req.headers["x-izin"] === "evet" });
      await meet();
      return { event: feralin.track("order_completed"), surface: req.feralin.track("order_shipped"), consent: req.feralin.consent };
    },
  );
  const { app, base } = await listen(AppModule, t);
  const service = app.get(FeralinService);
  const [ali, ayse] = await Promise.all([
    fetch(`${base}/kapsam`, { headers: { "x-kim": "ali", "x-izin": "evet" } }).then((res) => res.json()),
    fetch(`${base}/kapsam`, { headers: { "x-kim": "ayse", "x-izin": "hayir" } }).then((res) => res.json()),
  ]);
  assert.equal(ali.event.user_id, "ali", "ayse'nin kimliği ali'nin olayına sızmamalı");
  assert.equal(ali.surface.user_id, "ali", "req.feralin ve servis aynı istek kapsamını paylaşır");
  assert.deepEqual(ali.consent, { analytics: true });
  assert.equal(ayse.event, null, "ali'nin izni ayse'ye sızmamalı");
  assert.equal(ayse.surface, null);
  assert.deepEqual(ayse.consent, { analytics: false });

  // Paylaşılan istemci hiç değişmedi: ret herkesi durdurmaz, kuyruk silinmez.
  const status = service.getStatus();
  assert.equal(status.optedOut, false);
  assert.deepEqual(status.consent, { analytics: false });
  assert.equal(status.queued, 2);
  await app.close();
  assert.deepEqual(c.batches[0].events.map((event) => event.user_id), ["ali", "ali"]);
});

test("istek içi açık ret olay bazlı izinle aşılmaz; kimlik sonraki isteğe taşınmaz; geçersiz kimlik yok sayılır", async (t) => {
  const c = collector();
  const AppModule = scopedApp(
    FeralinModule.forRoot({ projectKey: KEY, collectUrl: COLLECT, flushIntervalMs: 0, fetch: c.fetch, resolveConsent: () => ({ analytics: true }) }),
    (feralin, req) => {
      if (req.headers["x-kim"]) feralin.identify(req.headers["x-kim"]);
      const before = feralin.track("before_change");
      feralin.identify("x".repeat(129));
      const invalid = feralin.track("invalid_id");
      feralin.identify(undefined);
      const cleared = feralin.track("cleared_id");
      feralin.setConsent({ analytics: false });
      return { before, invalid, cleared, overridden: feralin.track("after_change", undefined, { consent: { analytics: true } }) };
    },
  );
  const { app, base } = await listen(AppModule, t);
  const first = await (await fetch(`${base}/kapsam`, { headers: { "x-kim": "ali" } })).json();
  assert.equal(first.before.user_id, "ali");
  assert.equal(first.invalid.user_id, "ali", "geçersiz kimlik öncekini silmez, olayı düşürmez");
  assert.equal(first.cleared.user_id, undefined);
  assert.equal(first.overridden, null);
  const second = await (await fetch(`${base}/kapsam`)).json();
  assert.equal(second.before.user_id, undefined, "kimlik sonraki isteğe taşınmamalı");
  await app.close();
});

test("istek dışında identify ve setConsent açık hata verir; RPC ve iş kuyruğu izni ve kimliği olay başına verir", async () => {
  const c = collector();
  const app = await NestFactory.createApplicationContext(FeralinModule.forRoot({ projectKey: KEY, collectUrl: COLLECT, flushIntervalMs: 0, fetch: c.fetch }), { logger: false });
  const service = app.get(FeralinService);
  assert.throws(() => service.identify("ali"), /istek/);
  assert.throws(() => service.setConsent({ analytics: true }), /istek/);
  assert.equal(service.getStatus().optedOut, false);
  assert.equal(service.track("job_done"), null);
  const event = service.track("job_done", { ok: true }, { consent: { analytics: true }, userId: "ali", sessionId: "rpc_1" });
  assert.equal(event.user_id, "ali");
  assert.equal(event.session_id, "rpc_1");
  assert.equal(service.track("job_done", undefined, { consent: { analytics: true } }).user_id, undefined, "kimlik sonraki olaya taşınmamalı");
  await app.close();
});

test("gizli anahtar açılışta reddedilir", async () => {
  await assert.rejects(async () => {
    class AppModule {}
    Module({ imports: [FeralinModule.forRoot({ projectKey: "sk_live_gizli_0001", collectUrl: COLLECT })] })(AppModule);
    await NestFactory.createApplicationContext(AppModule, { logger: false, abortOnError: false });
  }, /gizli anahtar/);
});
