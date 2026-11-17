// Angular bağdaştırıcısı: @feralin/web üstünde provideFeralin ve FeralinService. Dekoratör ve derleyici çıktısı içermez,
// bu yüzden JIT'e düşmeden AOT uygulamalarda çalışır. Sunucuda (Angular SSR) istemci kurulmaz.
import { isPlatformBrowser } from "@angular/common";
import { ENVIRONMENT_INITIALIZER, InjectionToken, PLATFORM_ID, inject, makeEnvironmentProviders } from "@angular/core";
import type { EnvironmentProviders } from "@angular/core";
import { assertProjectKey } from "@feralin/web";
import { acquireFeralin, noopFeralin } from "./handle.js";
import type { Consent, FeralinHandle, FeralinOptions, FeralinStatus, FlushResult, RevenueInput, UtpEvent } from "./handle.js";

export { noopFeralin, releaseFeralin } from "./handle.js";
export type { Consent, FeralinHandle, FeralinOptions, FeralinStatus, FlushResult, RevenueInput, UtpEvent } from "./handle.js";

export const FERALIN_OPTIONS = new InjectionToken<FeralinOptions>("FERALIN_OPTIONS");

/** Sunucuda ve tarayıcıda aynı yüzey; sunucuda tüm çağrılar güvenle hiçbir şey yapmaz. */
export class FeralinService implements FeralinHandle {
  constructor(private readonly feralin: FeralinHandle) {}

  get active(): boolean {
    return this.feralin.active;
  }
  track(eventName: string, properties?: Record<string, unknown>): UtpEvent | null {
    return this.feralin.track(eventName, properties);
  }
  page(properties?: Record<string, unknown>): UtpEvent | null {
    return this.feralin.page(properties);
  }
  trackRevenue(input: RevenueInput): UtpEvent | null {
    return this.feralin.trackRevenue(input);
  }
  identify(userId: string): void {
    this.feralin.identify(userId);
  }
  group(groupId: string, traits?: Record<string, unknown>): UtpEvent | null {
    return this.feralin.group(groupId, traits);
  }
  setUserProperties(properties: Record<string, unknown>): UtpEvent | null {
    return this.feralin.setUserProperties(properties);
  }
  setGlobalProperties(properties: Record<string, unknown>): void {
    this.feralin.setGlobalProperties(properties);
  }
  clearGlobalProperties(): void {
    this.feralin.clearGlobalProperties();
  }
  setConsent(consent: Consent): void {
    this.feralin.setConsent(consent);
  }
  optOut(): void {
    this.feralin.optOut();
  }
  reset(): void {
    this.feralin.reset();
  }
  setReferrer(url?: string): void {
    this.feralin.setReferrer(url);
  }
  flush(): Promise<FlushResult> {
    return this.feralin.flush();
  }
  getStatus(): FeralinStatus | null {
    return this.feralin.getStatus();
  }
}

/** `bootstrapApplication` veya rota sağlayıcılarına eklenir. İstemci açılışta kurulur; autoTrack için servisin enjekte edilmesi beklenmez. */
export function provideFeralin(options: FeralinOptions): EnvironmentProviders {
  return makeEnvironmentProviders([
    { provide: FERALIN_OPTIONS, useValue: options },
    {
      provide: FeralinService,
      useFactory: () => {
        const platform = inject(PLATFORM_ID);
        const resolved = inject(FERALIN_OPTIONS);
        assertProjectKey(resolved?.projectKey);
        return new FeralinService(isPlatformBrowser(platform) ? acquireFeralin(resolved) : noopFeralin);
      },
    },
    {
      provide: ENVIRONMENT_INITIALIZER,
      multi: true,
      useValue: () => {
        inject(FeralinService);
      },
    },
  ]);
}
