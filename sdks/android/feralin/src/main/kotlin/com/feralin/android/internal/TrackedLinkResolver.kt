package com.feralin.android.internal

import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

/**
 * E-posta servis sağlayıcısının (ESP: SendGrid, Iterable, Braze, Klaviyo, SFMC…) tıklama izleme adresini çözer (Adjust karşılaştırması
 * madde 15). ESP, e-postadaki Feralin kısa linkini kendi tıklama alanına sarar; uygulama App Link ile bu sarılı adresle açılır ve hedefi
 * bilemez. Çözücü yönlendirmeleri İZLEMEDEN tek tek okur (en çok [MAX_HOPS] adım): her adımda yalnız `Location` başlığına bakılır,
 * gövde indirilmez. Yalnız https adresler izlenir. Çözülemezse özgün adres döner; uygulama yine kendi yolunu izleyebilir.
 *
 * ESP tıklamayı bu istekle kaydeder: uygulama açılışı ESP raporunda da tıklama olarak görünür (Adjust ve ESP'lerin önerdiği davranış).
 */
internal class TrackedLinkResolver(
    private val open: (String) -> Hop = ::request,
) {
    /** Bir adımın sonucu: durum kodu ve (varsa) `Location` başlığı. */
    data class Hop(val status: Int, val location: String?)

    fun resolve(url: String): String {
        var current = url
        repeat(MAX_HOPS) {
            if (!current.startsWith("https://")) return current
            val hop = try {
                open(current)
            } catch (t: Throwable) {
                return current
            }
            if (hop.status !in 300..399 || hop.location.isNullOrBlank()) return current
            current = try {
                URI(current).resolve(hop.location.trim()).toString()
            } catch (t: Throwable) {
                return current
            }
        }
        return current
    }

    companion object {
        const val MAX_HOPS = 4
        private const val TIMEOUT_MS = 5_000

        private fun request(url: String): Hop {
            val connection = URL(url).openConnection() as HttpURLConnection
            return try {
                connection.instanceFollowRedirects = false
                connection.requestMethod = "GET"
                connection.connectTimeout = TIMEOUT_MS
                connection.readTimeout = TIMEOUT_MS
                connection.setRequestProperty("User-Agent", "feralin-android-link-resolver")
                Hop(connection.responseCode, connection.getHeaderField("Location"))
            } finally {
                connection.disconnect()
            }
        }
    }
}

/**
 * Push bildirimi açılışı (madde 15): bildirim verisindeki kampanya alanları `fr_push_open` olayına taşınır. Yalnız bu kapalı listedeki
 * anahtarlar okunur; bildirimin başlığı, gövdesi ve öteki verisi gitmez. Kaldırma ölçümü bildirimi (`fr_uninstall_check`) açılış sayılmaz.
 */
internal object PushOpen {
    const val EVENT = "fr_push_open"
    private val KEYS = listOf("utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "fr_push_id")
    private val VALUE = Regex("^[^\\p{Cntrl}]{1,128}$")

    fun properties(data: Map<String, String>): Map<String, Any?>? {
        if (data[FeralinEngine.UNINSTALL_CHECK_KEY] == "1") return null
        val props = LinkedHashMap<String, Any?>()
        for (key in KEYS) {
            val value = data[key]?.trim() ?: continue
            if (VALUE.matches(value)) props[if (key == "fr_push_id") "push_id" else key] = value
        }
        // Kampanya bilgisi olmayan bildirim de açılış olarak sayılır; kaynak "push" olur.
        if (!props.containsKey("utm_medium")) props["utm_medium"] = "push"
        return props
    }
}
