/**
 * `trackRevenue` sözleşmesi (F5-E04-T01): olay adı `feralin_purchase`; tutar küçük birimde tam sayı (kuruş, cent), para birimi ISO 4217.
 * İstemci beyanıdır: `verified` hiçbir zaman gönderilmez, doğrulama sunucu tarafı makbuz doğrulayıcısınındır.
 */
export const REVENUE_EVENT_NAME = "feralin_purchase";

export type PurchaseType = "purchase" | "subscription_start" | "subscription_renew" | "subscription_cancel";
export type ReceiptProvider = "apple" | "google" | "stripe";

export interface RevenueInput {
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
}

/** İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür. */
const RESERVED_KEYS = ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"];
const PURCHASE_TYPES: readonly string[] = ["purchase", "subscription_start", "subscription_renew", "subscription_cancel"];
const RECEIPT_PROVIDERS: readonly string[] = ["apple", "google", "stripe"];
const CURRENCY = /^[A-Z]{3}$/;

/** Gelir olayının özelliklerini kurar; geçersiz girdide null döner. Kurallar bütün SDK'larda aynıdır. */
export function buildRevenueProperties(input: RevenueInput): Record<string, unknown> | null {
  if (!input || typeof input.transactionId !== "string" || input.transactionId.length < 1 || input.transactionId.length > 128) return null;
  if (!Number.isSafeInteger(input.amountMinor) || input.amountMinor < 0) return null;
  if (typeof input.currency !== "string" || !CURRENCY.test(input.currency)) return null;
  if (input.productId !== undefined && (typeof input.productId !== "string" || input.productId.length < 1 || input.productId.length > 128)) return null;
  const quantity = input.quantity ?? 1;
  if (!Number.isInteger(quantity) || quantity < 0 || quantity > 100_000) return null;
  const purchaseType = input.purchaseType ?? "purchase";
  if (!PURCHASE_TYPES.includes(purchaseType)) return null;
  // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
  if (purchaseType === "subscription_cancel" && input.amountMinor !== 0) return null;
  if (input.receipt !== undefined && (!input.receipt || !RECEIPT_PROVIDERS.includes(input.receipt.provider) || typeof input.receipt.token !== "string" || input.receipt.token.length < 1 || input.receipt.token.length > 8192)) return null;
  const props: Record<string, unknown> = { ...(input.properties ?? {}) };
  for (const key of RESERVED_KEYS) delete props[key];
  props["transaction_id"] = input.transactionId;
  props["amount_minor"] = input.amountMinor;
  props["currency"] = input.currency;
  props["quantity"] = quantity;
  props["purchase_type"] = purchaseType;
  if (input.productId !== undefined) props["product_id"] = input.productId;
  if (input.receipt) props["receipt"] = { provider: input.receipt.provider, token: input.receipt.token };
  return props;
}
