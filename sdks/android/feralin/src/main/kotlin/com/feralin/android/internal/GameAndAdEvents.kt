package com.feralin.android.internal

import com.feralin.android.AdFormat
import com.feralin.android.AdPrecision
import com.feralin.android.AdRevenueInput

/**
 * Oyun olayları ve `fr_ad_revenue` sözleşmesi (X4). Kurallar `packages/schemas/utp/v1/game-events.md` ve olay şemasıyla aynıdır; sözleşme dışı
 * girdide null döner ve olay üretilmez. Oyun ekonomisi sanal para birimidir (gerçek gelir değildir). Reklam geliri satın alma gelirinden
 * (`feralin_purchase`) ve reklam harcamasından ayrı bir gelir sınıfıdır; istemci beyanıdır ve sunucuda ESTIMATED kalır.
 */
internal object GameEvents {
    const val LEVEL_START = "level_start"
    const val LEVEL_COMPLETE = "level_complete"
    const val LEVEL_FAIL = "level_fail"
    const val ECONOMY_SOURCE = "economy_source"
    const val ECONOMY_SINK = "economy_sink"
    const val REWARDED_SHOWN = "rewarded_ad_shown"
    const val REWARDED_COMPLETE = "rewarded_ad_complete"
    const val IAP_OFFER_SHOWN = "iap_offer_shown"
    const val IAP_INITIATED = "iap_initiated"

    const val MAX_AMOUNT = 1_000_000_000_000L
    private const val MAX_DURATION_MS = 86_400_000L
    private const val MAX_NUMBER = (1L shl 53) - 1

    private fun text(value: String?, max: Int): Boolean = value != null && value.isNotEmpty() && value.length <= max

    private fun LinkedHashMap<String, Any?>.putText(key: String, value: String?, max: Int): Boolean {
        if (value == null) return true
        if (!text(value, max)) return false
        put(key, value)
        return true
    }

    private fun LinkedHashMap<String, Any?>.putNumber(key: String, value: Long?, min: Long, max: Long): Boolean {
        if (value == null) return true
        if (value < min || value > max) return false
        put(key, value)
        return true
    }

    private fun level(levelId: String, attempt: Long?, score: Long?, durationMs: Long?, failReason: String?): Map<String, Any?>? {
        if (!text(levelId, 64)) return null
        val out = LinkedHashMap<String, Any?>()
        out["level_id"] = levelId
        if (!out.putNumber("attempt", attempt, 1, MAX_NUMBER)) return null
        if (!out.putNumber("score", score, 0, MAX_NUMBER)) return null
        if (!out.putNumber("duration_ms", durationMs, 0, MAX_DURATION_MS)) return null
        if (!out.putText("fail_reason", failReason, 64)) return null
        return out
    }

    fun levelStart(levelId: String, attempt: Long?): Map<String, Any?>? = level(levelId, attempt, null, null, null)
    fun levelComplete(levelId: String, attempt: Long?, score: Long?, durationMs: Long?): Map<String, Any?>? = level(levelId, attempt, score, durationMs, null)
    fun levelFail(levelId: String, attempt: Long?, score: Long?, durationMs: Long?, failReason: String?): Map<String, Any?>? = level(levelId, attempt, score, durationMs, failReason)

    /** `economy_source` ve `economy_sink`: oyun içi para birimi adı ve 1..10^12 miktar. */
    fun economy(currencyName: String, amount: Long, reason: String?, itemId: String?): Map<String, Any?>? {
        if (!text(currencyName, 64) || amount < 1 || amount > MAX_AMOUNT) return null
        val out = LinkedHashMap<String, Any?>()
        out["currency_name"] = currencyName
        out["amount"] = amount
        if (!out.putText("reason", reason, 64)) return null
        if (!out.putText("item_id", itemId, 64)) return null
        return out
    }

    fun rewardedShown(placement: String, network: String?): Map<String, Any?>? {
        if (!text(placement, 64)) return null
        val out = LinkedHashMap<String, Any?>()
        out["placement"] = placement
        if (!out.putText("network", network, 64)) return null
        return out
    }

    fun rewardedComplete(placement: String, network: String?, rewardAmount: Long?, rewardCurrency: String?): Map<String, Any?>? {
        val out = LinkedHashMap(rewardedShown(placement, network) ?: return null)
        if (!out.putNumber("reward_amount", rewardAmount, 0, MAX_NUMBER)) return null
        if (!out.putText("reward_currency", rewardCurrency, 64)) return null
        return out
    }

    fun iapOfferShown(productId: String, placement: String?): Map<String, Any?>? {
        if (!text(productId, 128)) return null
        val out = LinkedHashMap<String, Any?>()
        out["product_id"] = productId
        if (!out.putText("placement", placement, 64)) return null
        return out
    }

    fun iapInitiated(productId: String, placement: String?, transactionId: String?): Map<String, Any?>? {
        val out = LinkedHashMap(iapOfferShown(productId, placement) ?: return null)
        if (!out.putText("transaction_id", transactionId, 128)) return null
        return out
    }
}

internal object AdRevenueEvent {
    const val NAME = "fr_ad_revenue"
    const val MAX_REVENUE_MICROS = (1L shl 53) - 1
    private val CURRENCY = Regex("^[A-Z]{3}$")
    private val NETWORK = Regex("^[a-z][a-z0-9_]{0,63}$")

    // İstemci doğrulama beyan edemez; toplayıcı da düşürür.
    private val RESERVED_KEYS = listOf("verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt")

    /** Reklam gösterimi gelirinin özellikleri; sözleşme dışı girdide null. Tutar para biriminin milyonda biri, tam sayı. */
    fun properties(input: AdRevenueInput): Map<String, Any?>? {
        if (!NETWORK.matches(input.network)) return null
        if (input.revenueMicros < 0 || input.revenueMicros > MAX_REVENUE_MICROS) return null
        if (!CURRENCY.matches(input.currency)) return null
        val adUnit = input.adUnit
        if (adUnit != null && (adUnit.isEmpty() || adUnit.length > 128)) return null
        val placement = input.placement
        if (placement != null && (placement.isEmpty() || placement.length > 64)) return null
        val impressionId = input.impressionId
        if (impressionId != null && (impressionId.isEmpty() || impressionId.length > 128)) return null
        val out = LinkedHashMap<String, Any?>()
        input.properties?.let { out.putAll(it) }
        for (key in RESERVED_KEYS) out.remove(key)
        out["network"] = input.network
        out["ad_format"] = input.adFormat.wire
        out["revenue_micros"] = input.revenueMicros
        out["currency"] = input.currency
        out["precision"] = input.precision.wire
        if (adUnit != null) out["ad_unit"] = adUnit
        if (placement != null) out["placement"] = placement
        if (impressionId != null) out["impression_id"] = impressionId
        return out
    }
}

internal val AdFormat.wire: String
    get() = when (this) {
        AdFormat.BANNER -> "banner"
        AdFormat.INTERSTITIAL -> "interstitial"
        AdFormat.REWARDED -> "rewarded"
        AdFormat.REWARDED_INTERSTITIAL -> "rewarded_interstitial"
        AdFormat.NATIVE -> "native"
        AdFormat.APP_OPEN -> "app_open"
        AdFormat.OTHER -> "other"
    }

internal val AdPrecision.wire: String
    get() = when (this) {
        AdPrecision.ESTIMATED -> "estimated"
        AdPrecision.PUBLISHER_PROVIDED -> "publisher_provided"
        AdPrecision.PRECISE -> "precise"
        AdPrecision.UNKNOWN -> "unknown"
    }
