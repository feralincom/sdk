package com.feralin.android.internal

import java.net.URI
import java.net.URLDecoder

/** Sözleşmedeki `properties.attribution_source` değerleri. */
internal object AttributionSource {
    const val PLAY_INSTALL_REFERRER = "play_install_referrer"
    const val HUAWEI_INSTALL_REFERRER = "huawei_install_referrer"
    const val SAMSUNG_INSTALL_REFERRER = "samsung_install_referrer"
    const val APP_LINK = "app_link"
    const val NONE = "none"
}

/** Referrer veya URL'den alınmasına izin verilen tek veri: `fr_click` ve standart `utm_*`. */
internal data class AttributionParams(
    val frClick: String?,
    val utm: Map<String, String>,
    val deepLinkPath: String? = null,
    /** Yönlendiricinin okunduğu mağaza; olayın `attribution_source` değeri olur. */
    val source: String = AttributionSource.PLAY_INSTALL_REFERRER,
) {
    val isEmpty: Boolean get() = frClick == null && utm.isEmpty()

    /** Play'in tıklama yokken döndürdüğü varsayılan (`organic` / `(not set)`) kanıt sayılmaz. */
    val isPlayOrganicDefault: Boolean
        get() = frClick == null &&
            (utm["utm_medium"].equals("organic", ignoreCase = true) || utm["utm_source"] == "(not set)")

    fun writeTo(target: MutableMap<String, Any?>) {
        frClick?.let { target["fr_click"] = it }
        target.putAll(utm)
    }

    companion object {
        val EMPTY = AttributionParams(null, emptyMap())
        private const val FR_CLICK = "fr_click"
        private const val FR_DEEP_LINK = "fr_dl"
        private const val MAX_DEEP_LINK_LENGTH = 200
        // Link-router ve saas-api ile aynı kural: şema ve host taşıyamaz, yalnız uygulama içi yol.
        private val DEEP_LINK_PATTERN = Regex("^/[A-Za-z0-9._~!$'()*+,;=:@%/?&-]*$")

        // Kodlanmış nokta, bölü, ters bölü, kontrol karakteri ya da bozuk kaçış: `%2e%2e` URL birleştirmede üst dizine çıkar.
        private val DEEP_LINK_UNSAFE_ESCAPE = Regex("%(?:2e|2f|5c|0[0-9a-f]|1[0-9a-f]|7f|[^0-9a-f]|[0-9a-f](?:[^0-9a-f]|$)|$)", RegexOption.IGNORE_CASE)
        private const val MAX_VALUE_LENGTH = 256
        private val UTM_KEYS = setOf("utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content")
        private val FR_CLICK_PATTERN = Regex("^[A-Za-z0-9._~-]{1,256}$")

        /**
         * `a=b&c=d` dizgisini izin listesiyle ayrıştırır. Bilinmeyen parametre okunmaz ve hiçbir yerde saklanmaz.
         * Bozuk kodlanmış parça yok sayılır; aynı anahtarın ilk değeri geçerlidir.
         */
        fun parseQuery(raw: String?): AttributionParams {
            if (raw.isNullOrBlank()) return EMPTY
            // Bazı kampanya araçları referrer'ın tamamını bir kez daha kodlar.
            val text = if (!raw.contains('=') && raw.contains("%3D", ignoreCase = true)) decode(raw) ?: raw else raw
            var frClick: String? = null
            var deepLinkPath: String? = null
            val utm = LinkedHashMap<String, String>()
            for (pair in text.split('&')) {
                val eq = pair.indexOf('=')
                if (eq <= 0) continue
                val key = decode(pair.substring(0, eq)) ?: continue
                if (key != FR_CLICK && key != FR_DEEP_LINK && key !in UTM_KEYS) continue
                val value = decode(pair.substring(eq + 1))?.trim().orEmpty()
                if (value.isEmpty()) continue
                if (key == FR_CLICK) {
                    if (frClick == null && FR_CLICK_PATTERN.matches(value)) frClick = value
                } else if (key == FR_DEEP_LINK) {
                    if (deepLinkPath == null && isValidDeepLinkPath(value)) deepLinkPath = value
                } else if (key !in utm) {
                    utm[key] = value.take(MAX_VALUE_LENGTH)
                }
            }
            // Yol tıklama kimliğiyle birlikte gelir; kimliksiz değer Feralin linkinden gelmemiştir.
            return AttributionParams(frClick, utm, if (frClick != null) deepLinkPath else null)
        }

        private fun isValidDeepLinkPath(path: String): Boolean =
            path.length <= MAX_DEEP_LINK_LENGTH &&
                DEEP_LINK_PATTERN.matches(path) &&
                !path.startsWith("//") &&
                !DEEP_LINK_UNSAFE_ESCAPE.containsMatchIn(path) &&
                ".." !in path.substringBefore('?').split('/')

        private fun decode(text: String): String? = try {
            URLDecoder.decode(text, "UTF-8")
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}

/** Temizlenmiş derin bağlantı: yalnız scheme+host+path ile izin listesindeki parametreler kalır. */
internal data class DeepLink(val cleanUrl: String, val params: AttributionParams) {
    companion object {
        private const val MAX_URL_LENGTH = 2048

        /** Yalnız http(s) kabul edilir; App Link tanımı gereği özel şemalar kanıt sayılmaz. */
        fun parse(raw: String?): DeepLink? {
            if (raw.isNullOrBlank()) return null
            val uri = try {
                URI(raw)
            } catch (_: Exception) {
                return null
            }
            val scheme = uri.scheme?.lowercase() ?: return null
            if (scheme != "https" && scheme != "http") return null
            val host = uri.host ?: return null
            val port = if (uri.port != -1) ":${uri.port}" else ""
            val clean = "$scheme://$host$port${uri.rawPath.orEmpty()}"
            if (clean.length > MAX_URL_LENGTH) return null
            return DeepLink(clean, AttributionParams.parseQuery(uri.rawQuery))
        }
    }
}
