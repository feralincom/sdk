<?php

declare(strict_types=1);

namespace Feralin;

/**
 * `trackRevenue` sözleşmesi (F5-E04-T01): olay adı `feralin_purchase`; tutar küçük birimde tam sayı (kuruş, cent), para birimi
 * ISO 4217. İstemci beyanıdır: `verified` hiçbir zaman gönderilmez, doğrulama sunucu tarafı makbuz doğrulayıcısınındır. Kurallar
 * Web, Node, Python, Go ve .NET SDK'larıyla birebir aynıdır (packages/sdk-web/src/index.ts `buildRevenueProperties`).
 */
final class Revenue
{
    public const EVENT_NAME = 'feralin_purchase';
    public const PURCHASE_TYPES = ['purchase', 'subscription_start', 'subscription_renew', 'subscription_cancel'];
    public const RECEIPT_PROVIDERS = ['apple', 'google', 'stripe'];
    /** JS güvenli tam sayı üst sınırı; defter (PostgreSQL bigint) ve toplayıcı bunu taşır. */
    public const MAX_AMOUNT_MINOR = 9007199254740991;
    public const MAX_QUANTITY = 100000;

    /** İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür. */
    private const RESERVED_KEYS = ['verified', 'verification', 'verification_source', 'receipt_provider', 'receipt_digest', 'receipt'];

    /**
     * Gelir olayının özelliklerini kurar; sözleşme dışı girdide null döner (fırlatmaz).
     *
     * @param array{
     *   transactionId?: mixed,
     *   amountMinor?: mixed,
     *   currency?: mixed,
     *   productId?: mixed,
     *   quantity?: mixed,
     *   purchaseType?: mixed,
     *   receipt?: mixed,
     *   properties?: mixed,
     * } $input amountMinor satır toplamıdır (quantity ile çarpılmaz); abonelik iptalinde 0.
     * @return array<string, mixed>|null
     */
    public static function properties(array $input): ?array
    {
        $transactionId = $input['transactionId'] ?? null;
        if (!is_string($transactionId) || $transactionId === '' || mb_strlen($transactionId, 'UTF-8') > 128) {
            return null;
        }
        $amountMinor = $input['amountMinor'] ?? null;
        // Ondalık ya da metin tutar kabul edilmez; kayan nokta yuvarlaması defteri bozardı.
        if (!is_int($amountMinor) || $amountMinor < 0 || $amountMinor > self::MAX_AMOUNT_MINOR) {
            return null;
        }
        $currency = $input['currency'] ?? null;
        if (!is_string($currency) || preg_match('/^[A-Z]{3}$/D', $currency) !== 1) {
            return null;
        }
        $productId = $input['productId'] ?? null;
        if ($productId !== null && (!is_string($productId) || $productId === '' || mb_strlen($productId, 'UTF-8') > 128)) {
            return null;
        }
        $quantity = $input['quantity'] ?? 1;
        if (!is_int($quantity) || $quantity < 0 || $quantity > self::MAX_QUANTITY) {
            return null;
        }
        $purchaseType = $input['purchaseType'] ?? 'purchase';
        if (!in_array($purchaseType, self::PURCHASE_TYPES, true)) {
            return null;
        }
        // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
        if ($purchaseType === 'subscription_cancel' && $amountMinor !== 0) {
            return null;
        }
        $receipt = $input['receipt'] ?? null;
        if ($receipt !== null) {
            if (
                !is_array($receipt)
                || !in_array($receipt['provider'] ?? null, self::RECEIPT_PROVIDERS, true)
                || !is_string($receipt['token'] ?? null)
                || $receipt['token'] === ''
                || mb_strlen($receipt['token'], 'UTF-8') > 8192
            ) {
                return null;
            }
        }
        $extra = $input['properties'] ?? [];
        if (!is_array($extra)) {
            return null;
        }

        // Sözleşme alanları önce yazılır: 100 özellik sınırında kırpılan her zaman çağıranın ek alanlarıdır.
        $props = [
            'transaction_id' => $transactionId,
            'amount_minor' => $amountMinor,
            'currency' => $currency,
            'quantity' => $quantity,
            'purchase_type' => $purchaseType,
        ];
        if ($productId !== null) {
            $props['product_id'] = $productId;
        }
        if ($receipt !== null) {
            $props['receipt'] = ['provider' => $receipt['provider'], 'token' => $receipt['token']];
        }
        foreach ($extra as $key => $value) {
            if (!in_array($key, self::RESERVED_KEYS, true) && !array_key_exists($key, $props)) {
                $props[$key] = $value;
            }
        }
        return $props;
    }
}
