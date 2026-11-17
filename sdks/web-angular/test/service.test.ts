// Gerçek @angular/core enjektörü ve jsdom; yalnız ağ enjekte edilir. Bileşen derlemesi kullanılmaz, Angular'ın kısmi derlenmiş paketleri için JIT yüklenir.
import "@angular/compiler";
import { readFileSync } from "node:fs";
import { EnvironmentInjector, Injector, PLATFORM_ID, createEnvironmentInjector } from "@angular/core";
import { createApplication } from "@angular/platform-browser";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FeralinService, provideFeralin, releaseFeralin } from "../src/index";

const projectKey = "pk_test_angular_unit_01";
const collectUrl = "http://collector.test";

function collector() {
  const sent: Array<{ headers: Record<string, string>; events: Array<Record<string, any>> }> = [];
  const fetchImpl = vi.fn(async (_url: string, init: RequestInit) => {
    sent.push({ headers: init.headers as Record<string, string>, events: JSON.parse(String(init.body)).events });
    return new Response(JSON.stringify({ batch_id: "b1" }), { status: 202 });
  });
  return { sent, fetch: fetchImpl as unknown as typeof fetch };
}

function injectorFor(options: Record<string, unknown>, extra: unknown[] = []) {
  const parent = Injector.NULL as unknown as EnvironmentInjector;
  return createEnvironmentInjector([{ provide: PLATFORM_ID, useValue: "browser" }, provideFeralin({ projectKey, collectUrl, flushIntervalMs: 0, ...options } as never), ...(extra as never[])], parent);
}

beforeEach(() => localStorage.clear());
afterEach(() => releaseFeralin({ projectKey, collectUrl }));

describe("provideFeralin", () => {
  it("gerçek createApplication akışında kurulur ve servis enjekte edilebilir", async () => {
    const c = collector();
    const app = await createApplication({ providers: [provideFeralin({ projectKey, collectUrl, flushIntervalMs: 0, fetch: c.fetch, consent: { analytics: true } })] });
    const feralin = app.injector.get(FeralinService);
    expect(feralin.active).toBe(true);
    expect(feralin.getStatus()!.queued).toBe(1);
    app.destroy();
  });

  it("açılışta istemciyi kurar: servis enjekte edilmeden autoTrack çalışır", async () => {
    const c = collector();
    const injector = injectorFor({ fetch: c.fetch, consent: { analytics: true } });
    const feralin = injector.get(FeralinService);
    expect(feralin.active).toBe(true);
    expect(feralin.getStatus()!.queued).toBe(1);
    feralin.track("signup_completed", { plan: "growth" });
    expect((await feralin.flush()).status).toBe(202);
    expect(c.sent[0]!.events.map((e) => e.event_name)).toEqual(["page_view", "signup_completed"]);
    expect(c.sent[0]!.headers["x-feralin-project-key"]).toBe(projectKey);
  });

  it("izin yokken olay üretmez, reklam izni yoksa fr_click çıkarılır", () => {
    const feralin = injectorFor({ fetch: collector().fetch, autoTrack: false, consent: { analytics: false } }).get(FeralinService);
    expect(feralin.track("order_completed")).toBeNull();
    expect(localStorage.getItem("fr_aid")).toBeNull();
    feralin.setConsent({ analytics: true });
    expect(feralin.track("order_completed", { fr_click: "c1", order_id: "o1" })!.properties).toEqual({ order_id: "o1" });
    feralin.setConsent({ analytics: true, advertising: true });
    expect(feralin.track("order_completed", { fr_click: "c2" })!.properties).toEqual({ fr_click: "c2" });
    feralin.identify("user_1");
    expect(feralin.page()!.user_id).toBe("user_1");
    feralin.reset();
    expect(feralin.getStatus()!.user_id).toBeNull();
    feralin.optOut();
    expect(feralin.getStatus()!.consent.analytics).toBe(false);
  });

  it("trackRevenue ve setReferrer servis üzerinden çekirdeğe gider", () => {
    const feralin = injectorFor({ fetch: collector().fetch, autoTrack: false, consent: { analytics: true } }).get(FeralinService);
    const event = feralin.trackRevenue({ transactionId: "tx_1", amountMinor: 1299, currency: "USD", quantity: 2, receipt: { provider: "stripe", token: "pi_123" } });
    expect(event!.event_name).toBe("feralin_purchase");
    expect(event!.properties).toMatchObject({ amount_minor: 1299, quantity: 2, receipt: { provider: "stripe", token: "pi_123" } });
    expect(feralin.trackRevenue({ transactionId: "", amountMinor: 1, currency: "USD" })).toBeNull();
    expect(() => feralin.setReferrer("https://example.com/a")).not.toThrow();
  });

  it("gizli anahtar reddedilir", () => {
    expect(() => injectorFor({ projectKey: "sk_live_gizli_0001" })).toThrow(/gizli anahtar/);
  });

  it("ortak katman web-react ile birebir aynı", () => {
    const here = readFileSync("src/handle.ts", "utf8");
    const origin = readFileSync("../web-react/src/handle.ts", "utf8");
    expect(here).toBe(origin);
  });
});
