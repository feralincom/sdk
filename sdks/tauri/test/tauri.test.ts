// jsdom ve gerçek Web çekirdeği; Tauri çalışma zamanı işareti elle konur. Gerçek Tauri penceresinde koşmaz.
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { captureErrors } from "@feralin/web/errors";
import { createFeralinTauri, isTauri, parseAttributionQuery, parseDeepLink, releaseFeralin } from "../src/index";

const projectKey = "pk_test_tauri_unit_0001";
const collectUrl = "http://collector.test";
const host = window as unknown as Record<string, unknown>;

function collector() {
  const sent: Array<Array<Record<string, any>>> = [];
  const fetchImpl = vi.fn(async (_url: string, init: RequestInit) => {
    sent.push(JSON.parse(String(init.body)).events);
    return new Response("{}", { status: 202 });
  });
  return { sent, fetch: fetchImpl as unknown as typeof fetch };
}

beforeEach(() => {
  localStorage.clear();
  host.__TAURI_INTERNALS__ = {};
});
afterEach(() => {
  delete host.__TAURI_INTERNALS__;
  delete host.__TAURI__;
  releaseFeralin({ projectKey, collectUrl });
});

describe("createFeralinTauri", () => {
  it("Tauri 1 ve 2 işaretini tanır", () => {
    expect(isTauri()).toBe(true);
    delete host.__TAURI_INTERNALS__;
    expect(isTauri()).toBe(false);
    host.__TAURI__ = {};
    expect(isTauri()).toBe(true);
  });

  it("autoTrack varsayılanı kapalı; izinle olay gönderir", async () => {
    const c = collector();
    const feralin = createFeralinTauri({ projectKey, collectUrl, flushIntervalMs: 0, fetch: c.fetch, consent: { analytics: true } });
    expect(feralin.active).toBe(true);
    expect(feralin.getStatus()!.queued).toBe(0);
    feralin.page();
    expect((await feralin.flush()).status).toBe(202);
    expect(c.sent[0]!.map((e) => e.event_name)).toEqual(["page_view"]);
  });

  it("izin yokken olay üretmez, reklam izni yoksa fr_click çıkarılır", () => {
    const feralin = createFeralinTauri({ projectKey, collectUrl, flushIntervalMs: 0, fetch: collector().fetch });
    expect(feralin.track("order_completed")).toBeNull();
    feralin.setConsent({ analytics: true });
    expect(feralin.track("order_completed", { fr_click: "c1", a: 1 })!.properties).toEqual({ a: 1 });
  });

  it("Tauri dışında varsayılan boş yüzey, izin verilirse istemci", () => {
    delete host.__TAURI_INTERNALS__;
    expect(createFeralinTauri({ projectKey, collectUrl }).active).toBe(false);
    expect(createFeralinTauri({ projectKey, collectUrl, flushIntervalMs: 0, allowOutsideTauri: true }).active).toBe(true);
  });

  it("gizli anahtar reddedilir", () => {
    expect(() => createFeralinTauri({ projectKey: "sk_live_gizli_0001", collectUrl })).toThrow(/gizli anahtar/);
  });

  it("yalnız pk_ kabul edilir; Tauri dışındaki boş yüzey de denetlenir, boşluk kırpılır", () => {
    for (const outside of [false, true]) {
      if (outside) delete host.__TAURI_INTERNALS__;
      for (const bad of [" sk_live_gizli_0001", "SK_LIVE_GIZLI_0001"]) expect(() => createFeralinTauri({ projectKey: bad, collectUrl })).toThrow(/gizli anahtar/);
      expect(() => createFeralinTauri({ projectKey: "rk_live_gizli_0001", collectUrl })).toThrow(/pk_/);
    }
    const padded = ` ${projectKey} `;
    const feralin = createFeralinTauri({ projectKey: padded, collectUrl, flushIntervalMs: 0, allowOutsideTauri: true, fetch: collector().fetch });
    expect(feralin.active).toBe(true);
    // Kırpılmış ve boşluklu değer aynı istemcidir; serbest bırakma ikisiyle de bulur.
    releaseFeralin({ projectKey, collectUrl });
    expect(createFeralinTauri({ projectKey: padded, collectUrl, flushIntervalMs: 0, allowOutsideTauri: true })).not.toBe(feralin);
  });

  it("serbest bırakılan tutamak göndermez, depoya yazmaz; kuyruk yeni istemciye geçer", async () => {
    const c = collector();
    const old = createFeralinTauri({ projectKey, collectUrl, flushIntervalMs: 0, fetch: c.fetch, consent: { analytics: true } });
    const event = old.track("order_shipped")!;
    releaseFeralin({ projectKey, collectUrl });
    expect(old.track("order_refunded")).toBeNull();
    window.dispatchEvent(new Event("pagehide"));
    expect((await old.flush()).status).toBe(0);
    expect(c.sent.length).toBe(0);

    const next = createFeralinTauri({ projectKey, collectUrl, flushIntervalMs: 0, fetch: c.fetch, consent: { analytics: true } });
    expect((await next.flush()).status).toBe(202);
    expect(c.sent[0]!.map((e) => e.event_id)).toEqual([event.event_id]);
  });

  it("trackRevenue feralin_purchase üretir, verified gitmez", () => {
    const feralin = createFeralinTauri({ projectKey, collectUrl, flushIntervalMs: 0, fetch: collector().fetch, consent: { analytics: true } });
    const event = feralin.trackRevenue({ transactionId: "tx_1", amountMinor: 999, currency: "USD", properties: { verified: true } });
    expect(event!.event_name).toBe("feralin_purchase");
    expect(event!.properties).not.toHaveProperty("verified");
    expect(feralin.trackRevenue({ transactionId: "tx_1", amountMinor: -1, currency: "USD" })).toBeNull();
  });

  it("errors: pencere hatası ve elle bildirim fr_error olur; yığın izi ve yol gitmez", async () => {
    const c = collector();
    const feralin = createFeralinTauri({ projectKey, collectUrl, flushIntervalMs: 0, fetch: c.fetch, consent: { analytics: true }, errors: { captureErrors, appVersion: "1.2.3" } });
    const error = new TypeError("boom for ali@example.com");
    error.stack = ["TypeError: boom", "    at save (tauri://localhost/assets/app.3f9a1b2c.js:10:5)"].join("\n");
    expect(feralin.captureError(error)).toBe(true);
    window.dispatchEvent(new ErrorEvent("error", { error: new RangeError("x"), message: "x" }));
    await feralin.flush();
    const events = c.sent[0]!;
    expect(events.map((e) => e.event_name)).toEqual(["fr_error", "fr_error"]);
    expect(events[0]!.properties).toMatchObject({ error_type: "TypeError", message: "boom for [email]", handled: true, origin: "handled", app_version: "1.2.3", top_frame: "save@app.js" });
    expect(JSON.stringify(events[0])).not.toContain("tauri://localhost/assets");
    expect(events[1]!.properties).toMatchObject({ error_type: "RangeError", origin: "window_onerror", handled: false });
    feralin.stop();
    expect(feralin.captureError(new Error("y"))).toBe(false);
  });

  it("errors verilmezse captureError false; captureErrors işlev değilse kurulum hatası", () => {
    const feralin = createFeralinTauri({ projectKey, collectUrl, flushIntervalMs: 0, fetch: collector().fetch, consent: { analytics: true } });
    expect(feralin.captureError(new Error("x"))).toBe(false);
    expect(() => createFeralinTauri({ projectKey, collectUrl, errors: {} as never })).toThrow(/captureErrors/);
  });

  it("deep link ayrıştırma: yalnız izinli şema, fr_click ve utm_*; ham sorgu saklanmaz", () => {
    const schemes = new Set(["myapp"]);
    expect(parseDeepLink("https://x.example.com/a?fr_click=c1", schemes)).toBeNull();
    expect(parseDeepLink("bozuk", schemes)).toBeNull();
    const link = parseDeepLink("myapp://open/product/42?fr_click=clk_1&utm_source=mail&email=ali%40example.com#x", schemes)!;
    expect(link.cleanUrl).toBe("myapp://open/product/42");
    expect(link.params).toEqual({ frClick: "clk_1", utm: { utm_source: "mail" } });
    expect(parseAttributionQuery("fr_click=bad%20value&fr_click=ok_2&utm_medium=" + "a".repeat(300)).frClick).toBe("ok_2");
    expect(parseAttributionQuery("utm_medium=" + "a".repeat(300)).utm.utm_medium).toHaveLength(256);
    expect(parseAttributionQuery("fr_click%3Dc9%26utm_source%3Dx")).toEqual({ frClick: "c9", utm: { utm_source: "x" } });
    expect(parseAttributionQuery("fr_click=%E0%A4%A")).toEqual({ utm: {} });
  });

  it("deepLinks: getCurrent ve onOpenUrl URL'leri deep_link_opened olur; kanıt yalnız reklam izniyle", async () => {
    const c = collector();
    let push!: (urls: string[]) => void;
    const off = vi.fn();
    const feralin = createFeralinTauri({
      projectKey,
      collectUrl,
      flushIntervalMs: 0,
      fetch: c.fetch,
      consent: { analytics: true },
      deepLinks: {
        schemes: ["myapp"],
        onOpenUrl: async (handler) => {
          push = handler;
          return off;
        },
        getCurrent: async () => ["myapp://start?fr_click=clk_0"],
      },
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    push(["myapp://open?fr_click=clk_1&utm_source=mail", "https://evil.example.com/?fr_click=x"]);
    feralin.setConsent({ analytics: true, advertising: true });
    push(["myapp://open?fr_click=clk_2&utm_source=mail"]);
    expect(feralin.handleDeepLink("other://x")).toBeNull();
    await feralin.flush();
    const events = c.sent[0]!;
    expect(events.map((e) => e.event_name)).toEqual(["deep_link_opened", "deep_link_opened", "deep_link_opened"]);
    expect(events[0]!.properties).toEqual({ attribution_source: "none" });
    expect(events[1]!.properties).toEqual({ attribution_source: "none" });
    expect(events[2]!.properties).toEqual({ attribution_source: "app_link", fr_click: "clk_2", utm_source: "mail" });
    feralin.stop();
    expect(off).toHaveBeenCalledTimes(1);
    expect(feralin.handleDeepLink("myapp://open")).toBeNull();
  });

  it("deepLinks: izin yokken olay yok; geçersiz şema kurulumda reddedilir", () => {
    expect(() => createFeralinTauri({ projectKey, collectUrl, deepLinks: { schemes: ["my app://"], onOpenUrl: () => () => {} } })).toThrow(/şema/);
    const feralin = createFeralinTauri({ projectKey, collectUrl, flushIntervalMs: 0, fetch: collector().fetch, deepLinks: { schemes: ["myapp"], onOpenUrl: () => () => {} } });
    expect(feralin.handleDeepLink("myapp://open?fr_click=c")).toBeNull();
  });

  it("ortak katman web-react ile birebir aynı", () => {
    const here = readFileSync("src/handle.ts", "utf8");
    const origin = readFileSync("../web-react/src/handle.ts", "utf8");
    expect(here).toBe(origin);
  });
});
