package com.feralin.kmp

/** `trackRevenue` sözleşmesinin tek olay adı (F5-E04-T01); defter yalnız bu olaydan beslenir. */
const val REVENUE_EVENT_NAME: String = "feralin_purchase"

/** Küçük birimde tutarın üst sınırı (JS güvenli tam sayısı, 2^53-1); sunucu bigint taşır. */
const val MAX_AMOUNT_MINOR: Long = 9_007_199_254_740_991L

/** Satın alma türü; [wire] tel üzerindeki değerdir. */
enum class PurchaseType(val wire: String) {
    PURCHASE("purchase"),
    SUBSCRIPTION_START("subscription_start"),
    SUBSCRIPTION_RENEW("subscription_renew"),
    SUBSCRIPTION_CANCEL("subscription_cancel"),
}

/** Makbuz sağlayıcısı; [wire] tel üzerindeki değerdir. */
enum class ReceiptProvider(val wire: String) {
    APPLE("apple"),
    GOOGLE("google"),
    STRIPE("stripe"),
}

/** İsteğe bağlı ham makbuz; toplayıcı yalnız sağlayıcı adını ve belirtecin SHA-256 özetini saklar. */
data class Receipt(val provider: ReceiptProvider, val token: String) {
    // Belirteç günlüğe düşmesin.
    override fun toString(): String = "Receipt(provider=${provider.wire})"
}

/**
 * `trackRevenue` girdisi. İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar, aksi hâlde
 * ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez.
 */
data class Revenue(
    /** Mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz (1-128 karakter); sunucu aynı işlemi ikinci kez saymaz. */
    val transactionId: String,
    /** Küçük birimde satır toplamı: 49,99 TL için 4999. Ondalık yoktur; [quantity] ile çarpılmaz. Abonelik iptalinde 0. */
    val amountMinor: Long,
    /** ISO 4217, üç büyük harf. */
    val currency: String,
    /** Verilirse 1-128 karakter. */
    val productId: String? = null,
    /** Bilgi amaçlı adet, 0-100000. */
    val quantity: Int = 1,
    val purchaseType: PurchaseType = PurchaseType.PURCHASE,
    val receipt: Receipt? = null,
    /** Ek özellikler; `verified` ve türevleri düşürülür. */
    val properties: Map<String, Any?>? = null,
)

// İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
private val REVENUE_RESERVED_KEYS = listOf("verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt")
private val CURRENCY = Regex("^[A-Z]{3}$")

/**
 * Gelir girdisini sözleşme özelliklerine çevirir; geçersiz girdide null döner (olay üretilmez). Kurallar bütün SDK'larda aynıdır
 * (Web `buildRevenueProperties`): transaction_id 1..128, amount_minor 0..2^53-1, currency ^[A-Z]{3}$, quantity 0..100000, iptal tutarı 0,
 * makbuz belirteci 1..8192.
 */
fun revenueProperties(input: Revenue): Map<String, Any?>? {
    if (input.transactionId.isEmpty() || input.transactionId.length > 128) return null
    if (input.amountMinor < 0 || input.amountMinor > MAX_AMOUNT_MINOR) return null
    if (!CURRENCY.matches(input.currency)) return null
    val productId = input.productId
    if (productId != null && (productId.isEmpty() || productId.length > 128)) return null
    if (input.quantity < 0 || input.quantity > 100_000) return null
    // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
    if (input.purchaseType == PurchaseType.SUBSCRIPTION_CANCEL && input.amountMinor != 0L) return null
    val receipt = input.receipt
    if (receipt != null && (receipt.token.isEmpty() || receipt.token.length > 8192)) return null

    val props = LinkedHashMap<String, Any?>()
    input.properties?.let { props.putAll(it) }
    for (key in REVENUE_RESERVED_KEYS) props.remove(key)
    props["transaction_id"] = input.transactionId
    props["amount_minor"] = input.amountMinor
    props["currency"] = input.currency
    props["quantity"] = input.quantity
    props["purchase_type"] = input.purchaseType.wire
    if (productId != null) props["product_id"] = productId
    if (receipt != null) props["receipt"] = mapOf("provider" to receipt.provider.wire, "token" to receipt.token)
    return props
}
