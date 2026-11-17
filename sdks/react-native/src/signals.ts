// Hata (`fr_error`), oyun ve reklam geliri (`fr_ad_revenue`) olay sözleşmeleri (X4). Kurallar Android (`ErrorEvent.kt`,
// `GameAndAdEvents.kt`), Flutter (`error_event.dart`, `signal_events.dart`) ve Web (`packages/sdk-web/src/errors.ts`) SDK'larıyla
// birebir aynıdır; kaynak `packages/schemas/utp/v1/event.schema.json` ve `game-events.md`. Sözleşme dışı girdide `null` döner ve olay üretilmez.
// Doğrulama JS'te yapılır, davranış (kuyruk, izin, gönderim) Android çekirdeğindedir.

/** Hata olayı adı. */
export const ERROR_EVENT_NAME = "fr_error";
/** Reklam geliri olayı adı; satın alma gelirinden (`feralin_purchase`) ve reklam harcamasından ayrı bir gelir sınıfıdır. */
export const AD_REVENUE_EVENT_NAME = "fr_ad_revenue";

export const LEVEL_START_EVENT = "level_start";
export const LEVEL_COMPLETE_EVENT = "level_complete";
export const LEVEL_FAIL_EVENT = "level_fail";
export const ECONOMY_SOURCE_EVENT = "economy_source";
export const ECONOMY_SINK_EVENT = "economy_sink";
export const REWARDED_SHOWN_EVENT = "rewarded_ad_shown";
export const REWARDED_COMPLETE_EVENT = "rewarded_ad_complete";
export const IAP_OFFER_SHOWN_EVENT = "iap_offer_shown";
export const IAP_INITIATED_EVENT = "iap_initiated";

/** Tek olay miktarı üst sınırı (oyun içi para birimi). */
export const MAX_ECONOMY_AMOUNT = 1_000_000_000_000;
const MAX_DURATION_MS = 86_400_000;
const MAX_NUMBER = Number.MAX_SAFE_INTEGER;
/** Reklam geliri üst sınırı (JS güvenli tam sayı; sunucu bigint taşır). */
export const MAX_REVENUE_MICROS = Number.MAX_SAFE_INTEGER;

const CURRENCY = /^[A-Z]{3}$/;
const NETWORK = /^[a-z][a-z0-9_]{0,63}$/;
// İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
const RESERVED_KEYS = ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"];

export type AdFormat = "banner" | "interstitial" | "rewarded" | "rewarded_interstitial" | "native" | "app_open" | "other";
export type AdPrecision = "estimated" | "publisher_provided" | "precise" | "unknown";
const AD_FORMATS: readonly string[] = ["banner", "interstitial", "rewarded", "rewarded_interstitial", "native", "app_open", "other"];
const AD_PRECISIONS: readonly string[] = ["estimated", "publisher_provided", "precise", "unknown"];

type Props = Record<string, unknown>;

function validText(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

/** İsteğe bağlı metin: verilmediyse (undefined, null) geçer; verildiyse sınırda olmalı. */
function putText(out: Props, key: string, value: unknown, max: number): boolean {
  if (value === undefined || value === null) return true;
  if (!validText(value, max)) return false;
  out[key] = value;
  return true;
}

function putNumber(out: Props, key: string, value: unknown, min: number, max: number): boolean {
  if (value === undefined || value === null) return true;
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < min || value > max) return false;
  out[key] = value;
  return true;
}

export interface LevelOptions {
  /** 1'den başlayan deneme sayısı. */
  attempt?: number;
  /** Puan (≥ 0). */
  score?: number;
  /** Süre, milisaniye (0 - 86 400 000). */
  durationMs?: number;
  /** Başarısızlık nedeni (≤ 64); yalnız `level_fail`. */
  failReason?: string;
}

function level(levelId: unknown, options: LevelOptions | undefined, withFailReason: boolean, withResult: boolean): Props | null {
  if (!validText(levelId, 64)) return null;
  const o = options ?? {};
  const out: Props = { level_id: levelId };
  if (!putNumber(out, "attempt", o.attempt, 1, MAX_NUMBER)) return null;
  if (withResult) {
    if (!putNumber(out, "score", o.score, 0, MAX_NUMBER)) return null;
    if (!putNumber(out, "duration_ms", o.durationMs, 0, MAX_DURATION_MS)) return null;
  }
  if (withFailReason && !putText(out, "fail_reason", o.failReason, 64)) return null;
  return out;
}

/** `level_start` özellikleri. */
export function levelStartProperties(levelId: string, options?: Pick<LevelOptions, "attempt">): Props | null {
  return level(levelId, options, false, false);
}

/** `level_complete` özellikleri. */
export function levelCompleteProperties(levelId: string, options?: Omit<LevelOptions, "failReason">): Props | null {
  return level(levelId, options, false, true);
}

/** `level_fail` özellikleri. */
export function levelFailProperties(levelId: string, options?: LevelOptions): Props | null {
  return level(levelId, options, true, true);
}

export interface EconomyOptions {
  /** Neden (≤ 64): `quest`, `shop`. */
  reason?: string;
  /** Eşya kimliği (≤ 64). */
  itemId?: string;
}

/** `economy_source` ve `economy_sink` özellikleri: oyun içi para birimi adı ve 1..10^12 miktar (sanal para, gerçek gelir değil). */
export function economyProperties(currencyName: string, amount: number, options?: EconomyOptions): Props | null {
  if (!validText(currencyName, 64) || typeof amount !== "number" || !Number.isSafeInteger(amount) || amount < 1 || amount > MAX_ECONOMY_AMOUNT) return null;
  const out: Props = { currency_name: currencyName, amount };
  if (!putText(out, "reason", options?.reason, 64)) return null;
  if (!putText(out, "item_id", options?.itemId, 64)) return null;
  return out;
}

/** `rewarded_ad_shown` özellikleri. */
export function rewardedShownProperties(placement: string, options?: { network?: string }): Props | null {
  if (!validText(placement, 64)) return null;
  const out: Props = { placement };
  if (!putText(out, "network", options?.network, 64)) return null;
  return out;
}

/** `rewarded_ad_complete` özellikleri. */
export function rewardedCompleteProperties(
  placement: string,
  options?: { network?: string; rewardAmount?: number; rewardCurrency?: string },
): Props | null {
  const out = rewardedShownProperties(placement, options);
  if (!out) return null;
  if (!putNumber(out, "reward_amount", options?.rewardAmount, 0, MAX_NUMBER)) return null;
  if (!putText(out, "reward_currency", options?.rewardCurrency, 64)) return null;
  return out;
}

/** `iap_offer_shown` özellikleri. */
export function iapOfferShownProperties(productId: string, options?: { placement?: string }): Props | null {
  if (!validText(productId, 128)) return null;
  const out: Props = { product_id: productId };
  if (!putText(out, "placement", options?.placement, 64)) return null;
  return out;
}

/** `iap_initiated` özellikleri. */
export function iapInitiatedProperties(productId: string, options?: { placement?: string; transactionId?: string }): Props | null {
  const out = iapOfferShownProperties(productId, options);
  if (!out) return null;
  if (!putText(out, "transaction_id", options?.transactionId, 128)) return null;
  return out;
}

/**
 * `trackAdRevenue` girdisi (X4): tek reklam gösteriminin geliri (ör. AdMob `onPaidEvent`, AppLovin MAX `onAdRevenuePaid`). Satın alma
 * gelirinden (`trackRevenue`) ve reklam harcamasından ayrı bir gelir sınıfıdır; istemci beyanıdır ve sunucuda ESTIMATED kalır.
 */
export interface AdRevenueInput {
  /** Reklam ağı, küçük harf ve alt çizgi: `admob`, `applovin_max`, `ironsource`, `unity_ads`. */
  network: string;
  adFormat: AdFormat;
  /** Tek gösterim geliri, para biriminin milyonda biri: 0,0125 USD için 12500. Tam sayı, ondalık yok. */
  revenueMicros: number;
  /** ISO 4217, üç büyük harf. */
  currency: string;
  /** Reklam birimi kimliği (≤ 128). */
  adUnit?: string;
  /** Ağın bildirdiği kesinlik; verilmezse `unknown`. */
  precision?: AdPrecision;
  /** Yerleşim adı (≤ 64). */
  placement?: string;
  /** Ağın gösterim kimliği (≤ 128); verilirse aynı gösterim ikinci kez sayılmaz. */
  impressionId?: string;
  /** Ek özellikler; `verified` ve türevleri düşürülür. */
  properties?: Record<string, unknown>;
}

/** Reklam geliri olayının özelliklerini kurar; sözleşme dışı girdide `null`. Tutar para biriminin milyonda biri, tam sayı. */
export function adRevenueProperties(input: AdRevenueInput, clean: (properties: Props | undefined) => Props | null): Props | null {
  if (!input || typeof input !== "object") return null;
  const { network, adFormat, revenueMicros, currency, adUnit, placement, impressionId } = input;
  const precision = input.precision ?? "unknown";
  if (typeof network !== "string" || !NETWORK.test(network)) return null;
  if (!AD_FORMATS.includes(adFormat)) return null;
  if (!AD_PRECISIONS.includes(precision)) return null;
  if (typeof revenueMicros !== "number" || !Number.isSafeInteger(revenueMicros) || revenueMicros < 0 || revenueMicros > MAX_REVENUE_MICROS) return null;
  if (typeof currency !== "string" || !CURRENCY.test(currency)) return null;
  if (adUnit !== undefined && !validText(adUnit, 128)) return null;
  if (placement !== undefined && !validText(placement, 64)) return null;
  if (impressionId !== undefined && !validText(impressionId, 128)) return null;
  const out: Props = { ...(clean(input.properties) ?? {}) };
  for (const key of RESERVED_KEYS) delete out[key];
  out.network = network;
  out.ad_format = adFormat;
  out.revenue_micros = revenueMicros;
  out.currency = currency;
  out.precision = precision;
  if (adUnit !== undefined) out.ad_unit = adUnit;
  if (placement !== undefined) out.placement = placement;
  if (impressionId !== undefined) out.impression_id = impressionId;
  return out;
}

// ---------------------------------------------------------------- hata (`fr_error`)

export type ErrorOrigin = "uncaught_exception" | "unhandledrejection" | "handled" | "manual";
export const ERROR_ORIGIN_HANDLED: ErrorOrigin = "handled";
export const ERROR_ORIGIN_UNCAUGHT: ErrorOrigin = "uncaught_exception";
export const ERROR_ORIGIN_REJECTION: ErrorOrigin = "unhandledrejection";

/** Mesaj üst sınırı. */
export const ERROR_MAX_MESSAGE = 200;
const MAX_TYPE = 64;
const MAX_FRAME = 160;
const FINGERPRINT_FRAMES = 5;
const MAX_STACK_LINES = 50;

/** FNV-1a 64 bit (Web ve Flutter SDK'larıyla aynı özet): 16 küçük harf onaltılı. BigInt yok: yüksek ve alçak 32 bit ayrı tutulur (lib ES2019). */
export function fnv1a64(text: string): string {
  const TWO32 = 4_294_967_296;
  let hi = 0xcbf29ce4;
  let lo = 0x84222325;
  for (let i = 0; i < text.length; i++) {
    lo = (lo ^ text.charCodeAt(i)) >>> 0;
    // (hi, lo) × 0x100000001b3 mod 2^64: 0x1b3 çarpımı ve 2^40 kayması ayrı hesaplanır.
    const loProduct = lo * 0x1b3;
    const carry = Math.floor(loProduct / TWO32);
    const newLo = loProduct - carry * TWO32;
    const hiProduct = hi * 0x1b3 + carry;
    const newHi = (hiProduct - Math.floor(hiProduct / TWO32) * TWO32 + ((lo << 8) >>> 0)) % TWO32;
    hi = newHi;
    lo = newLo;
  }
  return hi.toString(16).padStart(8, "0") + lo.toString(16).padStart(8, "0");
}

/** Mesajdan e-posta, URL, UUID, uzun sayı ve belirteçleri çıkarır; 200 karaktere kırpar (toplayıcı aynı temizliği sunucuda tekrarlar). */
export function scrubErrorMessage(message: string): string {
  return message
    .replace(/\b[a-z][a-z0-9+.-]*:\/\/[^\s"'<>]+/gi, "[url]")
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "[email]")
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "[id]")
    .replace(/\b[A-Za-z0-9_\-+/=]{24,}\b/g, (m) => (/\d/.test(m) ? "[token]" : m))
    .replace(/\+?\d[\d\s\-().]{5,}\d/g, (m) => (m.replace(/\D/g, "").length >= 7 ? "[num]" : m))
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, ERROR_MAX_MESSAGE);
}

/** Dosya yolunu kararlı kısa ada indirir: sorgu, parça ve derleme özeti çıkar, dizin gitmez. Hermes `address at` önekini atar. */
function normalizeFile(location: string): string {
  const cleaned = (location.split("#")[0] ?? "").split("?")[0] ?? "";
  const base = (cleaned.split(/[\\/]/).filter(Boolean).pop() ?? "").replace(/^address at /, "");
  return base.replace(/[.-][0-9a-f]{6,}(?=\.|$)/gi, "").slice(0, 80) || "unknown";
}

/**
 * Yığın izini normalize çerçevelere çevirir (`işlev@dosya`). Hermes ve V8 (`at fn (dosya:1:2)`) ile JavaScriptCore (`fn@dosya:1:2`) biçimleri
 * okunur. Satır, sütun ve dizin atılır; yerel (`native`) çerçeveler yok sayılır. Sembolleştirme yoktur: üretilmiş paketin (bundle) adları
 * olduğu gibi gider.
 */
export function normalizeFrames(stack: unknown): string[] {
  if (typeof stack !== "string" || stack === "") return [];
  const frames: string[] = [];
  for (const raw of stack.split("\n").slice(0, MAX_STACK_LINES)) {
    const line = raw.trim();
    let fn: string;
    let loc: string;
    const v8 = /^at\s+(?:(.*?)\s+\()?(.*?)(?::\d+)?(?::\d+)?\)?$/.exec(line);
    if (line.startsWith("at ") && v8) {
      fn = v8[1] ?? "";
      loc = v8[2] ?? "";
    } else if (line.includes("@")) {
      const at = line.lastIndexOf("@");
      fn = line.slice(0, at);
      loc = line.slice(at + 1).replace(/(?::\d+){1,2}$/, "");
    } else continue;
    if (loc === "native") continue;
    fn = fn.replace(/^(?:async|new)\s+/, "").replace(/\s*\[as [^\]]*\]$/, "").trim();
    const name = (fn || "<anonymous>").slice(0, 60);
    frames.push(`${name}@${loc ? normalizeFile(loc) : "unknown"}`);
  }
  return frames;
}

function typeNameOf(error: unknown): string {
  if (error && typeof error === "object") {
    const e = error as { name?: unknown; constructor?: { name?: unknown } };
    if (typeof e.name === "string" && e.name) return e.name.slice(0, MAX_TYPE);
    if (typeof e.constructor?.name === "string" && e.constructor.name) return e.constructor.name.slice(0, MAX_TYPE);
  }
  return "Error";
}

/** Hata gövdesi: sözleşme alanlarının tamamı. `appVersion` ≤ 32 karakterse eklenir. Ham yığın izi, satır numarası, yol ve kullanıcı verisi GİTMEZ. */
export function errorProperties(error: unknown, origin: ErrorOrigin, fatal: boolean, appVersion?: string): Props {
  let type = typeNameOf(error);
  let rawMessage = "";
  let stack: unknown;
  if (error && typeof error === "object") {
    const e = error as { message?: unknown; stack?: unknown };
    rawMessage = typeof e.message === "string" ? e.message : "";
    stack = e.stack;
  } else if (typeof error === "string") {
    rawMessage = error;
    type = "Error";
  } else if (error !== undefined && error !== null) {
    rawMessage = String(error);
  }
  const frames = normalizeFrames(stack);
  const message = scrubErrorMessage(rawMessage);
  const basis = frames.length > 0 ? frames.slice(0, FINGERPRINT_FRAMES).join("|") : message.replace(/\d+/g, "#");
  const out: Props = { error_type: type, fingerprint: fnv1a64(`${type}|${basis}`) };
  if (message) out.message = message;
  const top = frames[0];
  if (top) out.top_frame = top.slice(0, MAX_FRAME);
  out.frame_count = Math.min(frames.length, 1000);
  if (appVersion && appVersion.length <= 32) out.app_version = appVersion;
  out.handled = origin === ERROR_ORIGIN_HANDLED || origin === "manual";
  out.fatal = fatal;
  out.origin = origin;
  return out;
}

/**
 * Hata fırtınası sınırı: süreç başına en çok `maxEvents` olay, aynı parmak izi için en çok `maxPerFingerprint`. Örnekleme `sampleRate`
 * ile (0..1); rastgele kaynak test için verilebilir.
 */
export class ErrorLimiter {
  private total = 0;
  private readonly perFingerprint = new Map<string, number>();

  constructor(
    private readonly sampleRate = 1,
    private readonly maxEvents = 20,
    private readonly maxPerFingerprint = 3,
    private readonly random: () => number = Math.random,
  ) {}

  allow(fingerprint: string): boolean {
    if (this.total >= this.maxEvents) return false;
    if (this.sampleRate < 1 && this.random() >= this.sampleRate) return false;
    const seen = this.perFingerprint.get(fingerprint) ?? 0;
    if (seen >= this.maxPerFingerprint) return false;
    this.perFingerprint.set(fingerprint, seen + 1);
    this.total++;
    return true;
  }
}
