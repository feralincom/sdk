// Feralin Node.js server SDK. İlkeler Web SDK ile aynıdır: izin yoksa olay üretilmez, at-least-once gönderim, tüm
// event_id'lerin özetinden idempotency anahtarı, anahtar yalnız x-feralin-project-key başlığında. Yapılandırma
// hatası başlangıçta fırlar; çalışma zamanındaki hiçbir metot uygulamaya hata fırlatmaz.
import {
  ATTRIBUTION_CLICK_PROPERTY,
  MAX_IDENTIFIER_LENGTH,
  idempotencyKeyFor,
  normalizeContext,
  sanitizeProperties,
  ulid,
  validEventName,
} from "./event.js";
import type { CaptureErrorOptions, Consent, FeralinOptions, FeralinStatus, FlushResult, TrackOptions, UtpEvent } from "./types.js";
import { buildRevenueProperties, REVENUE_EVENT_NAME } from "./revenue.js";
import { GROUP_EVENT_NAME, USER_PROPERTIES_EVENT_NAME, acceptsGlobalProperties, mergeGlobalProperties, sanitizeProfileProperties, validGroupId } from "./profile.js";
import type { ProfileDrop, ProfileValue } from "./profile.js";
import type { RevenueInput } from "./revenue.js";
import { ERROR_EVENT_NAME, ERROR_ORIGINS, ErrorLimiter, buildErrorProperties } from "./errors.js";
import type { ErrorOrigin } from "./errors.js";
import { DEFAULT_STALE_MS, FileQueue } from "./storage.js";
import type { RecoveredQueue, StoredEvent } from "./storage.js";

export const SDK_NAME = "@feralin/node";
export const SDK_VERSION = "0.2.0";

const MAX_BATCH_EVENTS = 500;
// Toplayıcı gövdeyi 1 MiB ile sınırlar; zarf için pay bırakılır.
const MAX_BODY_BYTES = 900 * 1024;
const MIN_BACKOFF_MS = 1_000;
const MAX_BACKOFF_MS = 30_000;
const MAX_RETRY_AFTER_MS = 5 * 60_000;
const DEFAULT_CLOSE_TIMEOUT_MS = 5_000;
const DEFAULT_STORAGE_MAX_BYTES = 10 * 1024 * 1024;
const DEFAULT_STORAGE_MAX_AGE_MS = 7 * 24 * 60 * 60_000;
// Toplayıcı 90 günden eski olayı reddeder; daha uzun yaş sınırı anlamsızdır.
const MAX_STORAGE_AGE_MS = 90 * 24 * 60 * 60_000;

/** Kuyruktaki olay; kalıcı kuyrukla aynı biçim (`at`: kuyruğa giriş zamanı, yaş sınırı için). */
type QueuedEvent = StoredEvent;

/** Kurulum eşleştirme kodu özelliği ve biçimi (Web SDK ve `services/collect/internal/worker/installcode.go` ile aynı). */
export const INSTALL_CODE_PROPERTY = "fr_install_code";
export const INSTALL_CODE_PATTERN = /^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$/;
// Toplayıcı bu ayrılmış olayların gövdesini izin listesine indirir; kod orada düşeceği için bir sonraki olaya bırakılır.
const INSTALL_CODE_SKIP_EVENTS: ReadonlySet<string> = new Set(["fr_error", "fr_ad_revenue"]);

const EMPTY_RESULT: Readonly<FlushResult> = Object.freeze({ sent: 0, accepted: 0, rejected: 0, status: 0, retained: 0 });

export class FeralinClient {
  private readonly projectKey: string;
  private readonly endpoint: string;
  private readonly fetchImpl: typeof fetch;
  private readonly batchSize: number;
  private readonly queueLimit: number;
  private readonly timeoutMs: number;
  private readonly logger: FeralinOptions["logger"];
  private readonly now: () => number;
  private readonly random: () => number;

  private consent: Consent;
  /** Açık ret: olay bazlı izin de geçersizdir, sıfır gönderim. */
  private optedOut = false;
  private userId: string | undefined;
  private closed = false;
  private dropped = 0;
  private queue: QueuedEvent[] = [];
  // Sonucu bilinmeyen batch aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda kaybolduysa
  // araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
  private pinned: QueuedEvent[] | null = null;
  private failures = 0;
  private notBefore = 0;
  private serverNotBefore = 0;
  private draining: Promise<FlushResult> | null = null;
  private timer: ReturnType<typeof setInterval> | undefined;
  /** `setGlobalProperties` haritası: süreç belleğinde, istemci örneğine bağlı; `fr_` dışındaki her olaya eklenir. */
  private readonly globals = new Map<string, ProfileValue>();
  private readonly errorLimiter: ErrorLimiter;
  /** Kurulum eşleştirme kodu; ilk uygun olaya eklenir ve silinir (Web, Android ve Flutter SDK'larıyla aynı kural). */
  private pendingInstallCode: string | null;
  private readonly errorOptions: NonNullable<FeralinOptions["errors"]>;
  /** `storageDirectory` verildiyse kuyruğun disk yansıması; yazım hatasında kapanır ve kuyruk bellekte sürer. */
  private storage: FileQueue | null = null;
  private readonly storageMaxBytes: number;
  private readonly storageMaxAgeMs: number;
  /** Çöken süreçten devralınan, bileşimi sabit batch'ler: aynı Idempotency-Key ile, yeni olaylardan önce gönderilir. */
  private recovered: QueuedEvent[][] = [];
  private storageTimer: ReturnType<typeof setInterval> | undefined;

  constructor(options: FeralinOptions) {
    const key = typeof options?.projectKey === "string" ? options.projectKey.trim() : "";
    if (key.startsWith("sk_")) throw new Error("feralin: gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin");
    if (!key.startsWith("pk_") || key.length < 8) throw new Error("feralin: projectKey pk_ ile başlamalı");
    let collect: URL;
    try {
      collect = new URL(String(options.collectUrl ?? "").trim());
    } catch {
      throw new Error("feralin: collectUrl http veya https şemalı mutlak adres olmalı");
    }
    if ((collect.protocol !== "http:" && collect.protocol !== "https:") || !collect.host) {
      throw new Error("feralin: collectUrl http veya https şemalı mutlak adres olmalı");
    }
    const fetchImpl = options.fetch ?? globalThis.fetch;
    if (typeof fetchImpl !== "function") throw new Error("feralin: fetch yok; Node 20+ kullanın veya fetch verin");

    this.projectKey = key;
    this.endpoint = collect.toString().replace(/\/+$/, "") + "/v1/batch";
    this.fetchImpl = fetchImpl;
    this.batchSize = Math.min(MAX_BATCH_EVENTS, Math.max(1, Math.floor(options.batchSize ?? 100)));
    this.queueLimit = Math.max(1, Math.floor(options.queueLimit ?? 1000));
    this.timeoutMs = Math.max(1, options.timeoutMs ?? 10_000);
    this.logger = options.logger;
    this.now = options.now ?? Date.now;
    this.random = options.random ?? Math.random;
    this.consent = options.consent ? { ...options.consent } : { analytics: false };
    const installCode = typeof options.installCode === "string" ? options.installCode.trim() : "";
    this.pendingInstallCode = INSTALL_CODE_PATTERN.test(installCode) ? installCode : null;
    this.errorOptions = options.errors && typeof options.errors === "object" ? { ...options.errors } : {};
    this.errorLimiter = new ErrorLimiter(this.errorOptions, this.now, this.random);
    this.storageMaxBytes = Math.max(1024, Math.floor(options.storageMaxBytes ?? DEFAULT_STORAGE_MAX_BYTES));
    this.storageMaxAgeMs = Math.min(MAX_STORAGE_AGE_MS, Math.max(1_000, Math.floor(options.storageMaxAgeMs ?? DEFAULT_STORAGE_MAX_AGE_MS)));
    if (options.storageDirectory !== undefined) this.openStorage(options.storageDirectory);

    const interval = options.flushIntervalMs ?? 2_000;
    if (interval > 0) {
      this.timer = setInterval(() => this.backgroundTick(), interval);
      // Arka plan göndericisi süreç çıkışını engellemesin.
      this.timer.unref?.();
    }
  }

  /** Varsayılan izni günceller. analytics=false: bekleyen olaylar silinir ve olay bazlı izin de geçersiz olur. */
  setConsent(consent: Consent): void {
    this.consent = { ...consent };
    this.optedOut = consent?.analytics !== true;
    if (this.optedOut) this.clearQueue();
  }

  optOut(): void {
    this.setConsent({ analytics: false });
  }

  /** Varsayılan user_id; boş değer varsayılanı kaldırır. 128 karakteri aşan değer yok sayılır. */
  identify(userId: string | undefined): void {
    if (userId === undefined || userId === "") {
      this.userId = undefined;
    } else if (typeof userId === "string" && userId.length <= MAX_IDENTIFIER_LENGTH) {
      this.userId = userId;
    } else {
      this.warn("geçersiz user_id yok sayıldı");
    }
  }

  /**
   * Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve isteğe bağlı özellikler. Kimlik `options` ile
   * verilir (`track` ile aynı). Grup kimliği 1-128 karakter, `@` ve kontrol karakteri içermez; uymazsa null döner, fırlatmaz.
   */
  group(groupId: string, traits?: Record<string, unknown>, options?: TrackOptions): UtpEvent | null {
    if (!validGroupId(groupId)) {
      this.warn("geçersiz group_id, olay üretilmedi");
      return null;
    }
    const { properties, dropped } = sanitizeProfileProperties(traits);
    this.warnDropped(GROUP_EVENT_NAME, dropped);
    return this.track(GROUP_EVENT_NAME, { ...properties, group_id: groupId }, options);
  }

  /**
   * Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Değer dizge (≤256 karakter, e-posta biçiminde değil), sonlu sayı ya da
   * mantıksal olmalı; kişisel veriye benzeyen anahtar ve doğrulama alanı düşer. Geçerli özellik yoksa null döner. Sunucu yalnız projenin
   * izin listesindeki anahtarları saklar.
   */
  setUserProperties(properties: Record<string, unknown>, options?: TrackOptions): UtpEvent | null {
    const clean = sanitizeProfileProperties(properties);
    this.warnDropped(USER_PROPERTIES_EVENT_NAME, clean.dropped);
    if (!Object.keys(clean.properties).length) {
      this.warn("geçerli kullanıcı özelliği yok, olay üretilmedi");
      return null;
    }
    return this.track(USER_PROPERTIES_EVENT_NAME, clean.properties, options);
  }

  /**
   * Bu istemcinin bundan sonraki her olayına (`fr_` sistem olayları hariç) eklenecek özellikleri birleştirir; `null` anahtarı siler.
   * Olayın kendi özelliği aynı anahtarda globali ezer. En çok 50 anahtar; kurallar `setUserProperties` ile aynıdır. Sunucu SDK'sında
   * istemci çoğunlukla bütün isteklerce paylaşılır: kullanıcıya özgü değeri burada değil olayın kendisinde verin.
   */
  setGlobalProperties(properties: Record<string, unknown>): void {
    this.warnDropped("global", mergeGlobalProperties(this.globals, properties));
  }

  /** Bütün global özellikleri siler. */
  clearGlobalProperties(): void {
    this.globals.clear();
  }

  /** Düşen anahtar adları ve nedenleri uyarı olarak yazılır; değer yazılmaz. */
  private warnDropped(scope: string, dropped: ProfileDrop[]): void {
    if (dropped.length) this.warn("özellik düştü", { scope, dropped: dropped.map((item) => `${item.key}:${item.reason}`) });
  }

  /** Çıkış: varsayılan kimlik, global özellikler ve kuyruk silinir. */
  reset(): void {
    this.userId = undefined;
    this.globals.clear();
    this.clearQueue();
  }

  page(properties?: Record<string, unknown>, options?: TrackOptions): UtpEvent | null {
    return this.track("page_view", properties, options);
  }

  /**
   * Satın alma ya da abonelik beyanı (`feralin_purchase`). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa
   * REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez. Geçersiz girdide null döner, fırlatmaz.
   */
  trackRevenue(input: RevenueInput, options?: TrackOptions): UtpEvent | null {
    const props = buildRevenueProperties(input);
    if (!props) {
      this.warn("geçersiz gelir girdisi, olay üretilmedi");
      return null;
    }
    return this.track(REVENUE_EVENT_NAME, props, options);
  }

  /**
   * Yakalanan (try/catch) bir hatayı `fr_error` olarak bildirir. Ham yığın izi, dizin yolu ve kullanıcı verisi gitmez: hata sınıfı adı,
   * temizlenmiş mesaj (≤200), normalize çerçevelerin özeti olan parmak izi, en üst çerçeve ve en çok beş konum (dosya taban adı, satır,
   * sütun). İzin yoksa sınır sayacı harcanmaz; hata fırtınası sınırı (varsayılan saatte 20 olay, aynı parmak izi için 3) aşılırsa ya da
   * örneklemeye takılırsa null döner. Fırlatmaz.
   */
  captureError(error: unknown, options?: CaptureErrorOptions): UtpEvent | null {
    try {
      const consent = options?.consent ?? this.consent;
      if (this.closed || this.optedOut || consent?.analytics !== true) return null;
      const origin: ErrorOrigin = options?.origin && ERROR_ORIGINS.includes(options.origin) ? options.origin : "handled";
      const props = buildErrorProperties(error, origin, {
        appVersion: this.errorOptions.appVersion ?? options?.context?.app?.version,
        sourcePositions: this.errorOptions.sourcePositions,
        fatal: options?.fatal === true,
      });
      if (!this.errorLimiter.allow(props.fingerprint)) {
        this.logger?.debug?.("hata sınırı, fr_error üretilmedi");
        return null;
      }
      const { origin: _origin, fatal: _fatal, ...trackOptions } = options ?? {};
      return this.track(ERROR_EVENT_NAME, props as unknown as Record<string, unknown>, trackOptions);
    } catch (err) {
      this.warn("hata olayı üretilemedi", { error: err instanceof Error ? err.name : "unknown" });
      return null;
    }
  }

  /**
   * Olayı doğrular ve kuyruğa ekler; ağ çağrısı yapmaz. İzin yoksa, ad veya kimlik geçersizse null döner, fırlatmaz.
   * `fr_click` yalnız consent.advertising === true iken gönderilir, aksi halde olaydan çıkarılır.
   */
  track(eventName: string, properties?: Record<string, unknown>, options?: TrackOptions): UtpEvent | null {
    try {
      return this.buildAndEnqueue(eventName, properties, options);
    } catch (err) {
      this.warn("olay üretilemedi", { error: err instanceof Error ? err.name : "unknown" });
      return null;
    }
  }

  private buildAndEnqueue(eventName: string, properties?: Record<string, unknown>, options?: TrackOptions): UtpEvent | null {
    if (this.closed) return null;
    const consent = options?.consent ?? this.consent;
    if (this.optedOut || consent?.analytics !== true) {
      this.logger?.debug?.("izin yok, olay üretilmedi", { event_name: validEventName(eventName) ? eventName : "?" });
      return null;
    }
    if (!validEventName(eventName)) {
      this.warn("geçersiz olay adı");
      return null;
    }
    const userId = options?.userId ?? this.userId;
    for (const value of [userId, options?.anonymousId, options?.sessionId]) {
      if (value !== undefined && (typeof value !== "string" || value.length > MAX_IDENTIFIER_LENGTH)) {
        this.warn("geçersiz kimlik alanı, olay üretilmedi", { event_name: eventName });
        return null;
      }
    }

    const { context, utm } = normalizeContext(options?.context);
    const props = sanitizeProperties(properties);
    // Global özellikler: olayın kendi özelliği önceliklidir, şemanın 100 özellik sınırı aşılmaz.
    if (this.globals.size && acceptsGlobalProperties(eventName)) {
      for (const [key, value] of this.globals) {
        if (!(key in props) && Object.keys(props).length < 100) props[key] = value;
      }
    }
    for (const [key, value] of Object.entries(utm)) {
      if (!(key in props) && Object.keys(props).length < 100) props[key] = value;
    }
    if (consent.advertising !== true) delete props[ATTRIBUTION_CLICK_PROPERTY];
    // Eşleştirme kodu en sona yazılır; şemanın 100 özellik sınırı aşılmasın diye gerekirse son özellik yer açar.
    const installCode = INSTALL_CODE_SKIP_EVENTS.has(eventName) ? null : this.pendingInstallCode;
    if (installCode) {
      const keys = Object.keys(props);
      if (keys.length >= 100) delete props[keys[keys.length - 1]!];
      props[INSTALL_CODE_PROPERTY] = installCode;
    }

    const nowMs = this.now();
    const occurredAt = options?.occurredAt instanceof Date && !Number.isNaN(options.occurredAt.getTime()) ? options.occurredAt : new Date(nowMs);
    const event: UtpEvent = {
      event_id: ulid(nowMs),
      event_name: eventName,
      occurred_at: occurredAt.toISOString(),
      platform: "node",
      schema_version: 1,
      sdk: { name: SDK_NAME, version: SDK_VERSION },
      consent: { ...consent },
    };
    if (options?.anonymousId) event.anonymous_id = options.anonymousId;
    if (userId) event.user_id = userId;
    if (options?.sessionId) event.session_id = options.sessionId;
    if (Object.keys(props).length) event.properties = props;
    if (context) event.context = context;

    // Serileştirme kuyruktan önce yapılır: BigInt veya döngüsel değer batch'i zehirleyemez, yakalanıp olay atılır.
    const json = JSON.stringify(event);
    const bytes = Buffer.byteLength(json);
    if (bytes > MAX_BODY_BYTES) {
      this.warn("olay boyut sınırını aşıyor, atıldı", { event_name: eventName, bytes });
      return null;
    }
    const item: QueuedEvent = { id: event.event_id, json, bytes, name: eventName, at: nowMs };
    this.queue.push(item);
    this.persist((storage) => storage.append(item));
    if (installCode) this.pendingInstallCode = null;
    this.enforceQueueLimit();
    if (this.timer && this.queue.length >= this.batchSize) this.backgroundTick();
    return event;
  }

  private enforceQueueLimit(): void {
    const over = this.queued() - this.queueLimit;
    let removed = over > 0 ? this.queue.splice(0, over) : [];
    // Disk sınırı: kalıcı kuyruğun gövde baytı sınırı aşarsa en eski olaylar atılır (gönderimdeki batch'e dokunulmaz).
    const storage = this.storage;
    if (storage) {
      let excess = storage.liveBytes - removed.reduce((sum, item) => sum + item.bytes, 0) - this.storageMaxBytes;
      let count = 0;
      while (excess > 0 && count < this.queue.length) excess -= this.queue[count++]!.bytes;
      if (count > 0) removed = removed.concat(this.queue.splice(0, count));
    }
    if (removed.length > 0) {
      this.dropped += removed.length;
      this.persist((s) => s.remove(removed));
      this.warn("kuyruk sınırı aşıldı, en eski olaylar atıldı", { dropped: removed.length });
    }
  }

  private clearQueue(): void {
    this.queue = [];
    this.pinned = null;
    this.recovered = [];
    this.persist((storage) => storage.clear());
    this.failures = 0;
    this.notBefore = 0;
    this.serverNotBefore = 0;
  }

  private queued(): number {
    let count = this.queue.length + (this.pinned?.length ?? 0);
    for (const batch of this.recovered) count += batch.length;
    return count;
  }

  private backgroundTick(): void {
    if (this.closed) return;
    if (this.queued() === 0) return;
    if (this.now() < Math.max(this.notBefore, this.serverNotBefore)) return;
    void this.flush();
  }

  /**
   * Kuyruğu gönderir; fırlatmaz. 202 → silinir; 4xx (429 hariç) → atılır; 429, 5xx ve ağ hatası → aynı içerik ve aynı
   * anahtarla sonra denenir. Sunucunun Retry-After süresi dolmadan açık çağrı da istek yapmaz.
   */
  flush(): Promise<FlushResult> {
    return this.startDrain(false);
  }

  private startDrain(force: boolean): Promise<FlushResult> {
    if (this.draining) return this.draining;
    if (!force && this.now() < this.serverNotBefore) return Promise.resolve({ ...EMPTY_RESULT, retained: this.queued() });
    const run = this.drain().finally(() => {
      this.draining = null;
    });
    this.draining = run;
    return run;
  }

  private async drain(): Promise<FlushResult> {
    const total: FlushResult = { ...EMPTY_RESULT };
    // Üretici sürekli ekliyorsa döngü sonsuz olmasın.
    const rounds = Math.ceil(this.queueLimit / this.batchSize) + 2;
    for (let round = 0; round < rounds; round++) {
      const batch = this.nextBatch();
      if (!batch) break;
      const result = await this.send(batch);
      total.sent += result.sent;
      total.accepted += result.accepted;
      total.rejected += result.rejected;
      total.status = result.status;
      if (result.batch_id) total.batch_id = result.batch_id;
      if (result.retained > 0) break;
    }
    total.retained = this.queued();
    return total;
  }

  private nextBatch(): QueuedEvent[] | null {
    if (this.pinned) return this.pinned;
    // Devralınan batch zaten diskte sabitlenmiştir; yeniden yazılmaz.
    const recovered = this.recovered.shift();
    if (recovered) {
      this.pinned = recovered;
      return recovered;
    }
    if (this.storage) this.dropExpired();
    if (this.queue.length === 0) return null;
    let count = 0;
    let bytes = 0;
    for (const item of this.queue) {
      if (count >= this.batchSize || (count > 0 && bytes + item.bytes > MAX_BODY_BYTES)) break;
      count++;
      bytes += item.bytes + 1;
    }
    const batch = this.queue.splice(0, count);
    this.pinned = batch;
    this.persist((storage) => storage.pin(batch));
    return batch;
  }

  /** Kalıcı kuyrukta `storageMaxAgeMs` süresini aşan, henüz gönderime girmemiş olaylar atılır. */
  private dropExpired(): void {
    const limit = this.now() - this.storageMaxAgeMs;
    let count = 0;
    while (count < this.queue.length && this.queue[count]!.at < limit) count++;
    if (count === 0) return;
    const removed = this.queue.splice(0, count);
    this.dropped += removed.length;
    this.persist((storage) => storage.remove(removed));
    this.warn("kalıcı kuyrukta yaş sınırını aşan olaylar atıldı", { dropped: removed.length });
  }

  private async send(batch: QueuedEvent[]): Promise<FlushResult> {
    const size = batch.length;
    const body = `{"sent_at":${JSON.stringify(new Date(this.now()).toISOString())},"events":[${batch.map((item) => item.json).join(",")}]}`;
    let response: Response;
    let text = "";
    try {
      response = await this.fetchImpl(this.endpoint, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          accept: "application/json, application/problem+json",
          "x-feralin-project-key": this.projectKey,
          "idempotency-key": idempotencyKeyFor(batch.map((item) => item.id)),
          "user-agent": `feralin-node/${SDK_VERSION}`,
        },
        body,
        signal: AbortSignal.timeout(this.timeoutMs),
      });
      text = await response.text().catch(() => "");
    } catch (err) {
      this.noteFailure(null);
      this.logger?.debug?.("ağ hatası, olaylar kuyrukta", { count: size, error: err instanceof Error ? err.name : "unknown" });
      return { sent: size, accepted: 0, rejected: 0, status: 0, retained: size };
    }

    if (response.status === 202) {
      this.releaseBatch(batch);
      this.failures = 0;
      this.notBefore = 0;
      this.serverNotBefore = 0;
      const ack = parseObject(text);
      const result: FlushResult = {
        sent: size,
        accepted: typeof ack.accepted === "number" ? ack.accepted : size,
        rejected: typeof ack.rejected === "number" ? ack.rejected : 0,
        status: 202,
        retained: 0,
      };
      if (typeof ack.batch_id === "string") result.batch_id = ack.batch_id;
      this.logger?.debug?.("batch kabul edildi", { batch_id: result.batch_id, accepted: result.accepted, rejected: result.rejected });
      return result;
    }

    if (response.status >= 400 && response.status < 500 && response.status !== 429) {
      this.releaseBatch(batch);
      this.warn("batch kalıcı olarak reddedildi", { status: response.status, count: size, problem: problemTitle(text) });
      return { sent: size, accepted: 0, rejected: size, status: response.status, retained: 0 };
    }

    this.noteFailure(response.headers.get("retry-after"));
    this.logger?.debug?.("geçici hata, olaylar kuyrukta", { status: response.status, count: size });
    return { sent: size, accepted: 0, rejected: 0, status: response.status, retained: size };
  }

  /** İstek sürerken izin geri çekildiyse kuyruk çoktan boşaltılmıştır; yeni batch'e dokunulmaz. */
  private releaseBatch(batch: QueuedEvent[]): void {
    if (this.pinned !== batch) return;
    this.pinned = null;
    this.persist((storage) => storage.remove(batch));
  }

  /**
   * Kalıcı kuyruğu açar ve dizindeki sahipsiz günlükleri (çöken ya da kapanmadan çıkan süreçler) devralır. Dizin oluşturulamaz ya da
   * yazılamazsa fırlatır: yapılandırma hatası başlangıçta görünür.
   */
  private openStorage(directory: unknown): void {
    if (typeof directory !== "string" || directory.trim() === "") throw new Error("feralin: storageDirectory boş olmayan bir dizin yolu olmalı");
    let storage: FileQueue;
    try {
      storage = new FileQueue({
        directory,
        maxAgeMs: this.storageMaxAgeMs,
        now: this.now,
        snapshot: () => ({ batches: [...(this.pinned ? [this.pinned] : []), ...this.recovered], events: this.queue }),
      });
    } catch (err) {
      const code = (err as NodeJS.ErrnoException)?.code ?? (err instanceof Error ? err.name : "unknown");
      // Asıl hata (dizin yolu dahil) yalnız `cause` içinde kalır; ileti log satırına güvenle yazılabilir.
      throw new Error(`feralin: storageDirectory kullanılamıyor (${code})`, { cause: err });
    }
    this.storage = storage;
    this.adopt();
    // Kalp atışı: boşta bekleyen canlı sürecin günlüğü sahipsiz sayılmasın; aynı turda sonradan sahipsiz kalan günlükler devralınır.
    this.storageTimer = setInterval(() => {
      this.persist((s) => s.heartbeat());
      this.adopt();
    }, Math.floor(DEFAULT_STALE_MS / 4));
    this.storageTimer.unref?.();
  }

  /** Sahipsiz günlüklerdeki olayları kuyruğa alır: sabit batch'ler önce, kalan olaylar kuyruğun başına (en eskiler önce). */
  private adopt(): void {
    if (this.closed || this.optedOut) return;
    let found: RecoveredQueue | undefined;
    this.persist((storage) => {
      found = storage.recover();
    });
    if (!found || found.files === 0) return;
    this.recovered.push(...found.batches);
    if (found.events.length) this.queue = [...found.events, ...this.queue];
    const events = found.events.length + found.batches.reduce((sum, batch) => sum + batch.length, 0);
    this.dropped += found.expired;
    this.logger?.debug?.("kalıcı kuyruk devralındı", { files: found.files, events, batches: found.batches.length, expired: found.expired });
    this.enforceQueueLimit();
  }

  /** Disk işlemi hatası uygulamaya fırlatılmaz: uyarı yazılır, kalıcı kuyruk kapanır ve kuyruk bellekte sürer. */
  private persist(operation: (storage: FileQueue) => void): void {
    const storage = this.storage;
    if (!storage) return;
    try {
      operation(storage);
    } catch (err) {
      this.storage = null;
      if (this.storageTimer) clearInterval(this.storageTimer);
      try {
        storage.close();
      } catch {
        // Kapanamayan günlük sonraki açılışta devralınır.
      }
      this.warn("kalıcı kuyruk yazılamadı, bellek içi kuyrukla sürüyor", { error: (err as NodeJS.ErrnoException)?.code ?? (err instanceof Error ? err.name : "unknown") });
    }
  }

  private noteFailure(retryAfter: string | null): void {
    this.failures++;
    const ceiling = Math.min(MAX_BACKOFF_MS, MIN_BACKOFF_MS * 2 ** Math.min(this.failures - 1, 10));
    // Yarım jitter: aynı anda yeniden başlayan süreçler toplayıcıya birlikte yüklenmez.
    this.notBefore = this.now() + Math.round(ceiling * (0.5 + this.random() * 0.5));
    const seconds = retryAfter === null ? Number.NaN : Number(retryAfter.trim());
    if (Number.isFinite(seconds) && seconds > 0) {
      this.serverNotBefore = this.now() + Math.min(MAX_RETRY_AFTER_MS, seconds * 1000);
    }
  }

  /** Arka plan göndericiyi durdurur, kalanı en çok `timeoutMs` içinde göndermeyi dener. Birden çok çağrı güvenlidir. */
  async close(timeoutMs: number = DEFAULT_CLOSE_TIMEOUT_MS): Promise<FlushResult> {
    if (this.closed) return { ...EMPTY_RESULT, retained: this.queued() };
    this.closed = true;
    if (this.timer) clearInterval(this.timer);
    if (this.storageTimer) clearInterval(this.storageTimer);
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const expired = new Promise<FlushResult>((resolve) => {
      timeout = setTimeout(() => resolve({ ...EMPTY_RESULT, retained: this.queued() }), timeoutMs);
      timeout.unref?.();
    });
    try {
      return await Promise.race([this.startDrain(true), expired]);
    } finally {
      if (timeout) clearTimeout(timeout);
      // Boş günlük silinir; gönderilemeyen olaylar diskte kalır ve sonraki açılışta aynı batch bileşimiyle gönderilir.
      this.persist((storage) => storage.close());
      this.storage = null;
    }
  }

  getStatus(): FeralinStatus {
    return {
      sdk: SDK_NAME,
      version: SDK_VERSION,
      queued: this.queued(),
      dropped: this.dropped,
      consent: { ...this.consent },
      optedOut: this.optedOut,
      closed: this.closed,
      backoffMs: Math.max(0, Math.max(this.notBefore, this.serverNotBefore) - this.now()),
      endpoint: this.endpoint,
      storage: this.storage ? { path: this.storage.path, events: this.storage.size, bytes: this.storage.liveBytes } : null,
    };
  }

  private warn(message: string, fields?: Record<string, unknown>): void {
    try {
      this.logger?.warn?.(message, fields);
    } catch {
      // Uygulamanın logger hatası SDK akışını kesmez.
    }
  }
}

function parseObject(text: string): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(text);
    return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** Ham gövde loga yazılmaz; yalnız RFC 7807 başlığı. */
function problemTitle(text: string): string {
  const title = parseObject(text).title;
  return typeof title === "string" ? title.slice(0, 120) : "problem+json yok";
}
