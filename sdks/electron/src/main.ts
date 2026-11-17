// Electron ana süreç tarafı: @feralin/node istemcisini ipcMain'e bağlar. Proje anahtarı ve ağ burada kalır; web görünümü
// yalnız doğrulanmış çağrı gönderir. Electron bu dosyada içe aktarılmaz, nesneler dışarıdan verilir.
import { randomUUID } from "node:crypto";
import { FeralinClient } from "@feralin/node";
import type { CaptureErrorOptions, Consent, FeralinOptions, FlushResult, RevenueInput, TrackOptions, UtpEvent } from "@feralin/node";
import { FERALIN_CHANNELS } from "./channels.js";
import { DEEP_LINK_EVENT_NAME, deepLinkProperties, normalizeSchemes, parseDeepLink } from "./deeplink.js";

export { FERALIN_CHANNELS } from "./channels.js";
export type { BridgeErrorPayload, BridgeRevenueInput, FeralinBridge, FeralinChannel } from "./channels.js";
export { ATTRIBUTION_SOURCE_APP_LINK, ATTRIBUTION_SOURCE_NONE, DEEP_LINK_EVENT_NAME, parseAttributionQuery, parseDeepLink } from "./deeplink.js";
export type { AttributionParams, ParsedDeepLink } from "./deeplink.js";
export type { CaptureErrorOptions, Consent, FeralinOptions, FlushResult, RevenueInput, TrackOptions, UtpEvent };

/** Electron IpcMainInvokeEvent'in kullanılan kısmı. */
export interface IpcInvokeEventLike {
  senderFrame?: { url?: string; parent?: unknown } | null;
}

export interface IpcMainLike {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- Electron ipcMain.handle imzasıyla uyum (parametre varyansı)
  handle(channel: string, listener: (event: IpcInvokeEventLike, ...args: any[]) => unknown): void;
  removeHandler(channel: string): void;
}

export interface ElectronAppLike {
  getVersion?(): string;
  getLocale?(): string;
  on(event: "will-quit", listener: (event: { preventDefault(): void }) => void): unknown;
  /** macOS: sistem özel şemalı adresi çalışan uygulamaya verir. */
  on(event: "open-url", listener: (event: { preventDefault(): void }, url: string) => void): unknown;
  /** Windows ve Linux: ikinci örnek açılınca birinci örneğe komut satırı gelir (requestSingleInstanceLock gerekir). */
  on(event: "second-instance", listener: (event: unknown, argv: string[]) => void): unknown;
  /** Verilirse `deepLinks.schemes` içindeki her özel şema için çağrılır. */
  setAsDefaultProtocolClient?(protocol: string): boolean;
  quit(): void;
}

/** Derin bağlantı yapılandırması (opt-in). */
export interface FeralinDeepLinkOptions {
  /** Uygulamanın kayıtlı özel şemaları (ör. `["myapp"]`); `https` de yazılabilir ama varsayılan istemci olarak kaydedilmez. */
  schemes: readonly string[];
  /** true (varsayılan): her özel şema `app.setAsDefaultProtocolClient` ile kaydedilir. Paketleyici kaydediyorsa false. */
  registerProtocol?: boolean;
  /** Açılış komut satırı; varsayılan `process.argv`. Windows ve Linux'ta uygulamayı başlatan adres buradadır. */
  argv?: readonly string[];
}

export interface FeralinMainOptions extends Partial<FeralinOptions> {
  ipcMain: IpcMainLike;
  /** Verilirse kapanışta kuyruk gönderilir, sürüm ve dil olaya eklenir. */
  app?: ElectronAppLike;
  client?: FeralinClient;
  /**
   * Çağrı kabul edilen kökenler: şema ve host (ör. "app://arayuz", "file://", "https://uygulama.example.com"). Verilmezse
   * yalnız yerel uygulama içeriği kabul edilir: `app://` ve yerel `file://`. Uzak sayfa ve geliştirme sunucusu açıkça yazılır.
   * Yol içeren, opak ("null", "data:") veya çözümlenemeyen değer kurulumda hata verir.
   */
  allowedOrigins?: readonly string[];
  /** Uygulamanın izinle sakladığı kurulum kimliği. SDK diske yazmaz, üretmez. */
  anonymousId?: string;
  closeTimeoutMs?: number;
  /**
   * Panelin ürettiği kurulum eşleştirme kodu: ilk olaya `fr_install_code` olarak bir kez eklenir (biçim `@feralin/web` ve toplayıcıyla
   * aynı; uymayan kod yok sayılır). `client` verildiyse kodu o istemcinin `installCode` seçeneğine verin.
   */
  installCode?: string;
  /** Verilirse sistem derin bağlantıları (`open-url`, `second-instance`, açılış argv) `deep_link_opened` olarak bildirilir. */
  deepLinks?: FeralinDeepLinkOptions;
}

export interface FeralinMain {
  readonly client: FeralinClient;
  /** Ana süreçten olay: izin ve oturum köprüyle aynıdır. */
  track(eventName: string, properties?: Record<string, unknown>, options?: TrackOptions): UtpEvent | null;
  /** Ana süreçte yakalanan hatayı `fr_error` olarak bildirir; sınır ve izin `@feralin/node` ile aynıdır. */
  captureError(error: unknown, options?: CaptureErrorOptions): UtpEvent | null;
  /** URL'i `deep_link_opened` olarak işler; `deepLinks` verilmediyse, şema izinli değilse ya da izin yoksa null. */
  handleDeepLink(url: string): UtpEvent | null;
  /** IPC işleyicilerini kaldırır ve kuyruğu gönderir. */
  close(timeoutMs?: number): Promise<FlushResult>;
}

function validProperties(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
}

/**
 * Karşılaştırma anahtarı: şema ve host. URL.origin kullanılmaz, çünkü standart dışı şemada ("app://arayuz") ve file'da
 * "null" döner ve hiçbir listeyle eşleşmez. Host'suz adres (data:, about:, blob:, app:/yol) opaktır, null döner; yerel
 * file:// tek istisnadır.
 */
function originKey(parsed: URL): string | null {
  if (!parsed.host && parsed.protocol !== "file:") return null;
  return `${parsed.protocol}//${parsed.host}`.toLowerCase();
}

function originOf(url: unknown): string | null {
  try {
    return typeof url === "string" && url ? originKey(new URL(url)) : null;
  } catch {
    return null;
  }
}

/** Listedeki her değer kurulumda denetlenir: eşleşmesi imkânsız değer sessizce bütün IPC'yi reddettirmesin. */
function normalizeAllowedOrigins(origins: readonly string[] | undefined): ReadonlySet<string> | undefined {
  if (origins === undefined) return undefined;
  if (!Array.isArray(origins)) throw new Error("feralin: allowedOrigins dizi olmalı");
  const keys = new Set<string>();
  for (const entry of origins as readonly unknown[]) {
    let parsed: URL | null = null;
    try {
      parsed = typeof entry === "string" ? new URL(entry.trim()) : null;
    } catch {
      parsed = null;
    }
    const key = parsed && originKey(parsed);
    const bare = parsed && !parsed.username && !parsed.password && !parsed.search && !parsed.hash && (parsed.pathname === "" || parsed.pathname === "/");
    if (!key || !bare) throw new Error(`feralin: allowedOrigins değeri yalnız şema ve host olmalı ("app://arayuz", "file://", "https://uygulama.example.com"); geçersiz: ${JSON.stringify(entry)}`);
    keys.add(key);
  }
  return keys;
}

/** Liste verilmediğinde güvenli varsayılan: uygulamanın kendi paketindeki içerik. UNC yolu (file://sunucu) yerel değildir. */
function isLocalAppContent(url: unknown): boolean {
  try {
    if (typeof url !== "string") return false;
    const parsed = new URL(url);
    return (parsed.protocol === "app:" && parsed.host !== "") || (parsed.protocol === "file:" && parsed.host === "");
  } catch {
    return false;
  }
}

/** Web görünümünden gelen izin yalnız bilinen boolean alanlarla geçer. */
function sanitizeConsent(value: unknown): Consent | null {
  if (!value || typeof value !== "object") return null;
  const input = value as Record<string, unknown>;
  const consent: Consent = { analytics: input.analytics === true };
  if (typeof input.advertising === "boolean") consent.advertising = input.advertising;
  if (typeof input.personalization === "boolean") consent.personalization = input.personalization;
  if (typeof input.session_replay === "boolean") consent.session_replay = input.session_replay;
  return consent;
}

const REVENUE_PURCHASE_TYPES: readonly string[] = ["purchase", "subscription_start", "subscription_renew", "subscription_cancel"];

/** Web görünümünden gelen gelir girdisi: yalnız bilinen alanlar ve türleri geçer; sözleşme doğrulaması `@feralin/node` içindedir. */
function sanitizeRevenueInput(value: unknown): RevenueInput | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const input = value as Record<string, unknown>;
  if (typeof input.transactionId !== "string" || typeof input.amountMinor !== "number" || typeof input.currency !== "string") return null;
  const out: RevenueInput = { transactionId: input.transactionId, amountMinor: input.amountMinor, currency: input.currency };
  if (input.productId !== undefined) {
    if (typeof input.productId !== "string") return null;
    out.productId = input.productId;
  }
  if (input.quantity !== undefined) {
    if (typeof input.quantity !== "number") return null;
    out.quantity = input.quantity;
  }
  if (input.purchaseType !== undefined) {
    if (typeof input.purchaseType !== "string" || !REVENUE_PURCHASE_TYPES.includes(input.purchaseType)) return null;
    out.purchaseType = input.purchaseType as RevenueInput["purchaseType"];
  }
  if (input.receipt !== undefined) {
    const receipt = input.receipt as Record<string, unknown> | null;
    if (!receipt || typeof receipt !== "object" || typeof receipt.provider !== "string" || typeof receipt.token !== "string") return null;
    out.receipt = { provider: receipt.provider as NonNullable<RevenueInput["receipt"]>["provider"], token: receipt.token };
  }
  const properties = validProperties(input.properties);
  if (properties) out.properties = properties;
  return out;
}

const MAX_ERROR_NAME = 128;
const MAX_ERROR_MESSAGE = 2_000;
const MAX_ERROR_STACK = 16_384;
// Web görünümü yalnız bu kökenleri bildirebilir; `uncaught_exception` ve `fatal` ana sürecindir.
const RENDERER_ERROR_ORIGINS: readonly string[] = ["handled", "manual", "window_onerror", "unhandledrejection"];

/** Web görünümünden gelen hata özeti: yalnız dizge alanlar, uzunluk sınırıyla. Yığın izi ana süreçte normalize edilir, ham hâli gönderilmez. */
function sanitizeErrorPayload(value: unknown): { name?: string; message: string; stack?: string } | null {
  if (typeof value === "string") return { message: value.slice(0, MAX_ERROR_MESSAGE) };
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const input = value as Record<string, unknown>;
  const out: { name?: string; message: string; stack?: string } = { message: typeof input.message === "string" ? input.message.slice(0, MAX_ERROR_MESSAGE) : "" };
  if (typeof input.name === "string" && input.name) out.name = input.name.slice(0, MAX_ERROR_NAME);
  if (typeof input.stack === "string") out.stack = input.stack.slice(0, MAX_ERROR_STACK);
  return out;
}

export function createFeralinMain(options: FeralinMainOptions): FeralinMain {
  const { ipcMain, app, client: provided, allowedOrigins, anonymousId, closeTimeoutMs, deepLinks, ...clientOptions } = options;
  // Yapılandırma hatası istemci kurulmadan fırlar: geride çalışan zamanlayıcı kalmasın.
  const allowed = normalizeAllowedOrigins(allowedOrigins);
  const schemes = deepLinks ? normalizeSchemes(deepLinks.schemes) : null;
  const client = provided ?? new FeralinClient(clientOptions as FeralinOptions);
  const sessionId = randomUUID();
  const appVersion = app?.getVersion?.();
  const locale = app?.getLocale?.();

  const defaults = (): TrackOptions => {
    const base: TrackOptions = { sessionId };
    if (anonymousId) base.anonymousId = anonymousId;
    if (appVersion || locale) {
      base.context = {
        ...(appVersion ? { app: { version: appVersion } } : {}),
        ...(locale ? { locale } : {}),
      };
    }
    return base;
  };

  /** Alt çerçeve (ör. gömülü reklam veya üçüncü taraf içerik) ve izinli olmayan köken olay üretemez, izin ve kimliği değiştiremez. */
  const refusalReason = (event: IpcInvokeEventLike): "frame" | "origin" | null => {
    const frame = event?.senderFrame;
    if (!frame || frame.parent) return "frame";
    if (!allowed) return isLocalAppContent(frame.url) ? null : "origin";
    const origin = originOf(frame.url);
    return origin !== null && allowed.has(origin) ? null : "origin";
  };

  /** İzin geri çekme de reddedilebildiği için red görünür kalır. Yalnız kanal, neden ve köken yazılır; anahtar, argüman ve adres yolu yazılmaz. */
  const noteRefusal = (channel: string, reason: "frame" | "origin", event: IpcInvokeEventLike): void => {
    try {
      clientOptions.logger?.debug?.("feralin IPC çağrısı reddedildi", { channel, reason, origin: originOf(event?.senderFrame?.url) });
    } catch {
      // Uygulamanın logger hatası SDK akışını kesmez.
    }
  };

  const emptyFlush = { status: 0, accepted: 0, rejected: 0, retained: 0 };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- işleyiciler argümanı kendisi doğrular (unknown); kayıt tipi varyans için any
  const handlers: Record<string, (...args: any[]) => unknown> = {
    [FERALIN_CHANNELS.track]: (name: unknown, properties: unknown) =>
      typeof name === "string" && client.track(name, validProperties(properties), defaults()) !== null,
    [FERALIN_CHANNELS.page]: (properties: unknown) => client.page(validProperties(properties), defaults()) !== null,
    [FERALIN_CHANNELS.identify]: (userId: unknown) => {
      if (userId === null || typeof userId === "string") client.identify(userId ?? undefined);
    },
    [FERALIN_CHANNELS.setConsent]: (consent: unknown) => {
      const clean = sanitizeConsent(consent);
      if (clean) client.setConsent(clean);
    },
    [FERALIN_CHANNELS.reset]: () => client.reset(),
    [FERALIN_CHANNELS.flush]: async () => {
      const { status, accepted, rejected, retained } = await client.flush();
      return { status, accepted, rejected, retained };
    },
    [FERALIN_CHANNELS.trackRevenue]: (input: unknown) => {
      const clean = sanitizeRevenueInput(input);
      return clean !== null && client.trackRevenue(clean, defaults()) !== null;
    },
    [FERALIN_CHANNELS.group]: (groupId: unknown, traits: unknown) =>
      typeof groupId === "string" && client.group(groupId, validProperties(traits), defaults()) !== null,
    [FERALIN_CHANNELS.setUserProperties]: (properties: unknown) => {
      const clean = validProperties(properties);
      return clean !== undefined && client.setUserProperties(clean, defaults()) !== null;
    },
    [FERALIN_CHANNELS.captureError]: (payload: unknown, origin: unknown) => {
      const error = sanitizeErrorPayload(payload);
      if (!error) return false;
      const safeOrigin = typeof origin === "string" && RENDERER_ERROR_ORIGINS.includes(origin) ? (origin as CaptureErrorOptions["origin"]) : "handled";
      return client.captureError(error, { ...defaults(), origin: safeOrigin, fatal: false }) !== null;
    },
  };

  const refusals: Record<string, unknown> = {
    [FERALIN_CHANNELS.track]: false,
    [FERALIN_CHANNELS.page]: false,
    [FERALIN_CHANNELS.flush]: emptyFlush,
    [FERALIN_CHANNELS.trackRevenue]: false,
    [FERALIN_CHANNELS.group]: false,
    [FERALIN_CHANNELS.setUserProperties]: false,
    [FERALIN_CHANNELS.captureError]: false,
  };

  for (const [channel, handler] of Object.entries(handlers)) {
    ipcMain.handle(channel, (event, ...args) => {
      const reason = refusalReason(event);
      if (reason) {
        noteRefusal(channel, reason, event);
        return refusals[channel];
      }
      try {
        return handler(...args);
      } catch {
        // Web görünümünden gelen hiçbir girdi ana süreci düşürmez.
        clientOptions.logger?.warn?.("feralin IPC çağrısı işlenemedi", { channel });
        return refusals[channel];
      }
    });
  }

  let closing: Promise<FlushResult> | null = null;
  const close = (timeoutMs?: number): Promise<FlushResult> => {
    if (!closing) {
      for (const channel of Object.keys(handlers)) ipcMain.removeHandler(channel);
      closing = client.close(timeoutMs ?? closeTimeoutMs);
    }
    return closing;
  };

  const handleDeepLink = (url: string): UtpEvent | null => {
    try {
      if (!schemes || closing) return null;
      const link = parseDeepLink(url, schemes);
      if (!link) return null;
      const advertising = client.getStatus().consent.advertising === true;
      return client.track(DEEP_LINK_EVENT_NAME, deepLinkProperties(link, advertising), defaults());
    } catch {
      return null;
    }
  };
  /** Komut satırındaki izinli şemalı ilk adres; başka argümanlar (dosya yolu, bayrak) okunmaz. */
  const deepLinkFromArgv = (argv: unknown): void => {
    if (!Array.isArray(argv) || !schemes) return;
    for (const arg of argv as unknown[]) {
      if (typeof arg === "string" && parseDeepLink(arg, schemes)) {
        handleDeepLink(arg);
        return;
      }
    }
  };

  if (deepLinks && schemes) {
    if (app && deepLinks.registerProtocol !== false && typeof app.setAsDefaultProtocolClient === "function") {
      for (const scheme of schemes) {
        // http(s) işletim sisteminin tarayıcısınındır; uygulama onların varsayılan istemcisi yapılmaz.
        if (scheme === "http" || scheme === "https") continue;
        try {
          app.setAsDefaultProtocolClient(scheme);
        } catch {
          clientOptions.logger?.warn?.("feralin deep link şeması kaydedilemedi", { scheme });
        }
      }
    }
    if (app) {
      app.on("open-url", (event, url) => {
        try {
          event?.preventDefault?.();
        } catch {
          // Olay nesnesi beklenen biçimde değilse adres yine işlenir.
        }
        handleDeepLink(url);
      });
      app.on("second-instance", (_event, argv) => deepLinkFromArgv(argv));
    }
    deepLinkFromArgv(deepLinks.argv ?? process.argv);
  }

  if (app) {
    let finished = false;
    app.on("will-quit", (event) => {
      if (finished) return;
      // Kapanış bir kez ertelenir: kuyruk gönderilir, ardından çıkış sürer. Zaman aşımı close içindedir.
      event.preventDefault();
      void close().finally(() => {
        finished = true;
        app.quit();
      });
    });
  }

  return {
    client,
    track: (eventName, properties, extra) => client.track(eventName, properties, { ...defaults(), ...extra }),
    captureError: (error, extra) => client.captureError(error, { ...defaults(), ...extra }),
    handleDeepLink,
    close,
  };
}
