package com.feralin.reactnative

import com.feralin.android.Consent
import com.feralin.android.DeferredDeepLink
import com.feralin.android.DeferredDeepLinkStatus
import com.feralin.android.FeralinConfig
import com.feralin.android.FeralinStatus
import com.feralin.android.FlushResult
import com.feralin.android.SdkWrapper

/**
 * JS ile çekirdek arasındaki dönüşüm. React Native türlerini kullanmaz, saf JVM'de sınanır. Köprüden gelen sayılar
 * Double'dır; tam sayı alanları burada çevrilir. Dönüş haritaları anahtar içermez.
 */
internal object BridgeMapping {
    private const val WRAPPER_PLATFORM = "react_native"

    /** Geçersiz yapılandırmada `null`: çekirdek de reddederdi, köprü erken döner. */
    fun configFrom(map: Map<String, Any?>): FeralinConfig? {
        val projectKey = map["projectKey"] as? String ?: return null
        val collectUrl = map["collectUrl"] as? String ?: return null
        val defaults = FeralinConfig(projectKey, collectUrl)
        return defaults.copy(
            consent = consentFrom(map["consent"]),
            flushIntervalMs = longOf(map["flushIntervalMs"]) ?: defaults.flushIntervalMs,
            batchSize = longOf(map["batchSize"])?.toInt() ?: defaults.batchSize,
            queueLimit = longOf(map["queueLimit"])?.toInt() ?: defaults.queueLimit,
            sessionTimeoutMs = longOf(map["sessionTimeoutMs"]) ?: defaults.sessionTimeoutMs,
            autoCaptureDeepLinks = map["autoCaptureDeepLinks"] as? Boolean ?: defaults.autoCaptureDeepLinks,
            debug = map["debug"] as? Boolean ?: defaults.debug,
            // Kurulum eşleştirme kodu: çekirdek biçimi denetler ve ilk olaya `fr_install_code` olarak ekler.
            installCode = (map["installCode"] as? String)?.trim()?.takeIf { it.isNotEmpty() },
            wrapper = SdkWrapper(
                name = map["wrapperName"] as? String ?: "@feralin/react-native",
                version = map["wrapperVersion"] as? String ?: "0.0.0-dev",
                platform = WRAPPER_PLATFORM,
            ),
        )
    }

    /** `analytics` yoksa izin bilinmiyor sayılır; varsayılan olarak verilmiş kabul edilmez. */
    fun consentFrom(value: Any?): Consent? {
        val map = value as? Map<*, *> ?: return null
        val analytics = map["analytics"] as? Boolean ?: return null
        return Consent(
            analytics = analytics,
            advertising = map["advertising"] as? Boolean,
            personalization = map["personalization"] as? Boolean,
            sessionReplay = map["session_replay"] as? Boolean,
        )
    }

    fun consentToMap(consent: Consent): Map<String, Any?> = buildMap {
        put("analytics", consent.analytics)
        consent.advertising?.let { put("advertising", it) }
        consent.personalization?.let { put("personalization", it) }
        consent.sessionReplay?.let { put("session_replay", it) }
    }

    fun flushToMap(result: FlushResult): Map<String, Any?> = mapOf(
        "sent" to result.sent,
        "accepted" to result.accepted,
        "rejected" to result.rejected,
        "status" to result.status,
        "batchId" to result.batchId,
    )

    fun deferredDeepLinkToMap(link: DeferredDeepLink): Map<String, Any?> = mapOf(
        "status" to when (link.status) {
            DeferredDeepLinkStatus.DELIVERED -> "delivered"
            DeferredDeepLinkStatus.NONE -> "none"
            DeferredDeepLinkStatus.CONSENT_REQUIRED -> "consent_required"
            DeferredDeepLinkStatus.NOT_INITIALIZED -> "not_initialized"
        },
        "path" to link.path,
    )

    fun statusToMap(status: FeralinStatus): Map<String, Any?> = mapOf(
        "initialized" to status.initialized,
        "sdk" to status.sdk,
        "version" to status.version,
        "queued" to status.queued,
        "consent" to status.consent?.let(::consentToMap),
        "anonymousId" to status.anonymousId,
        "sessionId" to status.sessionId,
        "userId" to status.userId,
    )

    /** JSON'daki 3.0 değeri `3` olarak gitsin diye kesirsiz Double tam sayıya indirilir. */
    @Suppress("UNCHECKED_CAST")
    fun propertiesFrom(map: Map<String, Any?>?): Map<String, Any?>? = map?.mapValues { (_, value) -> normalize(value) }

    private fun normalize(value: Any?): Any? = when (value) {
        is Double -> if (value % 1.0 == 0.0 && value >= Long.MIN_VALUE.toDouble() && value <= Long.MAX_VALUE.toDouble()) value.toLong() else value
        is Map<*, *> -> value.entries.associate { (k, v) -> k.toString() to normalize(v) }
        is List<*> -> value.map(::normalize)
        else -> value
    }

    private fun longOf(value: Any?): Long? = (value as? Number)?.toLong()
}
