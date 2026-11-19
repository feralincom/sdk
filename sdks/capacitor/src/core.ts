// JS yüzü: doğrulama burada, davranış yerel çekirdeklerde (Android: sdks/android, iOS: sdks/swift) ya da web yedeğinde (@feralin/web).
// Hiçbir yöntem uygulamaya hata fırlatmaz ve reddedilen Promise döndürmez; yerel katman yoksa ya da hata verirse güvenli varsayılan döner.
// Kurallar Cordova eklentisiyle (sdks/cordova/www/feralin.js) aynıdır.
import type {
  Consent,
  DeferredDeepLink,
  FeralinApi,
  FeralinConfig,
  FeralinStatus,
  FirstOpenOptions,
  FirstOpenResult,
  FlushResult,
  LinkOpen,
  NativeConfig,
  NativeFeralin,
  RevenueInput,
} from "./definitions.js";

export const SDK_NAME = "@feralin/capacitor";
export const SDK_VERSION = "0.1.0";

// Biçimler toplayıcı şeması (packages/schemas/utp/v1/event.schema.json) ve öteki SDK'larla aynıdır.
const EVENT_NAME_PATTERN = /^[a-z][a-z0-9_]*$/;
const PROPERTY_KEY_PATTERN = /^[a-zA-Z][a-zA-Z0-9_]{0,63}$/;
const MAX_PROPERTIES = 100;
const INSTALL_CODE_PATTERN = /^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$/;
const SIGNING_KEY_ID_PATTERN = /^sgn_[a-z0-9]{12,40}$/;
const META_APP_ID_PATTERN = /^[0-9]{5,20}$/;
const CURRENCY_PATTERN = /^[A-Z]{3}$/;
const HTTP_URL_PATTERN = /^https?:\/\/[^\s]+$/;
// Kaldırma ölçümü bildiriminin anahtarı (Android FeralinEngine.UNINSTALL_CHECK_KEY, Swift isUninstallCheck ile aynı).
const UNINSTALL_CHECK_KEY = "fr_uninstall_check";
const PURCHASE_TYPES: readonly string[] = ["purchase", "subscription_start", "subscription_renew", "subscription_cancel"];
const RECEIPT_PROVIDERS: readonly string[] = ["apple", "google", "stripe"];
// İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, toplayıcı da düşürür.
const REVENUE_RESERVED_KEYS = ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"];
const DEFERRED_STATUSES: readonly string[] = ["delivered", "none", "consent_required", "not_initialized", "pending", "not_configured", "not_supported", "failed"];
const FIRST_OPEN_STATUSES: readonly string[] = ["sent", "automatic", "already_sent", "skipped", "not_initialized", "not_supported"];

type Json = null | string | number | boolean | Json[] | { [key: string]: Json };

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPositiveInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value > 0;
}

function validEventName(name: unknown): string | null {
  return typeof name === "string" && name.length >= 1 && name.length <= 100 && EVENT_NAME_PATTERN.test(name) ? name : null;
}

/** Değer JSON'a birebir dönüşüyorsa kopyasını, dönüşmüyorsa undefined döner (işlev, sonsuz sayı, aşırı derinlik). */
function jsonValue(value: unknown, depth: number): Json | undefined {
  if (value === null) return null;
  if (typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  if (depth > 8) return undefined;
  if (Array.isArray(value)) {
    const list: Json[] = [];
    for (const item of value) {
      const converted = jsonValue(item, depth + 1);
      if (converted !== undefined) list.push(converted);
    }
    return list;
  }
  if (isObject(value)) {
    const out: { [key: string]: Json } = {};
    for (const key of Object.keys(value)) {
      const converted = jsonValue(value[key], depth + 1);
      if (converted !== undefined) out[key] = converted;
    }
    return out;
  }
  return undefined;
}

/** Özellik anahtarlarını şema desenine göre süzer; en çok 100 özellik. Geçerli özellik yoksa null. */
export function sanitizeProperties(properties: unknown): Record<string, Json> | null {
  if (!isObject(properties)) return null;
  const out: Record<string, Json> = {};
  let count = 0;
  for (const key of Object.keys(properties)) {
    if (count >= MAX_PROPERTIES) break;
    if (!PROPERTY_KEY_PATTERN.test(key)) continue;
    const value = jsonValue(properties[key], 0);
    if (value === undefined) continue;
    out[key] = value;
    count++;
  }
  return count > 0 ? out : null;
}

/** `analytics` zorunlu; öteki alanlar verilmediyse gönderilmez (varsayılan olarak verilmiş sayılmaz). */
export function normalizeConsent(consent: unknown): Consent | null {
  if (!isObject(consent) || typeof consent.analytics !== "boolean") return null;
  const out: Consent = { analytics: consent.analytics };
  if (typeof consent.advertising === "boolean") out.advertising = consent.advertising;
  if (typeof consent.personalization === "boolean") out.personalization = consent.personalization;
  if (typeof consent.session_replay === "boolean") out.session_replay = consent.session_replay;
  return out;
}

/** Yalnız public anahtar (pk_) geçer; gizli anahtar ya da bozuk imza anahtarı yapılandırma hatasıdır ve null döner. */
export function normalizeConfig(config: unknown): NativeConfig | null {
  if (!isObject(config)) return null;
  const projectKey = typeof config.projectKey === "string" ? config.projectKey.trim() : "";
  if (/^sk_/i.test(projectKey) || !projectKey.startsWith("pk_") || projectKey.length < 8) return null;
  const collectUrl = typeof config.collectUrl === "string" ? config.collectUrl.trim() : "";
  if (!HTTP_URL_PATTERN.test(collectUrl)) return null;
  const out: NativeConfig = { projectKey, collectUrl, sdkName: SDK_NAME, sdkVersion: SDK_VERSION };
  const consent = normalizeConsent(config.consent);
  if (consent) out.consent = consent;
  for (const key of ["flushIntervalMs", "batchSize", "queueLimit", "sessionTimeoutMs"] as const) {
    const value = config[key];
    if (isPositiveInteger(value)) out[key] = value;
  }
  for (const key of ["autoCaptureDeepLinks", "debug", "childDirected", "collectAdvertisingId"] as const) {
    const value = config[key];
    if (typeof value === "boolean") out[key] = value;
  }
  if (typeof config.installCode === "string" && INSTALL_CODE_PATTERN.test(config.installCode.trim())) out.installCode = config.installCode.trim();
  if (typeof config.metaAppId === "string" && META_APP_ID_PATTERN.test(config.metaAppId.trim())) out.metaAppId = config.metaAppId.trim();
  if (isPositiveInteger(config.consentMaxAgeDays) && config.consentMaxAgeDays <= 3650) out.consentMaxAgeDays = config.consentMaxAgeDays;
  if (config.signingKey !== undefined) {
    const key = config.signingKey;
    if (!isObject(key) || typeof key.id !== "string" || !SIGNING_KEY_ID_PATTERN.test(key.id) || typeof key.secret !== "string" ||
        key.secret.length < 16 || key.secret.length > 200) {
      return null;
    }
    out.signingKey = { id: key.id, secret: key.secret };
  }
  if (Array.isArray(config.shortLinkHosts)) {
    out.shortLinkHosts = config.shortLinkHosts.filter((host): host is string => typeof host === "string" && /^[a-z0-9.-]{1,253}$/i.test(host));
  }
  const attribution = config.attribution;
  if (isObject(attribution) && typeof attribution.apiUrl === "string" && typeof attribution.projectId === "string" &&
      HTTP_URL_PATTERN.test(attribution.apiUrl) && attribution.projectId.length > 0) {
    out.attribution = { apiUrl: attribution.apiUrl, projectId: attribution.projectId };
  }
  return out;
}

/**
 * Gelir olayının özelliklerini sözleşmeye göre kurar (`feralin_purchase`; Web, Android ve Swift ile aynı kurallar); geçersiz girdide
 * null döner ve olay üretilmez. iOS çekirdeğinde ayrı gelir yöntemi olmadığı için iOS köprüsü bu özelliklerle olay üretir.
 */
export function buildRevenueProperties(input: unknown): Record<string, Json> | null {
  if (!isObject(input) || typeof input.transactionId !== "string" || input.transactionId.length < 1 || input.transactionId.length > 128) return null;
  if (typeof input.amountMinor !== "number" || !Number.isSafeInteger(input.amountMinor) || input.amountMinor < 0) return null;
  if (typeof input.currency !== "string" || !CURRENCY_PATTERN.test(input.currency)) return null;
  if (input.productId !== undefined && (typeof input.productId !== "string" || input.productId.length < 1 || input.productId.length > 128)) return null;
  const quantity = input.quantity === undefined ? 1 : input.quantity;
  if (typeof quantity !== "number" || !Number.isInteger(quantity) || quantity < 0 || quantity > 100_000) return null;
  const purchaseType = input.purchaseType === undefined ? "purchase" : input.purchaseType;
  if (typeof purchaseType !== "string" || !PURCHASE_TYPES.includes(purchaseType)) return null;
  // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
  if (purchaseType === "subscription_cancel" && input.amountMinor !== 0) return null;
  const receipt = input.receipt;
  if (receipt !== undefined && (!isObject(receipt) || typeof receipt.provider !== "string" || !RECEIPT_PROVIDERS.includes(receipt.provider) ||
      typeof receipt.token !== "string" || receipt.token.length < 1 || receipt.token.length > 8192)) {
    return null;
  }
  const props: Record<string, Json> = sanitizeProperties(input.properties) ?? {};
  for (const key of REVENUE_RESERVED_KEYS) delete props[key];
  props.transaction_id = input.transactionId;
  props.amount_minor = input.amountMinor;
  props.currency = input.currency;
  props.quantity = quantity;
  props.purchase_type = purchaseType;
  if (typeof input.productId === "string") props.product_id = input.productId;
  if (isObject(receipt)) props.receipt = { provider: receipt.provider as string, token: receipt.token as string };
  return props;
}

/** Gelen bildirim Feralin'in kaldırma ölçümü bildirimi mi? `true` ise uygulama bildirimi göstermemelidir. */
export function isUninstallCheck(data: unknown): boolean {
  return isObject(data) && data[UNINSTALL_CHECK_KEY] === "1";
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

/** Yerel katman yanıt vermezse uygulamanın gideceği yol: adresin kendi yolu ve sorgusu. */
function fallbackPath(url: unknown): string {
  const match = typeof url === "string" ? /^[a-z][a-z0-9+.-]*:\/\/[^/?#]*([^#]*)/i.exec(url) : null;
  const path = match?.[1] ? match[1] : "/";
  return path.startsWith("/") ? path : `/${path}`;
}

function toFlushResult(value: unknown): FlushResult {
  if (!isObject(value)) return { sent: 0, accepted: 0, rejected: 0, status: 0, batchId: null };
  return {
    sent: numberOr(value.sent, 0),
    accepted: numberOr(value.accepted, 0),
    rejected: numberOr(value.rejected, 0),
    status: numberOr(value.status, 0),
    batchId: stringOrNull(value.batchId),
  };
}

function toDeferredDeepLink(value: unknown): DeferredDeepLink {
  if (!isObject(value) || typeof value.status !== "string" || !DEFERRED_STATUSES.includes(value.status)) {
    return { status: "failed", path: null, linkCode: null };
  }
  return { status: value.status as DeferredDeepLink["status"], path: stringOrNull(value.path), linkCode: stringOrNull(value.linkCode) };
}

function toLinkOpen(value: unknown, url: unknown): LinkOpen {
  if (!isObject(value) || typeof value.destination !== "string") return { destination: fallbackPath(url), linkCode: null, hasClickId: false };
  return { destination: value.destination, linkCode: stringOrNull(value.linkCode), hasClickId: value.hasClickId === true };
}

function toFirstOpen(value: unknown): FirstOpenResult {
  if (!isObject(value) || typeof value.status !== "string" || !FIRST_OPEN_STATUSES.includes(value.status)) return { status: "skipped", eventId: null };
  return { status: value.status as FirstOpenResult["status"], eventId: stringOrNull(value.eventId) };
}

function toStatus(value: unknown): FeralinStatus {
  if (!isObject(value)) {
    return { initialized: false, sdk: SDK_NAME, version: SDK_VERSION, queued: 0, consent: null, anonymousId: null, sessionId: null, userId: null };
  }
  return {
    initialized: value.initialized === true,
    sdk: stringOrNull(value.sdk) ?? SDK_NAME,
    version: stringOrNull(value.version) ?? SDK_VERSION,
    queued: numberOr(value.queued, 0),
    consent: normalizeConsent(value.consent),
    anonymousId: stringOrNull(value.anonymousId),
    sessionId: stringOrNull(value.sessionId),
    userId: stringOrNull(value.userId),
  };
}

function field(value: unknown, key: string): unknown {
  return isObject(value) ? value[key] : undefined;
}

/** Uygulama yüzünü kurar. `native` Capacitor'ın `registerPlugin` vekilidir; testler sahte nesne verir. */
export function createFeralin(native: NativeFeralin | null | undefined): FeralinApi {
  async function call<T>(invoke: (plugin: NativeFeralin) => Promise<unknown>, map: (value: unknown) => T): Promise<T> {
    if (!native) return map(undefined);
    try {
      return map(await invoke(native));
    } catch {
      return map(undefined);
    }
  }

  const ok = (value: unknown) => field(value, "ok") === true;
  const eventId = (value: unknown) => stringOrNull(field(value, "eventId"));
  const linkFor = (url: string) => (value: unknown) => toLinkOpen(value, url);

  return {
    SDK_NAME,
    SDK_VERSION,

    initialize(config: FeralinConfig) {
      const normalized = normalizeConfig(config);
      if (!normalized) return Promise.resolve(false);
      return call((p) => p.initialize({ config: normalized }), (value) => field(value, "ready") === true);
    },

    setConsent(consent: Consent) {
      const normalized = normalizeConsent(consent);
      if (!normalized) return Promise.resolve(false);
      return call((p) => p.setConsent({ consent: normalized }), ok);
    },

    optOut() {
      return call((p) => p.setConsent({ consent: { analytics: false } }), ok);
    },

    track(name: string, properties?: Record<string, unknown>) {
      const valid = validEventName(name);
      if (!valid) return Promise.resolve(null);
      return call((p) => p.track({ name: valid, properties: sanitizeProperties(properties) }), eventId);
    },

    screen(name: string, properties?: Record<string, unknown>) {
      if (typeof name !== "string" || name.length < 1 || name.length > 256) return Promise.resolve(null);
      return call((p) => p.screen({ name, properties: sanitizeProperties(properties) }), eventId);
    },

    identify(userId: string) {
      if (typeof userId !== "string" || userId.length < 1 || userId.length > 128) return Promise.resolve(false);
      return call((p) => p.identify({ userId }), ok);
    },

    reset() {
      return call((p) => p.reset(), ok);
    },

    group(groupId: string, traits?: Record<string, unknown>) {
      if (typeof groupId !== "string" || groupId.length < 1 || groupId.length > 128) return Promise.resolve(null);
      return call((p) => p.group({ groupId, traits: sanitizeProperties(traits) }), eventId);
    },

    setUserProperties(properties: Record<string, unknown>) {
      const props = sanitizeProperties(properties);
      if (!props) return Promise.resolve(null);
      return call((p) => p.setUserProperties({ properties: props }), eventId);
    },

    setGlobalProperties(properties: Record<string, unknown>) {
      const props = sanitizeProperties(properties);
      if (!props) return Promise.resolve(0);
      return call((p) => p.setGlobalProperties({ properties: props }), (value) => numberOr(field(value, "count"), 0));
    },

    clearGlobalProperties() {
      return call((p) => p.clearGlobalProperties(), ok);
    },

    trackRevenue(input: RevenueInput) {
      const props = buildRevenueProperties(input);
      if (!props) return Promise.resolve(null);
      const wire: Record<string, unknown> = {
        transactionId: input.transactionId,
        amountMinor: input.amountMinor,
        currency: input.currency,
        quantity: props.quantity,
        purchaseType: props.purchase_type,
      };
      if (input.productId !== undefined) wire.productId = input.productId;
      if (input.receipt) wire.receipt = { provider: input.receipt.provider, token: input.receipt.token };
      const extra = sanitizeProperties(input.properties);
      if (extra) wire.properties = extra;
      return call((p) => p.trackRevenue({ input: wire, properties: props }), eventId);
    },

    flush() {
      return call((p) => p.flush(), toFlushResult);
    },

    trackFirstOpen(options?: FirstOpenOptions) {
      const args: FirstOpenOptions = {};
      if (isObject(options)) {
        if (typeof options.clickId === "string" && options.clickId.length > 0 && options.clickId.length <= 128) args.clickId = options.clickId;
        if (typeof options.source === "string" && /^[a-z][a-z0-9_]{0,63}$/.test(options.source)) args.source = options.source;
        if (typeof options.advertisingId === "string") args.advertisingId = options.advertisingId;
      }
      return call((p) => p.trackFirstOpen({ options: args }), toFirstOpen);
    },

    getInstallStore() {
      return call((p) => p.getInstallStore(), (value) => stringOrNull(field(value, "installStore")));
    },

    handleUniversalLink(url: string) {
      if (typeof url !== "string" || !/^https?:\/\//i.test(url)) return Promise.resolve(toLinkOpen(undefined, url));
      return call((p) => p.handleUniversalLink({ url }), linkFor(url));
    },

    handleShortLink(url: string) {
      if (typeof url !== "string" || !/^https?:\/\//i.test(url)) return Promise.resolve(toLinkOpen(undefined, url));
      return call((p) => p.handleShortLink({ url }), linkFor(url));
    },

    async consumeDeferredDeepLink(callback?: (link: DeferredDeepLink) => void) {
      const link = await call((p) => p.consumeDeferredDeepLink(), toDeferredDeepLink);
      if (typeof callback === "function") {
        try {
          callback(link);
        } catch {
          // Uygulama geri çağrısının hatası SDK sonucunu bozmaz.
        }
      }
      return link;
    },

    setPushToken(token: string) {
      if (typeof token !== "string" || token.length < 20 || token.length > 4096) return Promise.resolve(null);
      return call((p) => p.setPushToken({ token }), eventId);
    },

    isUninstallCheck,

    installIdentifier() {
      return call((p) => p.installIdentifier(), (value) => stringOrNull(field(value, "installId")));
    },

    getStatus() {
      return call((p) => p.getStatus(), toStatus);
    },
  };
}
