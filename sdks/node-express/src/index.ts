// Express ara katmanı: @feralin/node üstünde, isteğe bağlı izin ve kimlik geçirme. Ara katman uygulamayı düşürmez:
// çözümleyici hatası "izin yok" sayılır. IP, User-Agent ve çerez okunmaz, sorgu dizgisi gönderilmez.
import { FeralinClient } from "@feralin/node";
import type { Consent, EventContext, FeralinOptions, FlushResult, TrackOptions, UtpEvent } from "@feralin/node";
import type { NextFunction, Request, RequestHandler, Response } from "express";

export type { Consent, EventContext, FeralinOptions, FlushResult, TrackOptions, UtpEvent };

/** O isteğe bağlı yüzey: izin ve kimlik her olaya otomatik eklenir. */
export interface RequestFeralin {
  track(eventName: string, properties?: Record<string, unknown>, options?: TrackOptions): UtpEvent | null;
  page(properties?: Record<string, unknown>, options?: TrackOptions): UtpEvent | null;
  flush(): Promise<FlushResult>;
  readonly consent: Consent;
}

export interface FeralinExpressOptions extends Partial<FeralinOptions> {
  /** Paylaşılan istemci. Verilmezse projectKey ve collectUrl ile kurulur. */
  client?: FeralinClient;
  /** Bu isteğin son kullanıcısının izni. Çözümleyici yoksa istemcinin varsayılanı geçerlidir; undefined dönerse veya hata atarsa analytics=false kabul edilir. */
  resolveConsent?: (req: Request) => Consent | undefined;
  /** E-posta veya telefon döndürmeyin; uygulamanın kendi kullanıcı kimliği (≤128 karakter). */
  resolveUserId?: (req: Request) => string | undefined;
  resolveAnonymousId?: (req: Request) => string | undefined;
  resolveSessionId?: (req: Request) => string | undefined;
  /** page_url (yol), referrer (yalnız origin) ve locale eklensin. Varsayılan true. Yolda kişisel veri varsa kapatın. */
  includeContext?: boolean;
  /** Yanıt bitince `http_request` olayı üretir: yöntem, rota kalıbı, durum, süre. Varsayılan false. */
  trackRequests?: boolean;
}

export interface FeralinMiddleware extends RequestHandler {
  readonly client: FeralinClient;
  /** Kuyruğu gönderir ve arka plan göndericiyi durdurur. Yalnız ara katmanın kurduğu istemci için kapanış sorumluluğu buradadır. */
  close(timeoutMs?: number): Promise<FlushResult>;
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      feralin: RequestFeralin;
    }
  }
}

const NO_CONSENT: Consent = Object.freeze({ analytics: false });

function resolveSafely<T>(resolver: ((req: Request) => T) | undefined, req: Request, warn: (message: string) => void): T | undefined {
  if (!resolver) return undefined;
  try {
    return resolver(req);
  } catch {
    warn("çözümleyici hata verdi, değer yok sayıldı");
    return undefined;
  }
}

function requestContext(req: Request): EventContext {
  const context: EventContext = {};
  const host = req.get("host");
  if (host) context.page_url = `${req.protocol}://${host}${req.originalUrl}`;
  const referrer = req.get("referer");
  if (referrer) context.referrer = referrer;
  const locale = req.get("accept-language")?.split(",")[0]?.split(";")[0]?.trim();
  if (locale) context.locale = locale;
  return context;
}

/** Yol yerine rota kalıbı: /users/42 değil /users/:id; kimlik içeren yol olaya girmez. */
function routePattern(req: Request): string {
  const path = (req.route as { path?: unknown } | undefined)?.path;
  return typeof path === "string" ? `${req.baseUrl}${path}` : "unmatched";
}

export function feralinMiddleware(options: FeralinExpressOptions): FeralinMiddleware {
  const { client: provided, resolveConsent, resolveUserId, resolveAnonymousId, resolveSessionId, includeContext = true, trackRequests = false, ...clientOptions } = options;
  // Yapılandırma hatası uygulama açılışında fırlar (sk_ anahtar, geçersiz adres).
  const client = provided ?? new FeralinClient(clientOptions as FeralinOptions);
  const warn = (message: string) => clientOptions.logger?.warn?.(message);

  const middleware = ((req: Request, res: Response, next: NextFunction) => {
    const consent = resolveConsent ? (resolveSafely(resolveConsent, req, warn) ?? NO_CONSENT) : client.getStatus().consent;
    const base: TrackOptions = { consent };
    const userId = resolveSafely(resolveUserId, req, warn);
    const anonymousId = resolveSafely(resolveAnonymousId, req, warn);
    const sessionId = resolveSafely(resolveSessionId, req, warn);
    if (userId) base.userId = userId;
    if (anonymousId) base.anonymousId = anonymousId;
    if (sessionId) base.sessionId = sessionId;
    // Bağlam yalnız izin varsa hesaplanır; izinsiz istekte başlıklara dokunulmaz.
    if (includeContext && consent.analytics === true) base.context = requestContext(req);

    const merge = (extra?: TrackOptions): TrackOptions => ({ ...base, ...extra, consent: extra?.consent ?? consent });
    req.feralin = {
      consent,
      track: (eventName, properties, extra) => client.track(eventName, properties, merge(extra)),
      page: (properties, extra) => client.page(properties, merge(extra)),
      flush: () => client.flush(),
    };

    if (trackRequests && consent.analytics === true) {
      const startedAt = performance.now();
      res.once("finish", () => {
        client.track(
          "http_request",
          { method: req.method, route: routePattern(req), status_code: res.statusCode, duration_ms: Math.round(performance.now() - startedAt) },
          merge(),
        );
      });
    }
    next();
  }) as FeralinMiddleware;

  Object.defineProperty(middleware, "client", { value: client, enumerable: true });
  Object.defineProperty(middleware, "close", { value: (timeoutMs?: number) => client.close(timeoutMs), enumerable: true });
  return middleware;
}
