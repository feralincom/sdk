// provideFeralinErrorHandler: gerçek @angular/core enjektörü ve createApplication, jsdom, çekirdek @feralin/web; yalnız ağ enjekte edilir.
import "@angular/compiler";
import { readFileSync } from "node:fs";
import { Component, EnvironmentInjector, ErrorHandler, Injector, PLATFORM_ID, createEnvironmentInjector } from "@angular/core";
import { bootstrapApplication } from "@angular/platform-browser";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FeralinErrorHandler, FeralinService, provideFeralin, provideFeralinErrorHandler, releaseFeralin } from "../src/index";

const projectKey = "pk_test_angular_errors1";
const collectUrl = "http://collector.test";

function collector() {
  const events: Array<Record<string, any>> = [];
  const fetchImpl = vi.fn(async (_url: string, init: RequestInit) => {
    events.push(...JSON.parse(String(init.body)).events);
    return new Response(JSON.stringify({ batch_id: "b1" }), { status: 202 });
  });
  return { events, fetch: fetchImpl as unknown as typeof fetch };
}

function injectorFor(fetchImpl: typeof fetch, consent = { analytics: true }, handler: Parameters<typeof provideFeralinErrorHandler>[0] = {}) {
  return createEnvironmentInjector(
    [
      { provide: PLATFORM_ID, useValue: "browser" },
      provideFeralin({ projectKey, collectUrl, flushIntervalMs: 0, autoTrack: false, fetch: fetchImpl, consent }),
      provideFeralinErrorHandler(handler),
    ],
    Injector.NULL as unknown as EnvironmentInjector,
  );
}

async function settle(feralin: FeralinService, queued: number) {
  await vi.waitFor(() => expect(feralin.getStatus()?.queued).toBe(queued));
}

beforeEach(() => localStorage.clear());
afterEach(() => {
  releaseFeralin({ projectKey, collectUrl });
  vi.restoreAllMocks();
});

describe("provideFeralinErrorHandler", () => {
  it("ErrorHandler yerine geçer, fr_error gönderir ve delegate'i çağırır", async () => {
    const c = collector();
    const delegate = { handleError: vi.fn() };
    const injector = injectorFor(c.fetch, { analytics: true }, { delegate });
    const handler = injector.get(ErrorHandler);
    expect(handler).toBeInstanceOf(FeralinErrorHandler);
    const error = new RangeError("sipariş 5551234567 bulunamadı");
    handler.handleError(error);
    expect(delegate.handleError).toHaveBeenCalledWith(error);
    const feralin = injector.get(FeralinService);
    await settle(feralin, 1);
    await feralin.flush();
    expect(c.events[0]!.event_name).toBe("fr_error");
    expect(c.events[0]!.properties).toMatchObject({ error_type: "RangeError", origin: "uncaught_exception", handled: false, fatal: false, message: "sipariş [num] bulunamadı" });
  });

  it("delegate yoksa Angular varsayılanı gibi console.error yazar; izin yokken olay üretmez", async () => {
    const logged = vi.spyOn(console, "error").mockImplementation(() => {});
    const injector = injectorFor(collector().fetch, { analytics: false });
    injector.get(ErrorHandler).handleError(new Error("izinsiz"));
    expect(logged).toHaveBeenCalledWith("ERROR", expect.any(Error));
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(injector.get(FeralinService).getStatus()?.queued).toBe(0);
  });

  it("sınır seçeneği Web SDK'ya iletilir", async () => {
    const injector = injectorFor(collector().fetch, { analytics: true }, { maxEvents: 1, delegate: { handleError() {} } });
    const handler = injector.get(ErrorHandler);
    handler.handleError(new Error("bir"));
    handler.handleError(new Error("iki"));
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(injector.get(FeralinService).getStatus()?.queued).toBe(1);
  });

  it("gerçek uygulamada bileşen kurucusu hatası ErrorHandler'a ulaşır", async () => {
    const c = collector();
    const delegate = { handleError: vi.fn() };
    class Root {
      constructor() {
        throw new TypeError("kök bileşen hatası");
      }
    }
    Component({ selector: "app-root", template: "<p>x</p>", standalone: true })(Root);
    document.body.innerHTML = "<app-root></app-root>";
    await bootstrapApplication(Root, {
      providers: [provideFeralin({ projectKey, collectUrl, flushIntervalMs: 0, autoTrack: false, fetch: c.fetch, consent: { analytics: true } }), provideFeralinErrorHandler({ delegate })],
    }).catch(() => undefined);
    expect(delegate.handleError).toHaveBeenCalled();
  });

  it("provideFeralin olmadan da kurulur: yalnız işleyici çağrılır", () => {
    const delegate = { handleError: vi.fn() };
    const injector = createEnvironmentInjector([provideFeralinErrorHandler({ delegate })], Injector.NULL as unknown as EnvironmentInjector);
    injector.get(ErrorHandler).handleError(new Error("bağımsız"));
    expect(delegate.handleError).toHaveBeenCalledOnce();
  });

  it("ortak hata katmanı web-react ile birebir aynı", () => {
    expect(readFileSync("src/errors.ts", "utf8")).toBe(readFileSync("../web-react/src/errors.ts", "utf8"));
  });
});
