// Temiz kurulumdan çalışan tüketici: gerçek Angular enjektörü, sunucu platformu ve jsdom üzerinde gerçek services/collect.
// Tam Angular CLI uygulaması derlenmez; npm paketinin kısmi derlenmiş Angular kodu için JIT yüklenir.
import "@angular/compiler";
import assert from "node:assert/strict";
import { ErrorHandler, PLATFORM_ID, Injector, createEnvironmentInjector } from "@angular/core";
import { FeralinService, provideFeralin, releaseFeralin } from "@feralin/angular";
import { env, installDom, runErrorScenario, runWebScenarios } from "./web-scenarios.mjs";

const { collectUrl, projectKey } = env();
const injector = (providers) => createEnvironmentInjector(providers, Injector.NULL);

assert.equal(typeof window, "undefined");
const server = injector([{ provide: PLATFORM_ID, useValue: "server" }, provideFeralin({ projectKey, collectUrl, consent: { analytics: true } })]).get(FeralinService);
assert.equal(server.active, false);
assert.equal(server.track("server_side"), null);
console.log("  OK ssr-window-yok");

installDom();

async function mount(options) {
  return injector([{ provide: PLATFORM_ID, useValue: "browser" }, provideFeralin(options)]).get(FeralinService);
}

await runWebScenarios({ mount, release: async (options) => releaseFeralin(options), label: "angular" });

// ErrorHandler sağlayıcısı: enjektördeki ErrorHandler hatayı alır, fr_error gönderir ve delegate'i zincirler.
const angularPackage = await import("@feralin/angular");
await runErrorScenario({
  supported: typeof angularPackage.provideFeralinErrorHandler === "function",
  label: "angular",
  release: async (options) => releaseFeralin(options),
  trigger: async (options, message) => {
    const delegated = [];
    const scope = injector([
      { provide: PLATFORM_ID, useValue: "browser" },
      provideFeralin(options),
      angularPackage.provideFeralinErrorHandler({ delegate: { handleError: (error) => delegated.push(error) } }),
    ]);
    scope.get(ErrorHandler).handleError(new TypeError(message));
    assert.equal(delegated.length, 1, "delegate zincirde çağrılmalı");
    return scope.get(FeralinService);
  },
});
console.log("angular tüketici: tüm senaryolar geçti");
process.exit(0);
