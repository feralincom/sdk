// JS yüzeyi: doğrulama burada, davranış Android çekirdeğindedir (kuyruk, izin, idempotency, geri çekilme). Hiçbir metot
// uygulamaya hata fırlatmaz ve reddedilen Promise döndürmez. Yerel modül yoksa (iOS, bağlanmamış paket) SDK kapalı kalır.

export const SDK_NAME = "@feralin/react-native";
export const SDK_VERSION = "0.2.0";

import {
  AD_REVENUE_EVENT_NAME,
  ECONOMY_SINK_EVENT,
  ECONOMY_SOURCE_EVENT,
  ERROR_EVENT_NAME,
  ERROR_ORIGIN_HANDLED,
  ERROR_ORIGIN_REJECTION,
  ERROR_ORIGIN_UNCAUGHT,
  ErrorLimiter,
  IAP_INITIATED_EVENT,
  IAP_OFFER_SHOWN_EVENT,
  LEVEL_COMPLETE_EVENT,
  LEVEL_FAIL_EVENT,
  LEVEL_START_EVENT,
  REWARDED_COMPLETE_EVENT,
  REWARDED_SHOWN_EVENT,
  adRevenueProperties,
  economyProperties,
  errorProperties,
  iapInitiatedProperties,
  iapOfferShownProperties,
  levelCompleteProperties,
  levelFailProperties,
  levelStartProperties,
  rewardedCompleteProperties,
  rewardedShownProperties,
} from "./signals";
import type { AdRevenueInput, EconomyOptions, ErrorOrigin, LevelOptions } from "./signals";

export type { AdFormat, AdPrecision, AdRevenueInput, EconomyOptions, LevelOptions } from "./signals";

export interface Consent {
  analytics: boolean;
  advertising?: boolean;
  personalization?: boolean;
  session_replay?: boolean;
}

/** Kurulum eşleştirme kodu biçimi (Android çekirdeği ve toplayıcıyla aynı). */
export const INSTALL_CODE_PATTERN = /^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$/;

export interface FeralinConfig {
  /** Public proje anahtarı (pk_…). Yalnız x-feralin-project-key başlığında taşınır; sk_ reddedilir. */
  projectKey: string;
  /** Toplayıcı kökü, ör. https://collect.example.com. */
  collectUrl: string;
  /** Verilmezse izin bekleniyor demektir: olay üretilmez, depodaki kuyruk silinmez. */
  consent?: Consent;
  flushIntervalMs?: number;
  batchSize?: number;
  queueLimit?: number;
  sessionTimeoutMs?: number;
  autoCaptureDeepLinks?: boolean;
  /** true ise Logcat'e olay adı ve durum kodu yazılır; anahtar ve özellik değeri yazılmaz. */
  debug?: boolean;
  /** Uygulama sürümü (≤ 32); yalnız `fr_error` olaylarının `app_version` alanı için JS tarafında kullanılır, yerel katmana gitmez. */
  appVersion?: string;
  /**
   * Kurulum eşleştirme kodu: panelin "Kurulumu doğrula" ekranında üretilen tek kullanımlık kod. Yerel çekirdeğe iletilir; izin verildikten
   * sonra kuyruğa giren ilk olaya `fr_install_code` olarak eklenir ve sunucu kurulumu projeye bağlar. Biçimi geçersizse yok sayılır.
   */
  installCode?: string;
}

/** `captureUncaughtErrors` seçenekleri. */
export interface UncaughtErrorOptions {
  /** Örnekleme oranı 0..1 (varsayılan 1). */
  sampleRate?: number;
  /**
   * İşlenmemiş Promise reddini de bildirir. Varsayılan: yalnız yayın (release) derlemesinde açık; geliştirmede React Native'in kendi
   * reddedilmiş Promise uyarısının yerine geçeceği için kapalıdır.
   */
  promiseRejections?: boolean;
}

/** RN'in `ErrorUtils` yüzü; test için sahte verilebilir. */
export interface ErrorUtilsLike {
  getGlobalHandler(): ((error: unknown, isFatal?: boolean) => void) | undefined;
  setGlobalHandler(handler: (error: unknown, isFatal?: boolean) => void): void;
}

/** Ortam bağlantıları (RN çalışma zamanı); çekirdek RN içe aktarmaz. */
export interface ErrorHooks {
  errorUtils?: ErrorUtilsLike | null;
  /** İşlenmemiş Promise reddi izleyicisini açar; açılamazsa `false`. */
  trackRejections?: (onUnhandled: (reason: unknown) => void) => boolean;
  /** Geliştirme derlemesi mi (`__DEV__`). */
  dev?: boolean;
}

export interface FlushResult {
  sent: number;
  accepted: number;
  rejected: number;
  /** 0: istek yapılmadı veya ağ hatası. */
  status: number;
  batchId: string | null;
}

/**
 * Ertelenmiş derin bağlantı sonucu. `path` dışarıdan gelen veridir: uygulama kendi yönlendirme tablosuyla eşleştirmelidir.
 * `not_supported`: iOS'ta App Store parametreyi kuruluma taşımaz, parmak iziyle eşleştirme yasaktır.
 */
export interface DeferredDeepLink {
  status: "delivered" | "none" | "consent_required" | "not_supported" | "not_initialized";
  path: string | null;
}

export interface FeralinStatus {
  initialized: boolean;
  /** Kapalıysa neden: yerel köprü yok veya yapılandırma geçersiz. */
  unavailable: string | null;
  sdk: string;
  version: string;
  queued: number;
  consent: Consent | null;
  anonymousId: string | null;
  sessionId: string | null;
  userId: string | null;
}

export type PurchaseType = "purchase" | "subscription_start" | "subscription_renew" | "subscription_cancel";
export type ReceiptProvider = "apple" | "google" | "stripe";

/**
 * `trackRevenue` girdisi (F5-E04-T01), Android ve Flutter SDK'larıyla aynı sözleşme. İstemci beyanıdır: `verified` hiçbir zaman
 * gönderilmez; sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar.
 */
export interface RevenueInput {
  /** Mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz (≤128); sunucu aynı işlemi ikinci kez saymaz. */
  transactionId: string;
  /** Küçük birimde satır toplamı: 49,99 TL için 4999. Güvenli tam sayı; abonelik iptalinde 0. */
  amountMinor: number;
  /** ISO 4217, üç büyük harf. */
  currency: string;
  productId?: string;
  quantity?: number;
  purchaseType?: PurchaseType;
  /** İsteğe bağlı ham makbuz; toplayıcı yalnız sağlayıcı adını ve belirtecin SHA-256 özetini saklar. */
  receipt?: { provider: ReceiptProvider; token: string };
  /** Ek özellikler; `verified` ve türevleri düşürülür. */
  properties?: Record<string, unknown>;
}

/**
 * Kurulum kimliği bağlama sonucu (F3-E02-T02, ADR-0007). Yalnız iOS'ta anlamlıdır: AdServices token'ını Swift SDK ya da iOS yerel
 * modülü alır. Android'de Play Install Referrer yolu kullanılır; iOS dışında ve yerel iOS modülü yokken `unsupported`.
 */
export interface InstallBinding {
  status:
    | "received"
    | "skipped_no_consent"
    | "not_configured"
    | "unsupported"
    | "token_unavailable"
    | "rejected"
    | "temporary_failure"
    | "not_initialized";
  /** Hesap eşleştirme için müşteri sunucusuna iletilecek kurulum kimliği; izin ya da yerel destek yoksa `null`. */
  installId: string | null;
}

/** Yerel modülün JS'e açtığı yüzey (FeralinReactModule.kt). */
export interface NativeBridge {
  initialize(config: Record<string, unknown>): Promise<boolean>;
  setConsent(consent: Record<string, unknown>): void;
  optOut(): void;
  track(name: string, properties: Record<string, unknown> | null): Promise<string | null>;
  screen(name: string, properties: Record<string, unknown> | null): Promise<string | null>;
  identify(userId: string): void;
  reset(): void;
  flush(): Promise<Record<string, unknown>>;
  getStatus(): Promise<Record<string, unknown>>;
  consumeDeferredDeepLink?(): Promise<Record<string, unknown> | null>;
  /** Yalnız iOS yerel modülünde olur (henüz yok): AdServices token'ını alır, gönderir ve kurulum kimliğini döndürür. */
  bindInstall?(): Promise<Record<string, unknown> | null>;
}

const NO_FLUSH: Readonly<FlushResult> = Object.freeze({ sent: 0, accepted: 0, rejected: 0, status: 0, batchId: null });
const EVENT_NAME = /^[a-z][a-z0-9_]*$/;
const PROPERTY_KEY = /^[a-zA-Z][a-zA-Z0-9_]{0,63}$/;
const MAX_PROPERTIES = 100;
const MAX_ID_LENGTH = 128;

/** Gelir olayı: Android `RevenueEvent.kt` ve Flutter `revenue_event.dart` ile birebir. */
export const REVENUE_EVENT_NAME = "feralin_purchase";
/** Kimlik olayları: sistem olayı ön eki `fr_`; sunucuda ayrı profil deposu yoktur, olay olarak saklanır. */
export const GROUP_EVENT_NAME = "fr_group";
export const USER_PROPERTIES_EVENT_NAME = "fr_user_properties";
const MAX_AMOUNT_MINOR = Number.MAX_SAFE_INTEGER;
const MAX_QUANTITY = 100_000;
const CURRENCY = /^[A-Z]{3}$/;
const PURCHASE_TYPES: readonly string[] = ["purchase", "subscription_start", "subscription_renew", "subscription_cancel"];
const RECEIPT_PROVIDERS: readonly string[] = ["apple", "google", "stripe"];
// İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
const RESERVED_REVENUE_KEYS = ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"];

/** RN köprüsünün taşıyamadığı değerler atılır; undefined köprüde ReadableMap hatası üretirdi. */
function cleanValue(value: unknown, depth: number): unknown {
  if (depth > 8) return undefined;
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  if (Array.isArray(value)) {
    return value.map((item) => cleanValue(item, depth + 1)).filter((item) => item !== undefined);
  }
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
      const clean = cleanValue(item, depth + 1);
      if (clean !== undefined) out[key] = clean;
    }
    return out;
  }
  return undefined;
}

function cleanProperties(properties: Record<string, unknown> | undefined): Record<string, unknown> | null {
  if (!properties || typeof properties !== "object") return null;
  const out: Record<string, unknown> = {};
  let count = 0;
  for (const [key, value] of Object.entries(properties)) {
    if (count >= MAX_PROPERTIES) break;
    if (!PROPERTY_KEY.test(key)) continue;
    const clean = cleanValue(value, 0);
    if (clean === undefined) continue;
    out[key] = clean;
    count++;
  }
  return count > 0 ? out : null;
}

/** Gelir olayının özelliklerini kurar; sözleşme dışı girdide `null` döner (olay üretilmez). */
export function revenueProperties(input: RevenueInput): Record<string, unknown> | null {
  if (!input || typeof input !== "object") return null;
  const { transactionId, amountMinor, currency, productId, receipt } = input;
  const quantity = input.quantity ?? 1;
  const purchaseType = input.purchaseType ?? "purchase";
  if (typeof transactionId !== "string" || transactionId.length === 0 || transactionId.length > MAX_ID_LENGTH) return null;
  if (!Number.isSafeInteger(amountMinor) || amountMinor < 0 || amountMinor > MAX_AMOUNT_MINOR) return null;
  if (typeof currency !== "string" || !CURRENCY.test(currency)) return null;
  if (productId !== undefined && (typeof productId !== "string" || productId.length === 0 || productId.length > MAX_ID_LENGTH)) return null;
  if (!Number.isSafeInteger(quantity) || quantity < 0 || quantity > MAX_QUANTITY) return null;
  if (!PURCHASE_TYPES.includes(purchaseType)) return null;
  // Abonelik iptali para taşımaz; defter tutarsız iptali reddeder.
  if (purchaseType === "subscription_cancel" && amountMinor !== 0) return null;
  if (receipt !== undefined) {
    if (!receipt || !RECEIPT_PROVIDERS.includes(receipt.provider)) return null;
    if (typeof receipt.token !== "string" || receipt.token.length === 0 || receipt.token.length > 8192) return null;
  }
  const out: Record<string, unknown> = { ...(cleanProperties(input.properties) ?? {}) };
  for (const key of RESERVED_REVENUE_KEYS) delete out[key];
  out.transaction_id = transactionId;
  out.amount_minor = amountMinor;
  out.currency = currency;
  out.quantity = quantity;
  out.purchase_type = purchaseType;
  if (productId !== undefined) out.product_id = productId;
  if (receipt !== undefined) out.receipt = { provider: receipt.provider, token: receipt.token };
  return out;
}

function cleanConsent(consent: Consent): Record<string, unknown> {
  const out: Record<string, unknown> = { analytics: consent.analytics === true };
  if (typeof consent.advertising === "boolean") out.advertising = consent.advertising;
  if (typeof consent.personalization === "boolean") out.personalization = consent.personalization;
  if (typeof consent.session_replay === "boolean") out.session_replay = consent.session_replay;
  return out;
}

export function createFeralin(native: NativeBridge | null | undefined, os: string) {
  let unavailable: string | null = native ? null : `yerel köprü yok (${os})`;
  let initialized = false;
  let appVersion: string | undefined;
  let limiter = new ErrorLimiter();
  let uncaughtInstalled = false;

  const offline = (): FeralinStatus => ({
    initialized: false,
    unavailable,
    sdk: SDK_NAME,
    version: SDK_VERSION,
    queued: 0,
    consent: null,
    anonymousId: null,
    sessionId: null,
    userId: null,
  });

  /** Köprü hatası uygulamaya geçmez; yalnız türü tutulur, mesajda anahtar olabilir. */
  const guard = async <T>(fallback: T, call: () => Promise<T>): Promise<T> => {
    try {
      return await call();
    } catch {
      return fallback;
    }
  };
  const fire = (call: () => void): void => {
    try {
      call();
    } catch {
      // Köprü hatası uygulamayı düşürmez.
    }
  };
  const ready = (): NativeBridge | null => (native && initialized ? native : null);

  const signal = (name: string, properties: Record<string, unknown> | null): Promise<string | null> => {
    const bridge = ready();
    if (!bridge || !properties) return Promise.resolve(null);
    return guard(null, () => bridge.track(name, properties));
  };

  const report = (error: unknown, origin: ErrorOrigin, fatal: boolean): Promise<string | null> => {
    const bridge = ready();
    if (!bridge) return Promise.resolve(null);
    try {
      const props = errorProperties(error, origin, fatal, appVersion);
      if (!limiter.allow(props.fingerprint as string)) return Promise.resolve(null);
      return guard(null, () => bridge.track(ERROR_EVENT_NAME, props));
    } catch {
      // Hata bildirimi uygulamayı düşüremez.
      return Promise.resolve(null);
    }
  };

  return {
    /** Application yerine JS'ten çağrılır; ikinci çağrı yok sayılır. true: SDK etkin. */
    async initialize(config: FeralinConfig): Promise<boolean> {
      if (!native) return false;
      const key = typeof config?.projectKey === "string" ? config.projectKey.trim() : "";
      if (!key || key.startsWith("sk_")) {
        unavailable = "geçersiz proje anahtarı";
        return false;
      }
      if (typeof config.collectUrl !== "string" || !/^https?:\/\//.test(config.collectUrl)) {
        unavailable = "collectUrl http(s) olmalı";
        return false;
      }
      const payload: Record<string, unknown> = { projectKey: key, collectUrl: config.collectUrl, wrapperName: SDK_NAME, wrapperVersion: SDK_VERSION };
      if (config.consent) payload.consent = cleanConsent(config.consent);
      for (const field of ["flushIntervalMs", "batchSize", "queueLimit", "sessionTimeoutMs"] as const) {
        if (typeof config[field] === "number" && Number.isFinite(config[field])) payload[field] = config[field];
      }
      if (typeof config.autoCaptureDeepLinks === "boolean") payload.autoCaptureDeepLinks = config.autoCaptureDeepLinks;
      if (typeof config.debug === "boolean") payload.debug = config.debug;
      // Eşleştirme kodu yalnız biçimi doğruysa yerel katmana gider (çekirdek de aynı kuralla süzer).
      if (typeof config.installCode === "string" && INSTALL_CODE_PATTERN.test(config.installCode.trim())) payload.installCode = config.installCode.trim();
      if (typeof config.appVersion === "string" && config.appVersion.length > 0 && config.appVersion.length <= 32) appVersion = config.appVersion;
      initialized = await guard(false, () => native.initialize(payload));
      unavailable = initialized ? null : "yerel başlatma başarısız";
      return initialized;
    },

    /** analytics=false: kuyruk ve depodaki anonim kimlik silinir. */
    setConsent(consent: Consent): void {
      const bridge = ready();
      if (bridge && consent) fire(() => bridge.setConsent(cleanConsent(consent)));
    },

    optOut(): void {
      const bridge = ready();
      if (bridge) fire(() => bridge.optOut());
    },

    /** Olay kimliği döner; izin yoksa, ad geçersizse veya SDK kapalıysa null. */
    track(name: string, properties?: Record<string, unknown>): Promise<string | null> {
      const bridge = ready();
      if (!bridge || typeof name !== "string" || name.length > 100 || !EVENT_NAME.test(name)) return Promise.resolve(null);
      return guard(null, () => bridge.track(name, cleanProperties(properties)));
    },

    /** screen_view olayı üretir. */
    screen(name: string, properties?: Record<string, unknown>): Promise<string | null> {
      const bridge = ready();
      if (!bridge || typeof name !== "string" || name.length === 0) return Promise.resolve(null);
      return guard(null, () => bridge.screen(name, cleanProperties(properties)));
    },

    /** Uygulamanın kendi kullanıcı kimliği (≤128 karakter). E-posta veya telefon vermeyin. */
    identify(userId: string): void {
      const bridge = ready();
      if (bridge && typeof userId === "string" && userId.length > 0 && userId.length <= 128) fire(() => bridge.identify(userId));
    },

    /**
     * Satın alma ya da abonelik beyanı (`feralin_purchase`). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa
     * REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez. Sözleşme dışı girdide `null` döner.
     */
    trackRevenue(input: RevenueInput): Promise<string | null> {
      const bridge = ready();
      if (!bridge) return Promise.resolve(null);
      const properties = revenueProperties(input);
      if (!properties) return Promise.resolve(null);
      return guard(null, () => bridge.track(REVENUE_EVENT_NAME, properties));
    },

    /** Bölüm başladı (`level_start`). `levelId` 1-64 karakter. Sözleşme dışı girdide `null`. */
    trackLevelStart(levelId: string, options?: Pick<LevelOptions, "attempt">): Promise<string | null> {
      return signal(LEVEL_START_EVENT, levelStartProperties(levelId, options));
    },

    /** Bölüm tamamlandı (`level_complete`). Süre milisaniyedir (0-86 400 000). */
    trackLevelComplete(levelId: string, options?: Omit<LevelOptions, "failReason">): Promise<string | null> {
      return signal(LEVEL_COMPLETE_EVENT, levelCompleteProperties(levelId, options));
    },

    /** Bölüm başarısız (`level_fail`). */
    trackLevelFail(levelId: string, options?: LevelOptions): Promise<string | null> {
      return signal(LEVEL_FAIL_EVENT, levelFailProperties(levelId, options));
    },

    /** Oyun içi para birimi kazanıldı (`economy_source`). Sanal para birimidir; gerçek gelir değildir. Miktar 1..10^12. */
    trackEconomySource(currencyName: string, amount: number, options?: EconomyOptions): Promise<string | null> {
      return signal(ECONOMY_SOURCE_EVENT, economyProperties(currencyName, amount, options));
    },

    /** Oyun içi para birimi harcandı (`economy_sink`). */
    trackEconomySink(currencyName: string, amount: number, options?: EconomyOptions): Promise<string | null> {
      return signal(ECONOMY_SINK_EVENT, economyProperties(currencyName, amount, options));
    },

    /** Ödüllü reklam gösterildi (`rewarded_ad_shown`). Gelir taşımaz; reklam geliri `trackAdRevenue` ile bildirilir. */
    trackRewardedAdShown(placement: string, options?: { network?: string }): Promise<string | null> {
      return signal(REWARDED_SHOWN_EVENT, rewardedShownProperties(placement, options));
    },

    /** Ödüllü reklam tamamlandı (`rewarded_ad_complete`). */
    trackRewardedAdComplete(placement: string, options?: { network?: string; rewardAmount?: number; rewardCurrency?: string }): Promise<string | null> {
      return signal(REWARDED_COMPLETE_EVENT, rewardedCompleteProperties(placement, options));
    },

    /** Uygulama içi satın alma teklifi gösterildi (`iap_offer_shown`). Gelir değildir; gelir `trackRevenue` ile bildirilir. */
    trackIapOfferShown(productId: string, options?: { placement?: string }): Promise<string | null> {
      return signal(IAP_OFFER_SHOWN_EVENT, iapOfferShownProperties(productId, options));
    },

    /** Satın alma başlatıldı (`iap_initiated`). `transactionId` sonradan `trackRevenue` ile bildirilenle aynıysa panel bağlar. */
    trackIapInitiated(productId: string, options?: { placement?: string; transactionId?: string }): Promise<string | null> {
      return signal(IAP_INITIATED_EVENT, iapInitiatedProperties(productId, options));
    },

    /**
     * Reklam gösterimi geliri (`fr_ad_revenue`). Satın alma gelirinden (`trackRevenue`) ve reklam harcamasından ayrı bir gelir sınıfıdır;
     * istemci beyanıdır ve sunucuda ESTIMATED kalır, reklam ağı mutabakatı BLOCKED_EXTERNAL. Tutar `revenueMicros` (milyonda bir, tam sayı).
     * Sözleşme dışı girdide `null`.
     */
    trackAdRevenue(input: AdRevenueInput): Promise<string | null> {
      return signal(AD_REVENUE_EVENT_NAME, adRevenueProperties(input, cleanProperties));
    },

    /**
     * Yakalanan (try/catch) bir hatayı `fr_error` olarak bildirir. Yığın izi gitmez: hata sınıfı adı, temizlenmiş mesaj ve normalize
     * çerçeve özeti olan parmak izi gider. Süreç başına en çok 20 olay, aynı parmak izi için en çok 3. Sınır dolduysa ya da izin yoksa `null`.
     */
    captureError(error: unknown): Promise<string | null> {
      return report(error, ERROR_ORIGIN_HANDLED, false);
    },

    /**
     * Yakalanmamış JS hatalarını (`ErrorUtils` genel işleyicisi) ve işlenmemiş Promise reddini `fr_error` olarak bildirir. Mevcut işleyici
     * korunur ve çağrılmaya devam eder; hata davranışı değişmez. Ölümcül hatada olay, uygulama kapanmadan kuyruğa yetişmeyebilir.
     * Yerel çökme ve ANR yakalanmaz; sembolleştirme yoktur. İkinci çağrı yok sayılır. `hooks` yalnız testler içindir.
     */
    captureUncaughtErrors(options?: UncaughtErrorOptions, hooks?: ErrorHooks): boolean {
      if (uncaughtInstalled) return false;
      const env = hooks ?? {};
      const utils = env.errorUtils;
      if (!utils || typeof utils.setGlobalHandler !== "function") return false;
      uncaughtInstalled = true;
      const rate = typeof options?.sampleRate === "number" && Number.isFinite(options.sampleRate) ? Math.min(1, Math.max(0, options.sampleRate)) : 1;
      limiter = new ErrorLimiter(rate);
      const previous = utils.getGlobalHandler();
      utils.setGlobalHandler((error: unknown, isFatal?: boolean) => {
        void report(error, ERROR_ORIGIN_UNCAUGHT, isFatal === true);
        if (previous) previous(error, isFatal);
      });
      const wantRejections = options?.promiseRejections ?? env.dev !== true;
      if (wantRejections && env.trackRejections) {
        try {
          env.trackRejections((reason) => {
            void report(reason, ERROR_ORIGIN_REJECTION, false);
          });
        } catch {
          // İzleyici açılamazsa genel işleyici yine çalışır.
        }
      }
      return true;
    },

    /**
     * Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve isteğe bağlı özellikler. Grup kimliği
     * ≤128 karakter ve PII olmamalıdır. Sunucuda ayrı grup profili tutulmaz; olay olarak saklanır.
     */
    group(groupId: string, traits?: Record<string, unknown>): Promise<string | null> {
      const bridge = ready();
      if (!bridge || typeof groupId !== "string" || groupId.length === 0 || groupId.length > MAX_ID_LENGTH) return Promise.resolve(null);
      const properties = { ...(cleanProperties(traits) ?? {}), group_id: groupId };
      return guard(null, () => bridge.track(GROUP_EVENT_NAME, properties));
    },

    /**
     * Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Geçerli özellik yoksa olay üretilmez. E-posta, telefon gibi PII
     * vermeyin. Sunucuda ayrı profil deposu yoktur; olay olarak saklanır.
     */
    setUserProperties(properties: Record<string, unknown>): Promise<string | null> {
      const bridge = ready();
      if (!bridge) return Promise.resolve(null);
      const clean = cleanProperties(properties);
      if (!clean) return Promise.resolve(null);
      return guard(null, () => bridge.track(USER_PROPERTIES_EVENT_NAME, clean));
    },

    /**
     * AdServices token'ını gönderir ve kurulum kimliğini döndürür (ADR-0007). Yalnız iOS yerel modülü bunu sağlar; Android'de Play
     * Install Referrer yolu kullanılır, modül yokken `unsupported` döner. Müşteri `installId`'yi kendi sunucusuna iletip
     * `account-links` ucunu gizli anahtarla çağırır.
     */
    async bindInstall(): Promise<InstallBinding> {
      if (!native?.bindInstall) return { status: "unsupported", installId: null };
      const bridge = ready();
      if (!bridge?.bindInstall) return { status: "not_initialized", installId: null };
      const raw = await guard<Record<string, unknown> | null>(null, () => bridge.bindInstall!());
      if (!raw || typeof raw.status !== "string") return { status: "not_initialized", installId: null };
      return { status: raw.status as InstallBinding["status"], installId: typeof raw.installId === "string" ? raw.installId : null };
    },

    /** Çıkış: oturum ve anonim kimlik yenilenir, kuyruk silinir. */
    reset(): void {
      const bridge = ready();
      if (bridge) fire(() => bridge.reset());
    },

    async flush(): Promise<FlushResult> {
      const bridge = ready();
      if (!bridge) return { ...NO_FLUSH };
      const raw = await guard<Record<string, unknown>>({}, () => bridge.flush());
      return {
        sent: typeof raw.sent === "number" ? raw.sent : 0,
        accepted: typeof raw.accepted === "number" ? raw.accepted : 0,
        rejected: typeof raw.rejected === "number" ? raw.rejected : 0,
        status: typeof raw.status === "number" ? raw.status : 0,
        batchId: typeof raw.batchId === "string" ? raw.batchId : null,
      };
    },

    async consumeDeferredDeepLink(): Promise<DeferredDeepLink> {
      // Yerel modül yalnız Android'de vardır; köprü yoksa iOS ya da bağlanmamış pakettir, ikisinde de teslim yoktur.
      if (!native?.consumeDeferredDeepLink) return { status: "not_supported", path: null };
      const bridge = ready();
      if (!bridge?.consumeDeferredDeepLink) return { status: "not_initialized", path: null };
      const raw = await guard<Record<string, unknown> | null>(null, () => bridge.consumeDeferredDeepLink!());
      if (!raw || typeof raw.status !== "string") return { status: "not_initialized", path: null };
      return { status: raw.status as DeferredDeepLink["status"], path: typeof raw.path === "string" ? raw.path : null };
    },

    async getStatus(): Promise<FeralinStatus> {
      const bridge = ready();
      if (!bridge) return offline();
      const raw = await guard<Record<string, unknown> | null>(null, () => bridge.getStatus());
      if (!raw) return offline();
      return {
        initialized: raw.initialized === true,
        unavailable: null,
        sdk: typeof raw.sdk === "string" ? raw.sdk : SDK_NAME,
        version: typeof raw.version === "string" ? raw.version : SDK_VERSION,
        queued: typeof raw.queued === "number" ? raw.queued : 0,
        consent: raw.consent && typeof raw.consent === "object" ? (raw.consent as Consent) : null,
        anonymousId: typeof raw.anonymousId === "string" ? raw.anonymousId : null,
        sessionId: typeof raw.sessionId === "string" ? raw.sessionId : null,
        userId: typeof raw.userId === "string" ? raw.userId : null,
      };
    },
  };
}

export type FeralinApi = ReturnType<typeof createFeralin>;
