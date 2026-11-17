// NestJS bağdaştırıcısı: @feralin/node üstünde küresel modül, servis ve istek başına bağlam. Dekoratör metadata'sı
// gerekmez: sağlayıcılar useFactory ile kurulur, tüketicinin derleyici ayarına bağlı değildir. Express veya Fastify
// farketmez; yalnız istek nesnesi başlıkları okunur. IP, User-Agent ve çerez okunmaz.
import { AsyncLocalStorage } from "node:async_hooks";
import { createParamDecorator } from "@nestjs/common";
import type { CallHandler, DynamicModule, ExecutionContext, InjectionToken, NestInterceptor, OnApplicationShutdown, OptionalFactoryDependency, Provider } from "@nestjs/common";
import { APP_INTERCEPTOR } from "@nestjs/core";
import { FeralinClient } from "@feralin/node";
import type { Consent, FeralinOptions, FeralinStatus, FlushResult, TrackOptions, UtpEvent } from "@feralin/node";
import { Observable } from "rxjs";

export type { Consent, FeralinOptions, FeralinStatus, FlushResult, TrackOptions, UtpEvent };

export const FERALIN_MODULE_OPTIONS = Symbol("FERALIN_MODULE_OPTIONS");

/** Çerçeve istek nesnesi; Express ve Fastify ikisinde de `headers` vardır. */
export type FeralinRequest = { headers?: Record<string, unknown>; feralin?: RequestFeralin } & Record<string, unknown>;

export interface FeralinModuleOptions extends FeralinOptions {
  /** Bu isteğin son kullanıcısının izni. Çözümleyici yoksa `consent` varsayılanı geçerlidir; undefined dönerse veya hata atarsa analytics=false kabul edilir. */
  resolveConsent?: (req: FeralinRequest) => Consent | undefined;
  /** E-posta veya telefon döndürmeyin; uygulamanın kendi kullanıcı kimliği (≤128 karakter). */
  resolveUserId?: (req: FeralinRequest) => string | undefined;
  resolveAnonymousId?: (req: FeralinRequest) => string | undefined;
  resolveSessionId?: (req: FeralinRequest) => string | undefined;
}

export interface FeralinModuleAsyncOptions {
  imports?: DynamicModule["imports"];
  inject?: Array<InjectionToken | OptionalFactoryDependency>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- Nest useFactory sözleşmesi: inject edilen bağımlılık tipleri bilinmez
  useFactory: (...args: any[]) => FeralinModuleOptions | Promise<FeralinModuleOptions>;
}

/** O isteğe bağlı yüzey: izin ve kimlik her olaya otomatik eklenir, başka isteği ve paylaşılan istemciyi etkilemez. */
export interface RequestFeralin {
  /** Bu isteğin geçerli izni; `setConsent` sonrası yeni değeri verir. */
  readonly consent: Consent;
  track(eventName: string, properties?: Record<string, unknown>, options?: TrackOptions): UtpEvent | null;
  page(properties?: Record<string, unknown>, options?: TrackOptions): UtpEvent | null;
  flush(): Promise<FlushResult>;
  /** Yalnız bu isteğin sonraki olayları için; boş değer kimliği kaldırır, 128 karakteri aşan değer yok sayılır. */
  identify(userId: string | undefined): void;
  /** Yalnız bu isteğin sonraki olayları için. Kalıcı değildir; kuyruğa girmiş olayları silmez. Ret, olay bazlı izinle aşılmaz. */
  setConsent(consent: Consent): void;
}

const NO_CONSENT: Consent = Object.freeze({ analytics: false });
// @feralin/node istemcisinin kimlik sınırıyla aynıdır; bu sabit paketten dışa açılmaz.
const MAX_USER_ID_LENGTH = 128;

export class FeralinService implements OnApplicationShutdown {
  /** Tüm isteklerin paylaştığı istemci: flush ve durum içindir. `client.identify`, `client.setConsent`, `client.optOut` ve `client.reset` istek işlerken çağrılmaz; herkesi etkiler. */
  readonly client: FeralinClient;
  private readonly scope = new AsyncLocalStorage<RequestFeralin>();

  constructor(private readonly options: FeralinModuleOptions) {
    // Yapılandırma hatası uygulama açılışında fırlar (sk_ anahtar, geçersiz adres).
    const { resolveConsent: _a, resolveUserId: _b, resolveAnonymousId: _c, resolveSessionId: _d, ...clientOptions } = options;
    this.client = new FeralinClient(clientOptions);
  }

  /** HTTP isteği içinde o isteğin izni ve kimliği geçerlidir. İstek dışı işlerde (cron, kuyruk, RPC, WebSocket) izin ve kimlik `options.consent` ve `options.userId` ile olay başına verilir. */
  track(eventName: string, properties?: Record<string, unknown>, options?: TrackOptions): UtpEvent | null {
    const current = this.scope.getStore();
    return current ? current.track(eventName, properties, options) : this.client.track(eventName, properties, options);
  }
  /** Yalnız o isteğin kimliğini değiştirir. İstek dışında hata verir: paylaşılan istemciye yazılsa başka kullanıcıların olayına sızardı. */
  identify(userId: string | undefined): void {
    this.requireScope("identify").identify(userId);
  }
  /** Yalnız o isteğin iznini değiştirir. İstek dışında hata verir: paylaşılan istemciye yazılan ret herkesin olayını durdururdu. */
  setConsent(consent: Consent): void {
    this.requireScope("setConsent").setConsent(consent);
  }
  flush(): Promise<FlushResult> {
    return this.client.flush();
  }
  getStatus(): FeralinStatus {
    return this.client.getStatus();
  }

  /** İstek için izin ve kimlik çözer. Çözümleyici hatası uygulamayı düşürmez, izin yok sayılır. */
  forRequest(req: FeralinRequest): RequestFeralin {
    let consent = this.options.resolveConsent ? (this.resolve(this.options.resolveConsent, req) ?? NO_CONSENT) : this.client.getStatus().consent;
    let withdrawn = false;
    const base: TrackOptions = {};
    const userId = this.resolve(this.options.resolveUserId, req);
    const anonymousId = this.resolve(this.options.resolveAnonymousId, req);
    const sessionId = this.resolve(this.options.resolveSessionId, req);
    if (userId) base.userId = userId;
    if (anonymousId) base.anonymousId = anonymousId;
    if (sessionId) base.sessionId = sessionId;
    const merge = (extra?: TrackOptions): TrackOptions => ({ ...base, ...extra, consent: extra?.consent ?? consent });
    return {
      get consent() {
        return consent;
      },
      track: (eventName, properties, extra) => (withdrawn ? null : this.client.track(eventName, properties, merge(extra))),
      page: (properties, extra) => (withdrawn ? null : this.client.page(properties, merge(extra))),
      flush: () => this.client.flush(),
      identify: (next) => {
        if (next === undefined || next === "") delete base.userId;
        else if (typeof next === "string" && next.length <= MAX_USER_ID_LENGTH) base.userId = next;
        else this.options.logger?.warn?.("geçersiz user_id yok sayıldı");
      },
      setConsent: (next) => {
        consent = { ...next };
        withdrawn = next?.analytics !== true;
      },
    };
  }

  /** `fn` ve başlattığı asenkron işler içinde `identify`, `setConsent` ve `track` bu kapsama gider. Interceptor her HTTP isteğini bununla sarar. */
  runInScope<T>(scope: RequestFeralin, fn: () => T): T {
    return this.scope.run(scope, fn);
  }

  private requireScope(method: string): RequestFeralin {
    const current = this.scope.getStore();
    if (!current) throw new Error(`feralin: FeralinService.${method} yalnız HTTP isteği içinde çağrılır; istek dışı işlerde izni ve kimliği track(ad, ozellikler, { consent, userId }) ile olay başına verin`);
    return current;
  }

  private resolve<T>(resolver: ((req: FeralinRequest) => T) | undefined, req: FeralinRequest): T | undefined {
    if (!resolver) return undefined;
    try {
      return resolver(req);
    } catch {
      this.options.logger?.warn?.("çözümleyici hata verdi, değer yok sayıldı");
      return undefined;
    }
  }

  /** `app.close()` veya `enableShutdownHooks` ile sinyal geldiğinde kuyruk gönderilir. */
  async onApplicationShutdown(): Promise<void> {
    await this.client.close();
  }
}

/** HTTP isteklerine `req.feralin` ekler ve isteği kendi kapsamında çalıştırır; HTTP dışı bağlamlara (RPC, WebSocket) dokunmaz. */
export class FeralinInterceptor implements NestInterceptor {
  constructor(private readonly feralin: FeralinService) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    if (context.getType() !== "http") return next.handle();
    const req = context.switchToHttp().getRequest<FeralinRequest>();
    const scope = this.feralin.forRequest(req);
    req.feralin = scope;
    // İşleyici abone olununca çalışır: kapsam `next.handle()` çağrısını değil aboneliği sarmalıdır.
    return new Observable((subscriber) => this.feralin.runInScope(scope, () => next.handle().subscribe(subscriber)));
  }
}

/** Denetleyici parametresi: `@CurrentFeralin() feralin: RequestFeralin`. */
export const CurrentFeralin = createParamDecorator((_data: unknown, context: ExecutionContext): RequestFeralin | undefined => {
  return context.switchToHttp().getRequest<FeralinRequest>().feralin;
});

function sharedProviders(): Provider[] {
  return [
    { provide: FeralinService, useFactory: (options: FeralinModuleOptions) => new FeralinService(options), inject: [FERALIN_MODULE_OPTIONS] },
    { provide: APP_INTERCEPTOR, useFactory: (service: FeralinService) => new FeralinInterceptor(service), inject: [FeralinService] },
  ];
}

export class FeralinModule {
  static forRoot(options: FeralinModuleOptions): DynamicModule {
    return {
      module: FeralinModule,
      global: true,
      providers: [{ provide: FERALIN_MODULE_OPTIONS, useValue: options }, ...sharedProviders()],
      exports: [FeralinService],
    };
  }

  static forRootAsync(options: FeralinModuleAsyncOptions): DynamicModule {
    return {
      module: FeralinModule,
      global: true,
      imports: options.imports ?? [],
      providers: [{ provide: FERALIN_MODULE_OPTIONS, useFactory: options.useFactory, inject: options.inject ?? [] }, ...sharedProviders()],
      exports: [FeralinService],
    };
  }
}
