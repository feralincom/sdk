package com.feralin.android.internal

import com.feralin.android.PurchaseType
import com.feralin.android.Receipt
import com.feralin.android.RevenueInput

/**
 * `trackRevenue` sözleşmesi (F5-E04-T01): olay adı `feralin_purchase`; tutar küçük birimde tam sayı (kuruş, cent), para birimi ISO 4217.
 * İstemci beyanıdır: `verified` hiçbir zaman gönderilmez, doğrulama sunucu tarafı makbuz doğrulayıcısınındır. Kurallar bütün SDK'larda aynıdır.
 */
internal object RevenueEvent {
    const val NAME = "feralin_purchase"
    /** JS güvenli tam sayı üst sınırı; sunucu bigint taşır. */
    const val MAX_AMOUNT_MINOR = (1L shl 53) - 1
    const val MAX_QUANTITY = 100_000
    private val CURRENCY = Regex("^[A-Z]{3}$")

    // İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
    private val RESERVED_KEYS = listOf("verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt")

    /** Gelir olayının özelliklerini kurar; sözleşme dışı girdide null döner (olay üretilmez). */
    fun properties(input: RevenueInput): Map<String, Any?>? {
        if (input.transactionId.isEmpty() || input.transactionId.length > 128) return null
        if (input.amountMinor < 0 || input.amountMinor > MAX_AMOUNT_MINOR) return null
        if (!CURRENCY.matches(input.currency)) return null
        val productId = input.productId
        if (productId != null && (productId.isEmpty() || productId.length > 128)) return null
        if (input.quantity < 0 || input.quantity > MAX_QUANTITY) return null
        // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
        if (input.purchaseType == PurchaseType.SUBSCRIPTION_CANCEL && input.amountMinor != 0L) return null
        val receipt = input.receipt
        if (receipt != null && (receipt.token.isEmpty() || receipt.token.length > 8192)) return null
        val out = LinkedHashMap<String, Any?>()
        input.properties?.let { out.putAll(it) }
        for (key in RESERVED_KEYS) out.remove(key)
        out["transaction_id"] = input.transactionId
        out["amount_minor"] = input.amountMinor
        out["currency"] = input.currency
        out["quantity"] = input.quantity
        out["purchase_type"] = input.purchaseType.wire
        if (productId != null) out["product_id"] = productId
        if (receipt != null) out["receipt"] = mapOf("provider" to receipt.provider.wire, "token" to receipt.token)
        return out
    }
}

internal val PurchaseType.wire: String
    get() = when (this) {
        PurchaseType.PURCHASE -> "purchase"
        PurchaseType.SUBSCRIPTION_START -> "subscription_start"
        PurchaseType.SUBSCRIPTION_RENEW -> "subscription_renew"
        PurchaseType.SUBSCRIPTION_CANCEL -> "subscription_cancel"
    }

internal val Receipt.Provider.wire: String
    get() = when (this) {
        Receipt.Provider.APPLE -> "apple"
        Receipt.Provider.GOOGLE -> "google"
        Receipt.Provider.STRIPE -> "stripe"
    }
