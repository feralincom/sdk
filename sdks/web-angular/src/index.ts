// Angular bağdaştırıcısı: @feralin/web üstünde provideFeralin ve FeralinService. Dekoratör ve derleyici çıktısı içermez,
// bu yüzden JIT'e düşmeden AOT uygulamalarda çalışır. Sunucuda (Angular SSR) istemci kurulmaz.
import { isPlatformBrowser } from "@angular/common";
import { ENVIRONMENT_INITIALIZER, ErrorHandler, InjectionToken, PLATFORM_ID, inject, makeEnvironmentProviders } from "@angular/core";
import type { EnvironmentProviders } from "@angular/core";
import { assertProjectKey } from "@feralin/web";
import { reportFrameworkError } from "./errors.js";
import type { FeralinErrorOptions } from "./errors.js";
import { acquireFeralin, noopFeralin } from "./handle.js";
import type { Consent, FeralinHandle, FeralinOptions, FeralinStatus, FlushResult, RevenueInput, UtpEvent } from "./handle.js";

export { reportFrameworkError } from "./errors.js";
export type { FeralinErrorOptions } from "./errors.js";
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

export interface FeralinErrorHandlerOptions extends FeralinErrorOptions {
  /**
   * Bildirimden sonra çağrılacak işleyici (uygulamanın kendi `ErrorHandler`'ı). Verilmezse Angular'ın varsayılanı gibi
   * `console.error("ERROR", hata)` yazılır.
   */
  delegate?: { handleError(error: unknown): void };
}

/**
 * Angular `ErrorHandler`: bileşen, değişiklik algılama ve (`provideBrowserGlobalErrorListeners` açıksa) pencere hatalarını `fr_error`
 * olarak bildirir (`origin: "uncaught_exception"`, `handled: false`), sonra işleyiciyi zincirler. İzin, örnekleme, sınır ve PII
 * temizliği Web SDK'nınkidir. Sunucuda (Angular SSR) istemci boş olduğundan olay üretmez; işleyici yine çağrılır.
 */
export class FeralinErrorHandler extends ErrorHandler {
  constructor(
    private readonly feralin: FeralinHandle | null,
    private readonly options: FeralinErrorHandlerOptions = {},
  ) {
    super();
  }

  override handleError(error: unknown): void {
    const { delegate, ...errorOptions } = this.options;
    if (this.feralin) void reportFrameworkError(this.feralin, error, errorOptions);
    if (delegate) delegate.handleError(error);
    else super.handleError(error);
  }
}

/** `ErrorHandler` sağlayıcısı; `provideFeralin` ile birlikte `bootstrapApplication` sağlayıcılarına eklenir. */
export function provideFeralinErrorHandler(options: FeralinErrorHandlerOptions = {}): EnvironmentProviders {
  return makeEnvironmentProviders([
    { provide: ErrorHandler, useFactory: () => new FeralinErrorHandler(inject(FeralinService, { optional: true }), options) },
  ]);
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
