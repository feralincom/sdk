// Gerçek Vue, vue-router ve jsdom; yalnız ağ enjekte edilir.
import { readFileSync } from "node:fs";
import { createApp, defineComponent, h, nextTick } from "vue";
import { createMemoryHistory, createRouter } from "vue-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FeralinPlugin, releaseFeralin, useFeralin } from "../src/index";
import type { FeralinHandle } from "../src/index";

const projectKey = "pk_test_vue_unit_0001";
const collectUrl = "http://collector.test";

function collector() {
  const sent: Array<{ headers: Record<string, string>; events: Array<Record<string, any>> }> = [];
  const fetchImpl = vi.fn(async (_url: string, init: RequestInit) => {
    sent.push({ headers: init.headers as Record<string, string>, events: JSON.parse(String(init.body)).events });
    return new Response(JSON.stringify({ batch_id: "b1" }), { status: 202 });
  });
  return { sent, fetch: fetchImpl as unknown as typeof fetch };
}

function mountWith(options: Record<string, unknown>) {
  let feralin!: FeralinHandle;
  const app = createApp(
    defineComponent({
      setup() {
        feralin = useFeralin();
        return () => h("div");
      },
    }),
  );
  app.use(FeralinPlugin, { projectKey, collectUrl, flushIntervalMs: 0, ...options } as never);
  app.mount(document.createElement("div"));
  return { app, feralin };
}

beforeEach(() => localStorage.clear());
afterEach(() => releaseFeralin({ projectKey, collectUrl }));

describe("FeralinPlugin", () => {
  it("izinle page_view ve olay üretir, gerçek istek atar", async () => {
    const c = collector();
    const { feralin, app } = mountWith({ fetch: c.fetch, consent: { analytics: true } });
    expect(feralin.active).toBe(true);
    expect(app.config.globalProperties.$feralin).toBe(feralin);
    feralin.track("signup_completed", { plan: "growth" });
    expect((await feralin.flush()).status).toBe(202);
    expect(c.sent[0]!.events.map((e) => e.event_name)).toEqual(["page_view", "signup_completed"]);
    expect(c.sent[0]!.headers["x-feralin-project-key"]).toBe(projectKey);
    expect(c.sent[0]!.headers["idempotency-key"]).toMatch(/^[0-9a-f]{16}-2$/);
  });

  it("izin yokken olay üretmez, reklam izni yoksa fr_click çıkarılır", async () => {
    const c = collector();
    const { feralin } = mountWith({ fetch: c.fetch, autoTrack: false, consent: { analytics: false } });
    expect(feralin.track("order_completed")).toBeNull();
    expect(localStorage.getItem("fr_aid")).toBeNull();
    feralin.setConsent({ analytics: true });
    expect(feralin.track("order_completed", { fr_click: "c1", order_id: "o1" })!.properties).toEqual({ order_id: "o1" });
    feralin.setConsent({ analytics: true, advertising: true });
    expect(feralin.track("order_completed", { fr_click: "c2" })!.properties).toEqual({ fr_click: "c2" });
  });

  it("trackRevenue feralin_purchase üretir, verified düşer, geçersiz girdi null", () => {
    const { feralin } = mountWith({ fetch: collector().fetch, autoTrack: false, consent: { analytics: true } });
    const event = feralin.trackRevenue({ transactionId: "tx_1", amountMinor: 0, currency: "EUR", purchaseType: "subscription_cancel", properties: { verified: true } });
    expect(event!.event_name).toBe("feralin_purchase");
    expect(event!.properties).toEqual({ transaction_id: "tx_1", amount_minor: 0, currency: "EUR", quantity: 1, purchase_type: "subscription_cancel" });
    expect(feralin.trackRevenue({ transactionId: "tx_2", amountMinor: 100, currency: "eur" })).toBeNull();
  });

  it("aynı anahtarla ikinci kurulum ikinci istemci ve page_view üretmez", async () => {
    const c = collector();
    const first = mountWith({ fetch: c.fetch, consent: { analytics: true } });
    const second = mountWith({ fetch: c.fetch, consent: { analytics: true } });
    expect(second.feralin).toBe(first.feralin);
    expect(first.feralin.getStatus()!.queued).toBe(1);
  });

  it("bağlam dışında useFeralin uyarı vermez ve ilk istemciye gider", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const c = collector();
    const { feralin } = mountWith({ fetch: c.fetch, autoTrack: false, consent: { analytics: true } });
    useFeralin().track("store_event");
    expect(feralin.getStatus()!.queued).toBe(1);
    expect(warn).not.toHaveBeenCalled();
    warn.mockRestore();
  });

  it("vue-router: ilk gezinme atlanır, yol değişimi page_view üretir, sorgu değişimi üretmez", async () => {
    const c = collector();
    const empty = defineComponent({ render: () => h("div") });
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: "/", component: empty },
        { path: "/fiyat", component: empty },
      ],
    });
    const { feralin, app } = mountWith({ fetch: c.fetch, consent: { analytics: true }, router });
    app.use(router);
    await router.push("/");
    await nextTick();
    expect(feralin.getStatus()!.queued).toBe(1);
    await router.push("/fiyat");
    expect(feralin.getStatus()!.queued).toBe(2);
    await router.push("/fiyat?a=1");
    expect(feralin.getStatus()!.queued).toBe(2);
  });

  it("autoTrack kapalıysa ilk gezinme de router üzerinden gönderilir", async () => {
    const c = collector();
    const empty = defineComponent({ render: () => h("div") });
    const router = createRouter({ history: createMemoryHistory(), routes: [{ path: "/", component: empty }] });
    const { feralin, app } = mountWith({ fetch: c.fetch, autoTrack: false, consent: { analytics: true }, router });
    app.use(router);
    await router.push("/");
    expect(feralin.getStatus()!.queued).toBe(1);
  });

  it("ortak katman web-react ile birebir aynı", () => {
    const here = readFileSync("src/handle.ts", "utf8");
    const origin = readFileSync("../web-react/src/handle.ts", "utf8");
    expect(here).toBe(origin);
  });
});
