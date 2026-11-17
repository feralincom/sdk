// Ana süreç ve preload'ın ortak IPC adları. Bağımlılık içermez; sandbox'lı preload paketine girer.
export const FERALIN_CHANNELS = Object.freeze({
  track: "feralin:track",
  page: "feralin:page",
  identify: "feralin:identify",
  setConsent: "feralin:set-consent",
  reset: "feralin:reset",
  flush: "feralin:flush",
  trackRevenue: "feralin:track-revenue",
  group: "feralin:group",
  setUserProperties: "feralin:set-user-properties",
  captureError: "feralin:capture-error",
});

export type FeralinChannel = (typeof FERALIN_CHANNELS)[keyof typeof FERALIN_CHANNELS];

/** `trackRevenue` girdisi (`@feralin/node` RevenueInput ile aynı alanlar); doğrulama ana süreçtedir. */
export interface BridgeRevenueInput {
  transactionId: string;
  /** Küçük birimde tam sayı: 49,99 TL için 4999. */
  amountMinor: number;
  /** ISO 4217, üç büyük harf. */
  currency: string;
  productId?: string;
  quantity?: number;
  purchaseType?: "purchase" | "subscription_start" | "subscription_renew" | "subscription_cancel";
  receipt?: { provider: "apple" | "google" | "stripe"; token: string };
  properties?: Record<string, unknown>;
}

/** IPC'den geçen hata özeti: Error nesnesi preload'da düz alanlara çevrilir. */
export interface BridgeErrorPayload {
  name?: string;
  message?: string;
  stack?: string;
}

/** Web görünümünün gördüğü yüzey. Tüm çağrılar Promise döner; anahtar ve ağ ana süreçte kalır. */
export interface FeralinBridge {
  track(eventName: string, properties?: Record<string, unknown>): Promise<boolean>;
  page(properties?: Record<string, unknown>): Promise<boolean>;
  identify(userId: string | null): Promise<void>;
  setConsent(consent: { analytics: boolean; advertising?: boolean; personalization?: boolean; session_replay?: boolean }): Promise<void>;
  reset(): Promise<void>;
  flush(): Promise<{ status: number; accepted: number; rejected: number; retained: number }>;
  /** Satın alma ya da abonelik beyanı (`feralin_purchase`); `verified` gönderilmez, geçersiz girdide false. */
  trackRevenue(input: BridgeRevenueInput): Promise<boolean>;
  /** `fr_group` olayı; grup kimliği geçersizse false. */
  group(groupId: string, traits?: Record<string, unknown>): Promise<boolean>;
  /** `fr_user_properties` olayı; kişisel veriye benzeyen anahtar düşer, geçerli özellik yoksa false. */
  setUserProperties(properties: Record<string, unknown>): Promise<boolean>;
  /** Yakalanan bir hatayı `fr_error` olarak bildirir; yığın izi ana süreçte normalize edilir, ham hâli gönderilmez. */
  captureError(error: unknown, options?: { origin?: "handled" | "manual" | "window_onerror" | "unhandledrejection" }): Promise<boolean>;
}
