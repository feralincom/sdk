package com.feralin.android.internal

import com.feralin.android.Consent
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** Olaya eklenen bağlam: IP, reklam kimliği, cihaz modeli, ekran veya başka parmak izi alanı içermez. */
internal data class AppContext(
    val locale: String?,
    val timezone: String?,
    val appVersion: String?,
    val appBuild: String?,
)

internal data class EventFields(
    val eventId: String,
    val eventName: String,
    val occurredAtMs: Long,
    val sdkName: String,
    val sdkVersion: String,
    val anonymousId: String?,
    val sessionId: String?,
    val userId: String?,
    val consent: Consent,
    val properties: Map<String, Any?>,
    val pageUrl: String?,
    val app: AppContext,
    val platform: String = "android",
)

/** UTP v1 kodlaması (`packages/schemas/utp/v1/event.schema.json`). */
internal object EventJson {
    const val MAX_PROPERTIES = 100
    private const val MAX_DEPTH = 8
    private val PROPERTY_NAME = Regex("^[a-zA-Z][a-zA-Z0-9_]{0,63}$")
    private val EVENT_NAME = Regex("^[a-z][a-z0-9_]*$")
    private val ATTRIBUTION_EVENTS = setOf("app_first_open", "deep_link_opened")
    private val UTM_KEYS = listOf("utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content")

    fun isValidEventName(name: String): Boolean = name.length <= 100 && EVENT_NAME.matches(name)

    fun formatTime(ms: Long): String {
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT)
        format.timeZone = TimeZone.getTimeZone("UTC")
        return format.format(Date(ms))
    }

    /** Geçersiz anahtarı ve serileştirilemeyen değeri atar, 100 özellikte keser, çağıranın haritasını kopyalar. */
    fun sanitize(properties: Map<String, Any?>?): Map<String, Any?> {
        if (properties.isNullOrEmpty()) return emptyMap()
        val out = LinkedHashMap<String, Any?>()
        for ((key, value) in properties) {
            if (out.size >= MAX_PROPERTIES) break
            if (!PROPERTY_NAME.matches(key)) continue
            val clean = sanitizeValue(value, 0)
            if (clean !== Dropped && clean != null) out[key] = clean
        }
        return out
    }

    private object Dropped

    private fun sanitizeValue(value: Any?, depth: Int): Any? = when {
        depth > MAX_DEPTH -> Dropped
        value == null -> null
        value is String || value is Boolean -> value
        value is Double -> if (value.isNaN() || value.isInfinite()) Dropped else value
        value is Float -> if (value.isNaN() || value.isInfinite()) Dropped else value.toDouble()
        value is Number -> value
        value is Map<*, *> -> LinkedHashMap<String, Any?>().also { out ->
            for ((k, v) in value) {
                if (k !is String) continue
                val clean = sanitizeValue(v, depth + 1)
                if (clean !== Dropped) out[k] = clean
            }
        }
        value is Collection<*> -> value.map { sanitizeValue(it, depth + 1) }.filter { it !== Dropped }
        else -> Dropped
    }

    fun encode(fields: EventFields): String {
        val root = JSONObject()
        root.put("event_id", fields.eventId)
        root.put("event_name", fields.eventName)
        root.put("occurred_at", formatTime(fields.occurredAtMs))
        root.put("platform", fields.platform)
        root.put("schema_version", 1)
        root.put("sdk", JSONObject().put("name", fields.sdkName).put("version", fields.sdkVersion))
        fields.anonymousId?.let { root.put("anonymous_id", it) }
        fields.sessionId?.let { root.put("session_id", it) }
        fields.userId?.let { root.put("user_id", it) }
        if (fields.properties.isNotEmpty()) root.put("properties", toJson(fields.properties))
        root.put("consent", encodeConsent(fields.consent))
        root.put("context", encodeContext(fields))
        return root.toString()
    }

    /**
     * Reklam ölçümü izni kalktığında bekleyen olayı kanıtsız hale getirir. İlk açılış ve bağlantı açılışı sayılmaya devam eder: tıklama kimliği,
     * UTM ve kaynak silinir, izin bloğu güncel karara çekilir. Yalnız kanıt taşıyan follow-up olayının başka içeriği yoktur, `null` döner ve atılır.
     * Çözülemeyen gövde kanıt taşıyabileceği için de `null` döner.
     */
    fun withoutAttribution(payload: String, consent: Consent): String? {
        val root = try {
            JSONObject(payload)
        } catch (_: Exception) {
            return null
        }
        val properties = root.optJSONObject("properties")
        if (properties?.optBoolean("consent_followup", false) == true) return null
        val attributionEvent = root.optString("event_name") in ATTRIBUTION_EVENTS
        if (!attributionEvent && properties?.has("fr_click") != true) return payload
        properties?.remove("fr_click")
        if (attributionEvent) {
            UTM_KEYS.forEach { properties?.remove(it) }
            properties?.remove("first_open_at")
            if (properties?.has("attribution_source") == true) properties.put("attribution_source", "none")
            root.put("consent", encodeConsent(consent))
        }
        if (properties != null && properties.length() == 0) root.remove("properties")
        return root.toString()
    }

    private fun encodeConsent(consent: Consent): JSONObject {
        val out = JSONObject().put("analytics", consent.analytics)
        consent.advertising?.let { out.put("advertising", it) }
        consent.personalization?.let { out.put("personalization", it) }
        consent.sessionReplay?.let { out.put("session_replay", it) }
        return out
    }

    private fun encodeContext(fields: EventFields): JSONObject {
        val out = JSONObject()
        fields.pageUrl?.let { out.put("page_url", it) }
        fields.app.locale?.takeIf { it.length <= 16 }?.let { out.put("locale", it) }
        fields.app.timezone?.takeIf { it.length <= 64 }?.let { out.put("timezone", it) }
        val app = JSONObject()
        fields.app.appVersion?.takeIf { it.length <= 32 }?.let { app.put("version", it) }
        fields.app.appBuild?.takeIf { it.length <= 32 }?.let { app.put("build", it) }
        if (app.length() > 0) out.put("app", app)
        return out
    }

    private fun toJson(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().also { obj -> value.forEach { (k, v) -> obj.put(k as String, toJson(v)) } }
        is Collection<*> -> JSONArray().also { arr -> value.forEach { arr.put(toJson(it)) } }
        else -> value
    }

    /** Depodaki JSON metinlerinden yeniden ayrıştırmadan batch gövdesi kurar. */
    fun batchBody(sentAtMs: Long, events: List<StoredEvent>): String {
        val builder = StringBuilder(events.sumOf { it.payload.length } + 64)
        builder.append("{\"sent_at\":\"").append(formatTime(sentAtMs)).append("\",\"events\":[")
        events.forEachIndexed { index, event ->
            if (index > 0) builder.append(',')
            builder.append(event.payload)
        }
        builder.append("]}")
        return builder.toString()
    }
}
