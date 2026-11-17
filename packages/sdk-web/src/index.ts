// Feralin Web SDK — UTP v1. Yalnız public proje anahtarı kullanır; tenant/project sunucuda çözülür.
// İlkeler: consent yoksa olay üretilmez, gönderilmez ve kimlik depoya yazılmaz; at-least-once gönderim + idempotent
// event_id; URL'lerin sorgu dizgisi gönderilmez; parmak izi çıkarılmaz.
import { ulid } from "./ulid";
import { EventQueue, defaultStorage } from "./queue";
import { cleanPage, cleanReferrer } from "./url";
import type { Consent, FeralinOptions, FlushResult, RejectedEvent, UtpEvent } from "./types";
import { GROUP_EVENT_NAME, USER_PROPERTIES_EVENT_NAME, acceptsGlobalProperties, mergeGlobalProperties, sanitizeProfileProperties, validGroupId } from "./profile";
import type { ProfileDrop, ProfileValue } from "./profile";

declare const __SDK_VERSION__: string;
const SDK_NAME = "@feralin/web";
const SDK_VERSION: string = typeof __SDK_VERSION__ === "string" ? __SDK_VERSION__ : "0.0.0-dev";

export type { Consent, FeralinOptions, FlushResult, UtpEvent };
export { GROUP_EVENT_NAME, USER_PROPERTIES_EVENT_NAME, isPIILikeKey, sanitizeProfileProperties } from "./profile";
export type { ProfileDrop, ProfileValue } from "./profile";

function nowIso() { return new Date().toISOString(); }

/** Bu kadar hareketsizlikten sonra gelen olay yeni oturum başlatır. */
export const SESSION_IDLE_MS = 30 * 60_000;
const SESSION_KEY = "fr_sid";
function hasWindow() { return typeof window !== "undefined" && typeof document !== "undefined"; }
function sanitizeProps(p?: Record<string, unknown>): Record<string, unknown> | undefined {
  if (!p) return undefined;
  const out: Record<string, unknown> = {};
  let n = 0;
  for (const [k, v] of Object.entries(p)) {
    if (n >= 100) break;
    if (!/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/.test(k)) continue;
    if (v === undefined || typeof v === "function") continue;
    out[k] = v; n++;
  }
  return out;
}

const MAX_PROPERTIES = 100;
const MIN_BACKOFF_MS = 1_000;

/** `trackRevenue` sözleşmesi (F5-E04-T01): olay adı `feralin_purchase`; tutar küçük birimde tam sayı (kuruş, cent), para birimi ISO 4217. */
export const REVENUE_EVENT_NAME = "feralin_purchase";
export type PurchaseType = "purchase" | "subscription_start" | "subscription_renew" | "subscription_cancel";
export type ReceiptProvider = "apple" | "google" | "stripe";
export type RevenueInput = {
  /** Mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz; sunucu aynı işlemi ikinci kez saymaz. */
  transactionId: string;
  /** Küçük birimde satır toplamı: 49,99 TL için 4999. Ondalık kabul edilmez; `quantity` ile çarpılmaz. Abonelik iptalinde 0. */
  amountMinor: number;
  /** ISO 4217, üç büyük harf. */
  currency: string;
  productId?: string;
  quantity?: number;
  purchaseType?: PurchaseType;
  /** İsteğe bağlı ham makbuz; toplayıcı yalnız sağlayıcı adını ve belirtecin özetini saklar. */
  receipt?: { provider: ReceiptProvider; token: string };
  properties?: Record<string, unknown>;
};
/** İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür. */
const REVENUE_RESERVED_KEYS = ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"];
const PURCHASE_TYPES: readonly string[] = ["purchase", "subscription_start", "subscription_renew", "subscription_cancel"];
const RECEIPT_PROVIDERS: readonly string[] = ["apple", "google", "stripe"];

/**
 * Gelir olayının özelliklerini sözleşmeye göre kurar; geçersiz girdide null döner (olay üretilmez). Tüm SDK'larda aynı kurallar:
 * transaction_id 1..128, amount_minor 0..2^53-1 tam sayı, currency ^[A-Z]{3}$, quantity 0..100000, receipt provider enum ve dolu belirteç.
 */
export function buildRevenueProperties(input: RevenueInput): Record<string, unknown> | null {
  if (!input || typeof input.transactionId !== "string" || input.transactionId.length < 1 || input.transactionId.length > 128) return null;
  if (!Number.isSafeInteger(input.amountMinor) || input.amountMinor < 0) return null;
  if (typeof input.currency !== "string" || !/^[A-Z]{3}$/.test(input.currency)) return null;
  if (input.productId !== undefined && (typeof input.productId !== "string" || input.productId.length < 1 || input.productId.length > 128)) return null;
  const quantity = input.quantity ?? 1;
  if (!Number.isInteger(quantity) || quantity < 0 || quantity > 100_000) return null;
  const purchaseType = input.purchaseType ?? "purchase";
  if (!PURCHASE_TYPES.includes(purchaseType)) return null;
  // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
  if (purchaseType === "subscription_cancel" && input.amountMinor !== 0) return null;
  if (input.receipt !== undefined && (!input.receipt || !RECEIPT_PROVIDERS.includes(input.receipt.provider) || typeof input.receipt.token !== "string" || input.receipt.token.length < 1 || input.receipt.token.length > 8192)) return null;
  const props: Record<string, unknown> = { ...(input.properties ?? {}) };
  for (const key of REVENUE_RESERVED_KEYS) delete props[key];
  props.transaction_id = input.transactionId;
  props.amount_minor = input.amountMinor;
  props.currency = input.currency;
  props.quantity = quantity;
  props.purchase_type = purchaseType;
  if (input.productId !== undefined) props.product_id = input.productId;
  if (input.receipt) props.receipt = { provider: input.receipt.provider, token: input.receipt.token };
  return props;
}
const MAX_BACKOFF_MS = 30_000;
const MAX_RETRY_AFTER_MS = 5 * 60_000;

/** utm_* değerlerini ekler; açıkça verilen özellik ezilmez ve şemanın 100 özellik sınırı aşılmaz. */
function withUtm(props: Record<string, unknown> | undefined, utm: Record<string, string>) {
  const keys = Object.keys(utm);
  if (!keys.length) return props;
  const out: Record<string, unknown> = { ...props };
  for (const k of keys) {
    if (!(k in out) && Object.keys(out).length < MAX_PROPERTIES) out[k] = utm[k];
  }
  return out;
}

/** FNV-1a 64 bit; tarayıcıda senkron çalışır (crypto.subtle asenkron olduğu için pagehide'da kullanılamaz). */
function fnv1a64(text: string): string {
  let hash = 0xcbf29ce484222325n;
  for (let i = 0; i < text.length; i++) {
    hash = BigInt.asUintN(64, (hash ^ BigInt(text.charCodeAt(i))) * 0x100000001b3n);
  }
  return hash.toString(16).padStart(16, "0");
}

/** Anahtar batch içeriğini yansıtır: sıradan bağımsız aynı event_id kümesi aynı, farklı içerik farklı anahtar üretir. */
function idempotencyKeyFor(events: UtpEvent[]): string {
  const ids = events.map((e) => e.event_id).sort();
  return `${fnv1a64(ids.join(","))}-${ids.length}`;
}

/**
 * Yalnız public proje anahtarı (pk_) geçer ve kırpılmış değer döner; kara liste yerine zorunlu önek, çünkü " sk_", "SK_" ve
 * "rk_" gibi değerler başka türlü sayfaya sızar. Bağdaştırıcılar sunucu tarafında da aynı denetimi kullanır.
 */
export function assertProjectKey(projectKey: unknown): string {
  const key = typeof projectKey === "string" ? projectKey.trim() : "";
  if (/^sk_/i.test(key)) throw new Error("feralin: gizli anahtar tarayıcıda kullanılamaz; proje public anahtarını (pk_) verin");
  if (!key.startsWith("pk_") || key.length < 8) throw new Error("feralin: projectKey pk_ ile başlamalı");
  return key;
}

/** Kurulum eşleştirme kodu özelliği ve biçimi (toplayıcı `services/collect/internal/worker/installcode.go` ile aynı). */
const INSTALL_CODE_PROPERTY = "fr_install_code";
const INSTALL_CODE_PATTERN = /^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$/;

export class Feralin {
  private opts: Required<Pick<FeralinOptions, "projectKey" | "collectUrl" | "autoTrack" | "flushIntervalMs" | "batchSize" | "debug">> & FeralinOptions;
  private queue: EventQueue;
  private consent: Consent;
  /** Kurulum eşleştirme kodu; ilk olaya eklenir ve silinir (Android/Flutter SDK ile aynı kural). */
  private pendingInstallCode: string | null;
  /** İzin henüz bildirilmediyse (CMP yanıtı bekleniyor) depodaki kuyruk silinmez, yalnız bekletilir. */
  private consentKnown: boolean;
  /** autoTrack sayfa görüntülemesi üretildi mi; izin sonradan gelirse bir kez, çiftsiz üretmek için. */
  private autoPageTracked = false;
  private anonymousId: string;
  private sessionId: string;
  /** Bu örnekte son etkinliğin anı (kuruluş ya da son olay); depolama yokken de hareketsizlik süresi uygulanır. */
  private lastActivityMs = Date.now();
  private userId?: string;
  private referrerOverride?: string;
  private timer?: ReturnType<typeof setInterval>;
  private inflight = false;
  /** Teslim edilemeyen batch: yanıt kaybolduysa aynı içerik aynı anahtarla gider, araya giren olay anahtarı değiştirmez. */
  private pinned?: UtpEvent[];
  /** Kuyruk her temizlendiğinde artar; süren istek bittiğinde silinmiş batch yeniden sabitlenmez. */
  private queueEpoch = 0;
  private failures = 0;
  /** Bu andan önce arka plan gönderimi yapılmaz; açık flush ve sayfa kapanışı beklemez. */
  private notBefore = 0;
  private fetchImpl: typeof fetch;
  private storage: ReturnType<typeof defaultStorage>;
  /** destroy sonrası örnek ağa ve depoya dokunmaz; ortak depodaki kuyruk artık yeni örneğindir. */
  private destroyed = false;
  private unbindPageEvents?: () => void;
  /** `setGlobalProperties` haritası: yalnız bellekte tutulur, depoya yazılmaz; `fr_` dışındaki her olaya eklenir. */
  private globals = new Map<string, ProfileValue>();

  constructor(options: FeralinOptions) {
    if (!options?.projectKey || !options?.collectUrl) throw new Error("feralin: projectKey ve collectUrl zorunlu");
    const projectKey = assertProjectKey(options.projectKey);
    this.opts = { autoTrack: true, flushIntervalMs: 2000, batchSize: 50, debug: false, ...options, projectKey };
    this.opts.batchSize = Math.min(500, Math.max(1, this.opts.batchSize));
    this.fetchImpl = options.fetch ?? (typeof fetch !== "undefined" ? fetch.bind(globalThis) : (() => { throw new Error("feralin: fetch yok"); }));
    this.storage = options.storage ?? defaultStorage();
    this.consent = options.consent ?? { analytics: false };
    const code = typeof options.installCode === "string" ? options.installCode.trim() : "";
    this.pendingInstallCode = INSTALL_CODE_PATTERN.test(code) ? code : null;
    this.consentKnown = options.consent !== undefined;
    this.queue = new EventQueue(this.storage, `fr_q_${this.keyPrefix()}`);
    this.anonymousId = this.readAnonymousId() ?? ulid();
    // İzin yokken kimlik yalnız bellekte kalır; depodaki kimlik burada silinmez, çünkü izin az sonra gelebilir.
    if (this.consent.analytics) this.syncAnonymousId();
    // Oturum sayfa yüklemeleri arasında sürer: çok sayfalı sitede her yükleme yeni oturum sayılmaz. İzin yokken
    // oturum yalnız bellektedir; depodaki değer okunmaz ve yazılmaz.
    this.sessionId = (this.consent.analytics ? this.readSession() : null) ?? ulid();
    if (this.consent.analytics) this.syncSession();
    if (this.opts.flushIntervalMs > 0 && typeof setInterval !== "undefined") {
      this.timer = setInterval(() => { this.backgroundFlush(); }, this.opts.flushIntervalMs);
      // Node'da süreç çıkışını engellemesin
      (this.timer as { unref?: () => void }).unref?.();
    }
    if (hasWindow()) {
      this.trackAutoPage();
      const onPageHide = () => { void this.flush(true); };
      const onVisibilityChange = () => { if (document.visibilityState === "hidden") void this.flush(true); };
      window.addEventListener("pagehide", onPageHide);
      document.addEventListener("visibilitychange", onVisibilityChange);
      this.unbindPageEvents = () => {
        window.removeEventListener("pagehide", onPageHide);
        document.removeEventListener("visibilitychange", onVisibilityChange);
      };
    }
  }

  private keyPrefix() { return this.opts.projectKey.slice(0, 12); }
  private backgroundFlush() { if (Date.now() >= this.notBefore) void this.flush(); }
  private clearQueue() {
    this.queue.clear();
    this.pinned = undefined;
    this.queueEpoch++;
  }
  /** Üstel geri çekilme 1 sn → 30 sn; yarım jitter sekmeleri ayrıştırır. Retry-After alt sınırdır. */
  private noteFailure(retryAfter: string | null) {
    this.failures++;
    const ceiling = Math.min(MAX_BACKOFF_MS, MIN_BACKOFF_MS * 2 ** Math.min(this.failures - 1, 10));
    const seconds = retryAfter === null ? Number.NaN : Number(retryAfter.trim());
    const floor = Number.isFinite(seconds) && seconds > 0 ? Math.min(MAX_RETRY_AFTER_MS, seconds * 1000) : 0;
    this.notBefore = Date.now() + Math.max(floor, Math.round(ceiling * (0.5 + Math.random() * 0.5)));
  }
  /** Yanıt geldiğinde kuyruktan düşer. Örnek bu arada yok edildiyse depoya yazılmaz: bellekteki kopya, yeni örneğin depoda sildiği olayları geri getirirdi. */
  private settle(events: UtpEvent[]) {
    if (this.destroyed) return;
    this.queue.ack(events.map((e) => e.event_id));
    this.pinned = undefined;
    this.failures = 0;
    this.notBefore = 0;
  }
  /** Eski kimliğe dönüş olmasın: izin yeniden verilse de geri çekilmeden önceki olaylarla bağ kurulamaz. */
  private renewIdentity() {
    this.anonymousId = ulid();
    this.sessionId = ulid();
    this.lastActivityMs = Date.now();
  }
  private readAnonymousId() { try { return this.storage.get("fr_aid"); } catch { return null; } }
  /** Depoyu izne eşitler: izin varsa kimlik yazılır, yoksa silinir. Depolama hatası izlemeyi durdurmaz. */
  private syncAnonymousId() {
    try {
      if (this.consent.analytics) this.storage.set("fr_aid", this.anonymousId);
      else this.storage.remove("fr_aid");
    } catch { /* kota veya engelli depolama */ }
  }
  /** Depodaki oturum: `<kimlik>.<son etkinlik ms>`. Hareketsizlik süresi dolduysa ya da biçim bozuksa yok sayılır. */
  private readSession(): string | null {
    try {
      const raw = this.storage.get(SESSION_KEY);
      const match = raw ? /^([0-9A-Z]{26})\.(\d{10,16})$/.exec(raw) : null;
      if (!match) return null;
      return Date.now() - Number(match[2]) < SESSION_IDLE_MS ? (match[1] as string) : null;
    } catch { return null; }
  }
  /** Depoyu izne eşitler: izin varsa oturum ve son etkinlik anı yazılır, yoksa silinir. */
  private syncSession() {
    try {
      if (this.consent.analytics) this.storage.set(SESSION_KEY, `${this.sessionId}.${Date.now()}`);
      else this.storage.remove(SESSION_KEY);
    } catch { /* kota veya engelli depolama */ }
  }
  /** Olaydan önce çağrılır: başka sekmede süren ya da süresi dolan oturumu depodan okur, gerekirse yenisini başlatır. */
  private touchSession() {
    this.sessionId = this.readSession() ?? (Date.now() - this.lastActivityMs < SESSION_IDLE_MS ? this.sessionId : ulid());
    this.lastActivityMs = Date.now();
    this.syncSession();
  }
  private trackAutoPage() {
    if (this.autoPageTracked || !this.opts.autoTrack || !hasWindow() || !this.consent.analytics) return;
    this.autoPageTracked = true;
    this.page();
  }
  private log(...a: unknown[]) { if (this.opts.debug) console.debug("[feralin]", ...a); }

  getStatus() {
    return { sdk: SDK_NAME, version: SDK_VERSION, queued: this.queue.size, consent: { ...this.consent }, anonymous_id: this.anonymousId, session_id: this.sessionId, user_id: this.userId ?? null };
  }

  /** analytics=false: bekleyen olaylar ve depodaki kimlik silinir, bellekteki anonim kimlik ve oturum yenilenir, yeni olay üretilmez. analytics=true: kimlik depoya yazılır, bekleyen kuyruk serbest kalır ve autoTrack açıksa o sayfanın page_view'ı bir kez üretilir. */
  setConsent(c: Consent) {
    if (this.destroyed) return;
    this.consent = { ...c };
    this.consentKnown = true;
    if (!c.analytics) {
      this.clearQueue();
      this.renewIdentity();
    }
    this.syncAnonymousId();
    // İzin yeni geldiyse başka sekmede süren oturuma katılınır; yoksa bu örneğin oturumu depoya yazılır.
    if (c.analytics) this.sessionId = this.readSession() ?? this.sessionId;
    this.syncSession();
    this.log("consent", c);
    this.trackAutoPage();
  }

  identify(userId: string) {
    if (!userId || userId.length > 128) return;
    this.userId = userId;
  }

  /**
   * Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve isteğe bağlı özellikler. Grup kimliği 1-128
   * karakter olmalı, `@` ve kontrol karakteri içermemeli; uymazsa olay üretilmez ve null döner. Özellikler `setUserProperties` kurallarıyla
   * temizlenir; toplayıcı projenin izin listesinde olmayanı saklamaz.
   */
  group(groupId: string, traits?: Record<string, unknown>): UtpEvent | null {
    if (!validGroupId(groupId)) { this.log("geçersiz group_id, olay üretilmedi"); return null; }
    const { properties, dropped } = sanitizeProfileProperties(traits);
    this.logDropped(GROUP_EVENT_NAME, dropped);
    return this.track(GROUP_EVENT_NAME, { ...properties, group_id: groupId });
  }

  /**
   * Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Değer dizge (≤256 karakter, e-posta biçiminde değil), sonlu sayı ya da
   * mantıksal olmalı; kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad vb.) ve doğrulama alanı düşer. Geçerli özellik
   * kalmazsa olay üretilmez. Sunucu yalnız projenin izin listesindeki anahtarları saklar.
   */
  setUserProperties(properties: Record<string, unknown>): UtpEvent | null {
    const clean = sanitizeProfileProperties(properties);
    this.logDropped(USER_PROPERTIES_EVENT_NAME, clean.dropped);
    if (!Object.keys(clean.properties).length) { this.log("geçerli kullanıcı özelliği yok, olay üretilmedi"); return null; }
    return this.track(USER_PROPERTIES_EVENT_NAME, clean.properties);
  }

  /**
   * Bundan sonraki her olaya (`fr_` sistem olayları hariç) eklenecek özellikleri birleştirir; `null` anahtarı siler. Olayın kendi özelliği
   * aynı anahtarda globali ezer. Bellekte tutulur, depoya yazılmaz; en çok 50 anahtar. Kurallar `setUserProperties` ile aynıdır.
   */
  setGlobalProperties(properties: Record<string, unknown>) {
    this.logDropped("global", mergeGlobalProperties(this.globals, properties));
  }

  /** Bütün global özellikleri siler. */
  clearGlobalProperties() { this.globals.clear(); }

  /** Düşen anahtarlar (değer değil) hata ayıklama günlüğüne yazılır. */
  private logDropped(scope: string, dropped: ProfileDrop[]) {
    if (dropped.length) this.log("özellik düştü", scope, dropped);
  }

  /** Oturumu ve kimliği sıfırlar (çıkış). Anonim kimlik yenilenir, global özellikler silinir; eski veriler sunucuda kalır. */
  reset() {
    if (this.destroyed) return;
    this.userId = undefined;
    this.globals.clear();
    this.renewIdentity();
    this.syncAnonymousId();
    this.syncSession();
    this.clearQueue();
  }

  optOut() { this.setConsent({ analytics: false }); }

  /** Tek sayfalı uygulamada rota değişince `document.referrer` eski kalır; otomatik olay modülü önceki sayfanın adresini burada verir (yalnız origin gönderilir). Boş değer geçersiz kılmayı kaldırır. */
  setReferrer(url?: string) { this.referrerOverride = url || undefined; }

  page(properties?: Record<string, unknown>) {
    return this.track("page_view", properties);
  }

  /**
   * Satın alma ya da abonelik beyanı (`feralin_purchase`). İstemci beyanıdır: sunucu bu satırı yalnız makbuz doğrulayıcısı onaylarsa
   * REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` alanı istemciden hiçbir zaman gönderilmez. Geçersiz girdide null döner.
   */
  trackRevenue(input: RevenueInput): UtpEvent | null {
    const props = buildRevenueProperties(input);
    if (!props) { this.log("geçersiz gelir girdisi, olay üretilmedi"); return null; }
    return this.track(REVENUE_EVENT_NAME, props);
  }

  track(eventName: string, properties?: Record<string, unknown>): UtpEvent | null {
    if (this.destroyed) { this.log("yok edilmiş örnek, olay üretilmedi", eventName); return null; }
    if (!this.consent.analytics) { this.log("consent yok, olay üretilmedi", eventName); return null; }
    if (!/^[a-z][a-z0-9_]*$/.test(eventName) || eventName.length > 100) { this.log("geçersiz olay adı", eventName); return null; }
    this.touchSession();
    const e: UtpEvent = {
      event_id: ulid(),
      event_name: eventName,
      occurred_at: nowIso(),
      platform: "web",
      schema_version: 1,
      sdk: { name: SDK_NAME, version: SDK_VERSION },
      anonymous_id: this.anonymousId,
      session_id: this.sessionId,
      consent: { ...this.consent },
    };
    if (this.userId) e.user_id = this.userId;
    let props = sanitizeProps(properties);
    // Global özellikler: olayın kendi özelliği önceliklidir, şemanın 100 özellik sınırı aşılmaz.
    if (this.globals.size && acceptsGlobalProperties(eventName)) {
      const merged: Record<string, unknown> = { ...props };
      for (const [key, value] of this.globals) {
        if (!(key in merged) && Object.keys(merged).length < MAX_PROPERTIES) merged[key] = value;
      }
      props = merged;
    }
    // Tıklama kimliği reklam amaçlıdır: yalnız açık reklam izniyle gider.
    if (props && this.consent.advertising !== true) delete props.fr_click;
    if (hasWindow()) {
      const page = cleanPage(location.href);
      props = withUtm(props, page.utm);
      e.context = {
        ...(page.url ? { page_url: page.url.slice(0, 2048) } : {}),
        page_title: document.title.slice(0, 512),
        referrer: cleanReferrer(this.referrerOverride ?? document.referrer).slice(0, 2048),
        locale: navigator.language,
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        screen: { width: window.innerWidth, height: window.innerHeight },
      };
    }
    // Eşleştirme kodu yalnız ilk olaya eklenir; özellik sınırı kodu dışarıda bırakmasın diye en sona yazılır.
    const installCode = this.pendingInstallCode;
    if (installCode) props = { ...(props ?? {}), [INSTALL_CODE_PROPERTY]: installCode };
    if (props && Object.keys(props).length) e.properties = props;
    this.queue.push(e);
    if (installCode) this.pendingInstallCode = null;
    if (this.queue.size >= this.opts.batchSize) this.backgroundFlush();
    return e;
  }

  /** Kuyruğu gönderir. İzin yoksa hiçbir şey gönderilmez: izin reddedildiyse kuyruk silinir, henüz bildirilmediyse bekletilir. Başarı (202) → ack; 4xx (429 hariç) → olaylar atılır (tekrar denenmez); 5xx/ağ → kuyrukta kalır, aynı batch aynı anahtarla yeniden denenir. */
  async flush(useBeacon = false): Promise<FlushResult> {
    // Birden çok sekme aynı kuyruğu paylaşır: Web Locks varsa aynı anda yalnız bir sekme gönderir, kilidi bulamayan atlar (kuyruk depoda
    // kalır, sonraki turda gider). Sayfa kapanışı beklemez: kilit asenkrondur ve sayfa kapanırken geç kalırdı; orada toplayıcı event_id
    // ve içerik özetli idempotency anahtarıyla tekilleştirir.
    const locks = useBeacon || typeof navigator === "undefined" ? undefined : (navigator as { locks?: { request: (name: string, options: { ifAvailable: boolean }, cb: (lock: unknown) => Promise<FlushResult>) => Promise<FlushResult> } }).locks;
    if (locks?.request) {
      return locks.request(`fr_flush_${this.keyPrefix()}`, { ifAvailable: true }, (lock) => (lock ? this.flushLocked(useBeacon) : Promise.resolve({ sent: 0, status: 0 })));
    }
    return this.flushLocked(useBeacon);
  }

  private async flushLocked(useBeacon: boolean): Promise<FlushResult> {
    if (this.destroyed) return { sent: 0, status: 0 };
    if (!this.consent.analytics) {
      if (this.consentKnown) this.clearQueue();
      return { sent: 0, status: 0 };
    }
    if (this.inflight || (!this.pinned && this.queue.size === 0)) return { sent: 0, status: 0 };
    const events = this.pinned ?? this.queue.peek(this.opts.batchSize);
    const epoch = this.queueEpoch;
    const body = JSON.stringify({ sent_at: nowIso(), events });
    const idempotencyKey = idempotencyKeyFor(events);
    const url = this.opts.collectUrl.replace(/\/$/, "") + "/v1/batch";
    this.inflight = true;
    const keepForRetry = (retryAfter: string | null) => {
      if (epoch === this.queueEpoch) this.pinned = events;
      this.noteFailure(retryAfter);
    };
    try {
      const res = await this.fetchImpl(url, {
        method: "POST",
        headers: { "content-type": "application/json", "x-feralin-project-key": this.opts.projectKey, "idempotency-key": idempotencyKey },
        body,
        keepalive: useBeacon,
      });
      if (res.status === 202) {
        const data = (await res.json().catch(() => ({}))) as { batch_id?: string; trace_id?: string; accepted?: number; rejected?: number; rejected_events?: RejectedEvent[] };
        this.settle(events);
        this.log("gönderildi", data);
        return { sent: events.length, accepted: data.accepted ?? events.length, rejected: data.rejected ?? 0, ...(data.rejected_events ? { rejected_events: data.rejected_events } : {}), batch_id: data.batch_id, trace_id: data.trace_id, status: 202 };
      }
      if (res.status >= 400 && res.status < 500 && res.status !== 429) {
        this.settle(events);
        this.log("kalıcı ret", res.status);
        return { sent: events.length, accepted: 0, rejected: events.length, status: res.status };
      }
      keepForRetry(res.headers?.get?.("retry-after") ?? null);
      this.log("geçici hata, kuyrukta tutuluyor", res.status);
      return { sent: events.length, accepted: 0, rejected: 0, status: res.status };
    } catch (err) {
      keepForRetry(null);
      this.log("ağ hatası", err);
      return { sent: events.length, accepted: 0, rejected: 0, status: 0 };
    } finally {
      this.inflight = false;
    }
  }

  /**
   * Zamanlayıcıyı ve sayfa dinleyicilerini kaldırır; örnek bundan sonra olay üretmez, göndermez, depoya yazmaz. Süren istek
   * biterken de yazmaz. Kuyruk silinmez: her olay üretildiğinde depoya yazıldığı için aynı depoyu kullanan yeni örnek okur.
   * Süren istek sunucuya ulaştıysa olay yeni örnekten bir kez daha gider; toplayıcı event_id ile tekilleştirir.
   */
  destroy() {
    this.destroyed = true;
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    this.unbindPageEvents?.();
    this.unbindPageEvents = undefined;
  }
}

let singleton: Feralin | undefined;

/** Snippet kullanımı: feralin.initialize({...}); feralin.track('signup'). */
export function initialize(options: FeralinOptions): Feralin {
  singleton?.destroy();
  singleton = new Feralin(options);
  return singleton;
}
export function track(name: string, props?: Record<string, unknown>) { return singleton?.track(name, props) ?? null; }
export function trackRevenue(input: RevenueInput) { return singleton?.trackRevenue(input) ?? null; }
export function page(props?: Record<string, unknown>) { return singleton?.page(props) ?? null; }
export function identify(userId: string) { singleton?.identify(userId); }
export function group(groupId: string, traits?: Record<string, unknown>) { return singleton?.group(groupId, traits) ?? null; }
export function setUserProperties(properties: Record<string, unknown>) { return singleton?.setUserProperties(properties) ?? null; }
export function setGlobalProperties(properties: Record<string, unknown>) { singleton?.setGlobalProperties(properties); }
export function clearGlobalProperties() { singleton?.clearGlobalProperties(); }
export function setConsent(c: Consent) { singleton?.setConsent(c); }
export function flush() { return singleton?.flush() ?? Promise.resolve({ sent: 0, status: 0 } as FlushResult); }
export function reset() { singleton?.reset(); }
export function optOut() { singleton?.optOut(); }
export function setReferrer(url?: string) { singleton?.setReferrer(url); }
export function getStatus() { return singleton?.getStatus() ?? null; }
export const version = SDK_VERSION;
