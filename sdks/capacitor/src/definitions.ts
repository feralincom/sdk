// Uygulamaya açık tipler ve yerel eklentinin (Android Plugin, iOS CAPPlugin, web yedeği) çağrı sözleşmesi.

export interface Consent {
  analytics: boolean;
  advertising?: boolean;
  personalization?: boolean;
  session_replay?: boolean;
}

/** SDK imza anahtarı: `id` panelde görünen kimlik (`sgn_…`), `secret` üretildiği anda bir kez gösterilen değer (16-200 karakter). */
export interface SigningKey {
  id: string;
  secret: string;
}

export interface FeralinConfig {
  /** Public proje anahtarı (pk_…). `sk_` ile başlayan gizli anahtar reddedilir ve SDK kapalı kalır. */
  projectKey: string;
  /** Toplayıcı kökü, ör. https://collect.example.com. */
  collectUrl: string;
  /** Kayıtlı izin kararı. Android ve web'de verilmezse izin bekleniyor sayılır; iOS'ta analitik kapalı sayılır ve diskteki kuyruk silinir. */
  consent?: Consent;
  flushIntervalMs?: number;
  batchSize?: number;
  queueLimit?: number;
  sessionTimeoutMs?: number;
  /** Android: App Link niyetlerini otomatik yakala (varsayılan true). */
  autoCaptureDeepLinks?: boolean;
  debug?: boolean;
  /** Panelin "Kurulumu doğrula" ekranındaki tek kullanımlık kod. */
  installCode?: string;
  /** Android: Meta Install Referrer için Facebook uygulama kimliği (5-20 rakam). */
  metaAppId?: string;
  /** Biçimi bozuk anahtar yapılandırma hatasıdır: `initialize` false döner. */
  signingKey?: SigningKey;
  childDirected?: boolean;
  consentMaxAgeDays?: number;
  /** Android: Google reklam kimliği (GAID) yalnız açıkça istenirse ve reklam izniyle okunur. */
  collectAdvertisingId?: boolean;
  /** Fera Fly kısa link hostları (varsayılan fera.fly). */
  shortLinkHosts?: string[];
  /** iOS ertelenmiş derin bağlantı ve kurulum bağlama için saas-api adresi ve proje kimliği. */
  attribution?: { apiUrl: string; projectId: string };
}

export type PurchaseType = "purchase" | "subscription_start" | "subscription_renew" | "subscription_cancel";
export type ReceiptProvider = "apple" | "google" | "stripe";

export interface RevenueInput {
  /** Mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz (1-128). */
  transactionId: string;
  /** Küçük birimde tam sayı: 49,99 TL için 4999. Abonelik iptalinde 0. */
  amountMinor: number;
  /** ISO 4217, üç büyük harf. */
  currency: string;
  productId?: string;
  quantity?: number;
  purchaseType?: PurchaseType;
  receipt?: { provider: ReceiptProvider; token: string };
  properties?: Record<string, unknown>;
}

export interface FlushResult {
  sent: number;
  accepted: number;
  rejected: number;
  /** 0: istek yapılmadı ya da ağ hatası. */
  status: number;
  batchId: string | null;
}

export interface FirstOpenOptions {
  /** Pano ya da başka bir kanıttan gelen tıklama kimliği (iOS); yalnız reklam ölçümü izniyle gider. */
  clickId?: string;
  /** Kimliğin kaynağı, ör. `clipboard`. */
  source?: string;
  /** iOS IDFA; yalnız ATT izni `authorized` iken ve reklam ölçümü izniyle gider. */
  advertisingId?: string;
}

export type FirstOpenStatus = "sent" | "automatic" | "already_sent" | "skipped" | "not_initialized" | "not_supported";

export interface FirstOpenResult {
  /** `automatic`: Android çekirdeği ilk açılışı kendisi üretir. `not_supported`: web; uygulama kurulumu yoktur. */
  status: FirstOpenStatus;
  eventId: string | null;
}

export interface LinkOpen {
  /** Uygulamanın gideceği yol; dışarıdan gelen veridir, kendi yönlendirme tablonuzla eşleştirin. */
  destination: string;
  linkCode: string | null;
  hasClickId: boolean;
}

export type DeferredDeepLinkStatus =
  | "delivered"
  | "none"
  | "consent_required"
  | "not_initialized"
  | "pending"
  | "not_configured"
  | "not_supported"
  | "failed";

export interface DeferredDeepLink {
  status: DeferredDeepLinkStatus;
  path: string | null;
  linkCode: string | null;
}

export interface FeralinStatus {
  initialized: boolean;
  sdk: string;
  version: string;
  queued: number;
  consent: Consent | null;
  anonymousId: string | null;
  sessionId: string | null;
  userId: string | null;
}

/** Uygulamanın kullandığı yüz. Hiçbir yöntem hata fırlatmaz ya da reddedilen Promise döndürmez. */
export interface FeralinApi {
  readonly SDK_NAME: string;
  readonly SDK_VERSION: string;
  initialize(config: FeralinConfig): Promise<boolean>;
  setConsent(consent: Consent): Promise<boolean>;
  optOut(): Promise<boolean>;
  track(name: string, properties?: Record<string, unknown>): Promise<string | null>;
  screen(name: string, properties?: Record<string, unknown>): Promise<string | null>;
  identify(userId: string): Promise<boolean>;
  reset(): Promise<boolean>;
  group(groupId: string, traits?: Record<string, unknown>): Promise<string | null>;
  setUserProperties(properties: Record<string, unknown>): Promise<string | null>;
  setGlobalProperties(properties: Record<string, unknown>): Promise<number>;
  clearGlobalProperties(): Promise<boolean>;
  trackRevenue(input: RevenueInput): Promise<string | null>;
  flush(): Promise<FlushResult>;
  trackFirstOpen(options?: FirstOpenOptions): Promise<FirstOpenResult>;
  getInstallStore(): Promise<string | null>;
  handleUniversalLink(url: string): Promise<LinkOpen>;
  handleShortLink(url: string): Promise<LinkOpen>;
  consumeDeferredDeepLink(callback?: (link: DeferredDeepLink) => void): Promise<DeferredDeepLink>;
  setPushToken(token: string): Promise<string | null>;
  /** Push iletisinin verisi (`data` / `userInfo`) Feralin kaldırma ölçümü bildirimi mi? `true` ise bildirimi göstermeyin. */
  isUninstallCheck(data: Record<string, unknown> | null | undefined): boolean;
  installIdentifier(): Promise<string | null>;
  getStatus(): Promise<FeralinStatus>;
}

/** Normalleştirilmiş yapılandırma: JS katmanı doğrular, yerel katman olduğu gibi kullanır. */
export type NativeConfig = Omit<FeralinConfig, "consent"> & { consent?: Consent; sdkName: string; sdkVersion: string };

/**
 * Yerel eklentinin çağrı sözleşmesi. Capacitor her çağrıya tek nesne verir ve sonucu nesne olarak döndürür; alan adları Android
 * (`FeralinPlugin.java`), iOS (`FeralinPlugin.swift`) ve web yedeğinde (`web.ts`) aynıdır.
 */
export interface NativeFeralin {
  initialize(options: { config: NativeConfig }): Promise<{ ready?: boolean }>;
  setConsent(options: { consent: Consent }): Promise<{ ok?: boolean }>;
  track(options: { name: string; properties: Record<string, unknown> | null }): Promise<{ eventId?: string | null }>;
  screen(options: { name: string; properties: Record<string, unknown> | null }): Promise<{ eventId?: string | null }>;
  identify(options: { userId: string }): Promise<{ ok?: boolean }>;
  reset(): Promise<{ ok?: boolean }>;
  group(options: { groupId: string; traits: Record<string, unknown> | null }): Promise<{ eventId?: string | null }>;
  setUserProperties(options: { properties: Record<string, unknown> }): Promise<{ eventId?: string | null }>;
  setGlobalProperties(options: { properties: Record<string, unknown> }): Promise<{ count?: number }>;
  clearGlobalProperties(): Promise<{ ok?: boolean }>;
  trackRevenue(options: { input: Record<string, unknown>; properties: Record<string, unknown> }): Promise<{ eventId?: string | null }>;
  flush(): Promise<Partial<FlushResult>>;
  trackFirstOpen(options: { options: FirstOpenOptions }): Promise<Partial<FirstOpenResult>>;
  getInstallStore(): Promise<{ installStore?: string | null }>;
  handleUniversalLink(options: { url: string }): Promise<Partial<LinkOpen>>;
  handleShortLink(options: { url: string }): Promise<Partial<LinkOpen>>;
  consumeDeferredDeepLink(): Promise<Partial<DeferredDeepLink>>;
  setPushToken(options: { token: string }): Promise<{ eventId?: string | null }>;
  installIdentifier(): Promise<{ installId?: string | null }>;
  getStatus(): Promise<Partial<FeralinStatus>>;
}
