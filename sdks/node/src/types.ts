// UTP v1 tipleri: packages/schemas/utp/v1/event.schema.json ile birebir. tenant_id, project_id ve verified alanları
// istemciden gönderilmez; sunucu anahtar bağlamından çözer.

/** UTP v1 izin nesnesi. Server SDK'da karar müşteri uygulamasından geçirilir (consent passthrough). */
export interface Consent {
  analytics: boolean;
  advertising?: boolean;
  personalization?: boolean;
  session_replay?: boolean;
}

export interface EventContext {
  /** Sorgu ve parça gönderilmez; utm_* değerleri properties alanına taşınır. */
  page_url?: string;
  page_title?: string;
  /** Yalnız origin gönderilir. */
  referrer?: string;
  locale?: string;
  timezone?: string;
  screen?: { width?: number; height?: number };
  app?: { version?: string; build?: string };
}

export interface UtpEvent {
  event_id: string;
  event_name: string;
  occurred_at: string;
  platform: "node";
  schema_version: 1;
  sdk: { name: string; version: string };
  anonymous_id?: string;
  user_id?: string;
  session_id?: string;
  properties?: Record<string, unknown>;
  consent: Consent;
  context?: EventContext;
}

export interface TrackOptions {
  /** Müşteri uygulamasının kendi kullanıcı kimliği (≤128 karakter). E-posta veya telefon vermeyin. */
  userId?: string;
  anonymousId?: string;
  sessionId?: string;
  occurredAt?: Date;
  context?: EventContext;
  /** O olayın son kullanıcısına ait izin. Verilmezse istemcinin varsayılanı kullanılır. */
  consent?: Consent;
}

/** `captureError` seçenekleri: olay seçeneklerine ek olarak köken ve ölümcüllük. */
export interface CaptureErrorOptions extends TrackOptions {
  /** Varsayılan "handled". Elle oluşturulan bildirim için "manual"; süreç işleyicisinden "uncaught_exception" ya da "unhandledrejection". */
  origin?: "window_onerror" | "unhandledrejection" | "uncaught_exception" | "handled" | "manual";
  /** Süreci sonlandıran hata mı; varsayılan false. */
  fatal?: boolean;
}

export interface FlushResult {
  /** Bu çağrıda toplayıcıya iletilmeye çalışılan olay sayısı. */
  sent: number;
  /** Toplayıcının kabul ettiği olay sayısı; idempotent tekrarda 0 olabilir. */
  accepted: number;
  /** Toplayıcının reddettiği veya kalıcı 4xx ile atılan olay sayısı. */
  rejected: number;
  /** Son HTTP durumu; istek yapılmadıysa veya ağ hatasıysa 0. */
  status: number;
  /** Geçici hata sonrası kuyrukta kalan olay sayısı. */
  retained: number;
  batch_id?: string;
}

export interface FeralinLogger {
  debug?(message: string, fields?: Record<string, unknown>): void;
  warn?(message: string, fields?: Record<string, unknown>): void;
}

export interface FeralinOptions {
  /** Public proje anahtarı (pk_…). Yalnız x-feralin-project-key başlığında taşınır; sk_ reddedilir. */
  projectKey: string;
  /** Toplayıcı kökü, ör. https://collect.example.com. /v1/batch yolunu SDK ekler. */
  collectUrl: string;
  /** Varsayılan izin. Verilmezse analytics=false kabul edilir (consent-first). */
  consent?: Consent;
  /** Arka plan gönderim aralığı; 0 kapatır (yalnız flush/close). Varsayılan 2000 ms. */
  flushIntervalMs?: number;
  /** Tek istekteki en fazla olay (1…500). Varsayılan 100. */
  batchSize?: number;
  /** Bellek içi kuyruk üst sınırı; aşılınca en eski olay atılır. Varsayılan 1000. */
  queueLimit?: number;
  /** İstek zaman aşımı. Varsayılan 10000 ms. */
  timeoutMs?: number;
  /** Test, proxy veya özel TLS için fetch enjeksiyonu. */
  fetch?: typeof fetch;
  /** Anahtar, özellik değeri ve kimlik loga yazılmaz; yalnız olay adı, sayaç ve durum kodu gelir. */
  logger?: FeralinLogger;
  /**
   * Panelin ürettiği kurulum eşleştirme kodu (ör. "7K3M-9QX2-PA"). Biçime uyarsa ilk olaya `fr_install_code` olarak bir kez eklenir.
   * Masaüstü (Electron) ve tek kullanıcılı süreçler içindir; paylaşılan sunucu istemcisinde rastgele bir isteğin olayına düşer.
   */
  installCode?: string;
  /**
   * `captureError` ayarları: uygulama sürümü (≤32, `app_version`), sembolleştirme konumları (`frames`, varsayılan açık) ve hata fırtınası
   * sınırı (varsayılan: saatte 20 olay, aynı parmak izi için 3, örnekleme 1).
   */
  errors?: {
    appVersion?: string;
    sourcePositions?: boolean;
    sampleRate?: number;
    maxEvents?: number;
    maxPerFingerprint?: number;
    windowMs?: number;
  };
  /**
   * İsteğe bağlı kalıcı kuyruk dizini. Verilirse kuyruk bu dizindeki günlük dosyasına da yazılır; süreç çökerse ya da `close`
   * gönderemeden çıkarsa olaylar sonraki açılışta (ya da aynı dizini kullanan başka bir süreçte) aynı batch bileşimi ve aynı
   * Idempotency-Key ile gönderilir. Dizin yoksa oluşturulur (yalnız süreç kullanıcısına açık); yazılamıyorsa kurucu fırlatır.
   * Her istemci örneği kendi dosyasına yazar; birden çok süreç aynı dizini güvenle paylaşır. Olay gövdeleri diskte düz JSON durur.
   */
  storageDirectory?: string;
  /** Kalıcı kuyruğun olay gövdesi üst sınırı (bayt); aşılınca en eski olaylar atılır. Varsayılan 10 MiB. */
  storageMaxBytes?: number;
  /** Kalıcı kuyrukta bundan eski olay gönderilmez (ms). Varsayılan 7 gün, en çok 90 gün (toplayıcı sınırı). */
  storageMaxAgeMs?: number;
  /** Test için zaman ve rastgelelik kaynağı. */
  now?: () => number;
  random?: () => number;
}

export interface FeralinStatus {
  sdk: string;
  version: string;
  queued: number;
  dropped: number;
  consent: Consent;
  optedOut: boolean;
  closed: boolean;
  /** Kalan geri çekilme süresi (ms). */
  backoffMs: number;
  endpoint: string;
  /** Kalıcı kuyruk açıksa günlük dosyası, içindeki olay sayısı ve gövde baytı; kapalıysa ya da yazım hatasıyla kapandıysa null. */
  storage: { path: string; events: number; bytes: number } | null;
}
