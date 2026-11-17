package com.feralin.kmp

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Reklam izni yoksa olaydan çıkarılan özellik. */
const val ATTRIBUTION_CLICK_PROPERTY: String = "fr_click"

internal const val MAX_EVENT_NAME_LENGTH = 100
internal const val MAX_PROPERTIES = 100
internal const val MAX_IDENTIFIER_LENGTH = 128
internal const val MAX_VALUE_DEPTH = 32

/** İzin anlık görüntüsü. [analytics] false ise hiçbir olay üretilmez. Varsayılan hepsi kapalıdır. */
data class Consent(
    val analytics: Boolean = false,
    val advertising: Boolean = false,
    val personalization: Boolean = false,
    val sessionReplay: Boolean = false,
) {
    internal fun toJson(): JsonObject = buildJsonObject {
        put("analytics", analytics)
        put("advertising", advertising)
        put("personalization", personalization)
        put("session_replay", sessionReplay)
    }
}

data class Screen(val width: Int, val height: Int)

data class AppInfo(val version: String? = null, val build: String? = null)

/** Şemadaki `context` nesnesi; yalnız dolu alanlar gönderilir. SDK cihazdan kendiliğinden context toplamaz. */
data class EventContext(
    val pageUrl: String? = null,
    val pageTitle: String? = null,
    val referrer: String? = null,
    val locale: String? = null,
    val timezone: String? = null,
    val screen: Screen? = null,
    val app: AppInfo? = null,
) {
    internal fun toJson(): JsonObject = buildJsonObject {
        pageUrl?.takeIf { it.isNotEmpty() }?.let { put("page_url", it) }
        pageTitle?.takeIf { it.isNotEmpty() }?.let { put("page_title", it) }
        referrer?.takeIf { it.isNotEmpty() }?.let { put("referrer", it) }
        locale?.takeIf { it.isNotEmpty() }?.let { put("locale", it) }
        timezone?.takeIf { it.isNotEmpty() }?.let { put("timezone", it) }
        screen?.let { value ->
            put("screen", buildJsonObject {
                put("width", value.width)
                put("height", value.height)
            })
        }
        app?.let { value ->
            val info = buildJsonObject {
                value.version?.takeIf { it.isNotEmpty() }?.let { put("version", it) }
                value.build?.takeIf { it.isNotEmpty() }?.let { put("build", it) }
            }
            if (info.isNotEmpty()) put("app", info)
        }
    }
}

/** Kuyruğa giren olay: [payload] tel üzerinde giden JSON'dur. */
data class TrackedEvent(val eventId: String, val payload: JsonObject)

/** Bir `flush` çağrısının toplu sonucu. */
data class FlushResult(
    val sent: Int = 0,
    val accepted: Int = 0,
    val rejected: Int = 0,
    val batchId: String? = null,
    val status: Int = 0,
    val retained: Int = 0,
    val error: DeliveryError? = null,
) {
    val ok: Boolean get() = error == null
}

/** Anlık durum (debug ve sağlık amaçlı). Anahtar yoktur. */
data class ClientStatus(
    val sdk: String,
    val version: String,
    val queued: Int,
    val dropped: Long,
    val consent: Consent,
    val userId: String?,
    val closed: Boolean,
    val backoffSeconds: Long,
    val endpoint: String,
)

/** Web, Node, .NET, Android ve Python SDK'larıyla aynı anahtar: sıralı tüm `event_id` değerlerinin FNV-1a 64 özeti ve sayı. */
fun idempotencyKeyFor(eventIds: List<String>): String {
    val ordered = eventIds.sorted()
    var value = 0xCBF29CE484222325uL
    for (byte in ordered.joinToString(",").encodeToByteArray()) {
        value = (value xor byte.toUByte().toULong()) * 0x100000001B3uL
    }
    return value.toString(16).padStart(16, '0') + "-" + ordered.size
}

internal fun validateEventName(name: String) {
    val valid = name.isNotEmpty() &&
        name.length <= MAX_EVENT_NAME_LENGTH &&
        name[0] in 'a'..'z' &&
        name.all { it in 'a'..'z' || it in '0'..'9' || it == '_' }
    if (!valid) throw FeralinException.InvalidEvent("event_name snake_case olmalı (^[a-z][a-z0-9_]*$, en fazla 100 karakter)")
}

internal fun validateIdentifier(value: String?, field: String): String? {
    if (value.isNullOrEmpty()) return null
    if (value.length > MAX_IDENTIFIER_LENGTH) throw FeralinException.InvalidEvent("$field en fazla 128 karakter olmalı")
    return value
}

/** Özellikleri doğrular ve JSON'a çevirir. Yalnız JSON'a birebir dönüşen türler kabul edilir. */
internal fun convertProperties(properties: Map<String, Any?>?): MutableMap<String, JsonElement> {
    val out = LinkedHashMap<String, JsonElement>()
    if (properties == null) return out
    if (properties.size > MAX_PROPERTIES) {
        throw FeralinException.InvalidEvent("properties en fazla 100 anahtar içerebilir (${properties.size} verildi)")
    }
    for ((key, value) in properties) {
        val valid = key.isNotEmpty() && key.length <= 64 && isAsciiLetter(key[0]) &&
            key.all { isAsciiLetter(it) || it in '0'..'9' || it == '_' }
        if (!valid) throw FeralinException.InvalidEvent("properties anahtarı ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ desenine uymalı")
        out[key] = toJsonElement(value)
    }
    return out
}

private fun isAsciiLetter(char: Char): Boolean = char in 'a'..'z' || char in 'A'..'Z'

private fun toJsonElement(value: Any?, depth: Int = 0): JsonElement {
    // Derinlik sınırı döngüsel yapıyı da yakalar: yoksa StackOverflowError (Error) uygulamayı düşürürdü. Java ve Ruby ile aynı sınır.
    if (depth > MAX_VALUE_DEPTH) throw FeralinException.InvalidEvent("properties değeri en fazla $MAX_VALUE_DEPTH düzey iç içe olabilir")
    return when (value) {
        null -> JsonNull
        is JsonElement -> value
        is String -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        is Double -> {
            if (value.isNaN() || value.isInfinite()) throw FeralinException.InvalidEvent("NaN ve sonsuz değer JSON'a dönüşmez")
            JsonPrimitive(value)
        }
        is Float -> {
            if (value.isNaN() || value.isInfinite()) throw FeralinException.InvalidEvent("NaN ve sonsuz değer JSON'a dönüşmez")
            JsonPrimitive(value)
        }
        is Number -> JsonPrimitive(value)
        is Map<*, *> -> JsonObject(
            value.entries.associate { (key, item) ->
                if (key !is String) throw FeralinException.InvalidEvent("iç içe nesne anahtarı metin olmalı")
                key to toJsonElement(item, depth + 1)
            },
        )
        is List<*> -> JsonArray(value.map { toJsonElement(it, depth + 1) })
        else -> throw FeralinException.InvalidEvent("desteklenmeyen özellik türü")
    }
}

/** UTC RFC3339, milisaniye hassasiyeti (ör. 2026-11-03T10:00:00.123Z). Tarih kütüphanesi eklememek için takvim hesabı burada. */
internal fun formatTime(epochMillis: Long): String {
    val days = epochMillis.floorDiv(86_400_000L)
    val rest = epochMillis.mod(86_400_000L)
    val (year, month, day) = civilFromDays(days)
    val hour = rest / 3_600_000L
    val minute = rest % 3_600_000L / 60_000L
    val second = rest % 60_000L / 1000L
    val millis = rest % 1000L
    return year.toString().padStart(4, '0') + "-" + pad(month, 2) + "-" + pad(day, 2) + "T" +
        pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2) + "." + pad(millis, 3) + "Z"
}

private fun pad(value: Long, width: Int): String = value.toString().padStart(width, '0')

/** Gün sayısından proleptik Gregoryen takvim tarihi (Howard Hinnant'ın `civil_from_days` algoritması). */
private fun civilFromDays(days: Long): Triple<Long, Long, Long> {
    val z = days + 719_468L
    val era = z.floorDiv(146_097L)
    val doe = z.mod(146_097L)
    val yoe = (doe - doe / 1460L + doe / 36_524L - doe / 146_096L) / 365L
    val doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
    val mp = (5L * doy + 2L) / 153L
    val day = doy - (153L * mp + 2L) / 5L + 1L
    val month = if (mp < 10L) mp + 3L else mp - 9L
    val year = yoe + era * 400L + if (month <= 2L) 1L else 0L
    return Triple(year, month, day)
}
