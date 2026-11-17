package com.feralin.android

/** Reklam biçimi (`ad_format`). */
public enum class AdFormat {
    BANNER,
    INTERSTITIAL,
    REWARDED,
    REWARDED_INTERSTITIAL,
    NATIVE,
    APP_OPEN,
    OTHER,
}

/** Reklam ağının bildirdiği gelir kesinliği (`precision`); istemci beyanıdır, doğrulama sınıfı değildir. */
public enum class AdPrecision {
    ESTIMATED,
    PUBLISHER_PROVIDED,
    PRECISE,
    UNKNOWN,
}

/**
 * `trackAdRevenue` girdisi (X4): tek reklam gösteriminin geliri (ör. AdMob `OnPaidEventListener`, AppLovin MAX `onAdRevenuePaid`).
 * Satın alma gelirinden (`trackRevenue`) ve reklam harcamasından ayrı bir gelir sınıfıdır; istemci beyanıdır ve sunucuda ESTIMATED kalır.
 */
public data class AdRevenueInput(
    /** Reklam ağı, küçük harf ve alt çizgi: `admob`, `applovin_max`, `ironsource`, `unity_ads`. */
    val network: String,
    val adFormat: AdFormat,
    /** Tek gösterim geliri, para biriminin milyonda biri: 0,0125 USD için 12500. Ondalık yoktur. */
    val revenueMicros: Long,
    /** ISO 4217, üç büyük harf. */
    val currency: String,
    val adUnit: String? = null,
    val precision: AdPrecision = AdPrecision.UNKNOWN,
    val placement: String? = null,
    /** Ağın gösterim kimliği; verilirse aynı gösterim ikinci kez sayılmaz. */
    val impressionId: String? = null,
    /** Ek özellikler; `verified` ve türevleri düşürülür. */
    val properties: Map<String, Any?>? = null,
)
