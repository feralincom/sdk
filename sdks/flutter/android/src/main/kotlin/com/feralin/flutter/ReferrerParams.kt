package com.feralin.flutter

import java.net.URLDecoder

/**
 * Play Install Referrer dizgisini izin listesiyle süzer; ham dizgi Dart'a geçmez, saklanmaz ve loglanmaz.
 * Bilinmeyen parametre okunmaz. Değer doğrulaması Dart tarafında aynı kurallarla yinelenir.
 */
internal object ReferrerParams {
    private val ALLOWED = setOf("fr_click", "fr_dl", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content")

    fun parse(raw: String?): Map<String, String> {
        if (raw.isNullOrBlank()) return emptyMap()
        val text = if (!raw.contains('=') && raw.contains("%3D", ignoreCase = true)) decode(raw) ?: raw else raw
        val out = LinkedHashMap<String, String>()
        for (pair in text.split('&')) {
            val eq = pair.indexOf('=')
            if (eq <= 0) continue
            val key = decode(pair.substring(0, eq)) ?: continue
            if (key !in ALLOWED || key in out) continue
            val value = decode(pair.substring(eq + 1))?.trim().orEmpty()
            if (value.isNotEmpty()) out[key] = value
        }
        return out
    }

    private fun decode(text: String): String? = try {
        URLDecoder.decode(text, "UTF-8")
    } catch (_: IllegalArgumentException) {
        null
    }
}
