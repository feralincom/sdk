// @vitest-environment node
// window olmadan gerçek Angular enjektörü. PLATFORM_ID "server" iken tarayıcı benzeri ortam olsa bile istemci kurulmaz.
import "@angular/compiler";
import { Component, EnvironmentInjector, Injector, PLATFORM_ID, createEnvironmentInjector, inject } from "@angular/core";
import { bootstrapApplication } from "@angular/platform-browser";
import { provideServerRendering, renderApplication } from "@angular/platform-server";
import { afterEach, describe, expect, it, vi } from "vitest";
import { FeralinService, provideFeralin } from "../src/index";

const options = { projectKey: "pk_test_angular_ssr_001", collectUrl: "http://collector.test", consent: { analytics: true } };

function serverInjector(extra: Record<string, unknown> = {}, platform: string = "server") {
  return createEnvironmentInjector(
    [{ provide: PLATFORM_ID, useValue: platform }, provideFeralin({ ...options, ...extra } as never)],
    Injector.NULL as unknown as EnvironmentInjector,
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("SSR", () => {
  it("ortamda window yok", () => {
    expect(typeof window).toBe("undefined");
    expect(typeof document).toBe("undefined");
  });

  it("gerçek renderApplication: uygulama sunucuda render edilir, servis boş yüzeydir", async () => {
    const interval = vi.spyOn(globalThis, "setInterval");
    const seen: boolean[] = [];
    class Root {
      constructor() {
        seen.push(inject(FeralinService).active);
      }
    }
    Component({ selector: "app-root", template: "<p>ssr</p>", standalone: true })(Root);
    const html = await renderApplication(
      (context) => bootstrapApplication(Root, { providers: [provideServerRendering(), provideFeralin(options)] }, context),
      { document: "<!doctype html><html><head></head><body><app-root></app-root></body></html>", url: "/" },
    );
    expect(html).toContain("<p>ssr</p>");
    expect(seen).toEqual([false]);
    expect(interval).not.toHaveBeenCalled();
  });

  it("sunucu platformunda patlamaz; istemci, zamanlayıcı, ağ yok", async () => {
    const interval = vi.spyOn(globalThis, "setInterval");
    const network = vi.fn();
    const feralin = serverInjector({ fetch: network }).get(FeralinService);
    expect(feralin.active).toBe(false);
    expect(feralin.track("server_side")).toBeNull();
    expect(await feralin.flush()).toEqual({ sent: 0, status: 0 });
    expect(feralin.getStatus()).toBeNull();
    expect(interval).not.toHaveBeenCalled();
    expect(network).not.toHaveBeenCalled();
  });

  it("sunucu ortamında sahte window olsa da PLATFORM_ID kararı geçerlidir", () => {
    vi.stubGlobal("window", {});
    vi.stubGlobal("document", {});
    expect(serverInjector().get(FeralinService).active).toBe(false);
  });

  it("tarayıcı platformu bildirilse de window yoksa patlamaz", () => {
    expect(serverInjector({}, "browser").get(FeralinService).active).toBe(false);
  });

  it("gizli anahtar sunucuda da reddedilir", () => {
    expect(() => serverInjector({ projectKey: "sk_live_gizli_0001" })).toThrow(/gizli anahtar/);
  });

  it("yalnız pk_ kabul edilir; boşluk ve büyük harf kara listeyi aşamaz", () => {
    for (const bad of [" sk_live_gizli_0001", "SK_LIVE_GIZLI_0001"]) expect(() => serverInjector({ projectKey: bad })).toThrow(/gizli anahtar/);
    expect(() => serverInjector({ projectKey: "rk_live_gizli_0001" })).toThrow(/pk_/);
  });
});
