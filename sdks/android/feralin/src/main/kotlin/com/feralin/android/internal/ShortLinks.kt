package com.feralin.android.internal

import org.json.JSONObject
import java.net.URI
import java.net.URLEncoder

/**
 * Fera Fly kısa link çözümlemesi. Uygulama `https://marka.fera.fly/kod` gibi bir App Link ile doğrudan açıldığında Android yönlendiriciye
 * uğramaz; SDK aynı adresi `application/vnd.feralin.link+json` türüyle ister. Yönlendirici linkin derin yolunu, UTM'sini ve (izin varsa)
 * tıklama kimliğini döner; bu bilgi tarayıcı yönlendirmesinde zaten herkese açıktır.
 */
internal data class ResolvedShortLink(val code: String, val deepLinkPath: String?, val utm: Map<String, String>, val clickId: String?)

internal object ShortLinks {
    const val ACCEPT = "application/vnd.feralin.link+json"
    private val CLICK = Regex("^[A-Za-z0-9_-]{16,64}$")
    private val UTM_KEYS = setOf("source", "medium", "campaign", "term", "content")

    /** `https` ve host listedeki bir host ya da onun alt alanı. Benzer adlı host (`sahtefera.fly`) kabul edilmez. */
    fun isShortLink(raw: String?, hosts: List<String>): Boolean {
        if (raw.isNullOrBlank()) return false
        val uri = try { URI(raw) } catch (_: Exception) { return false }
        if (uri.scheme?.lowercase() != "https") return false
        val host = uri.host?.lowercase() ?: return false
        return hosts.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.any { host == it || host.endsWith(".$it") }
    }

    /**
     * Çözümleme isteğinin başlıkları. Kullanıcı-ajanı yalnız cihaz sınıfını (Android ve ana sürüm) verir, cihaz modeli gönderilmez. Reklam
     * ölçümü izni yoksa `Feralin-Attribution: off`: yönlendirici tıklamayı toplam sayar, IP içeren kanıt yazmaz.
     */
    fun headers(osVersion: String?, attribution: Boolean): Map<String, String> {
        val version = osVersion?.takeIf { it.matches(Regex("^[0-9.]{1,10}$")) } ?: "14"
        val headers = linkedMapOf("Accept" to ACCEPT, "User-Agent" to "FeralinSDK (Linux; Android $version)")
        if (!attribution) headers["Feralin-Attribution"] = "off"
        return headers
    }

    /** Yanıtı çözer; biçim bozuksa `null` (SDK çözümlemesiz açılışa düşer). */
    fun parse(body: String): ResolvedShortLink? = try {
        val json = JSONObject(body)
        val code = json.optString("code").takeIf { it.isNotEmpty() } ?: return null
        val path = if (json.isNull("deep_link_path")) null else json.optString("deep_link_path").takeIf { it.startsWith("/") && !it.startsWith("//") }
        val click = if (json.isNull("click_id")) null else json.optString("click_id").takeIf { CLICK.matches(it) }
        val utm = LinkedHashMap<String, String>()
        json.optJSONObject("utm")?.let { obj -> for (key in obj.keys()) if (key in UTM_KEYS) utm[key] = obj.optString(key) }
        ResolvedShortLink(code, path, utm, click)
    } catch (_: Exception) {
        null
    }

    /**
     * Çözülen linki mevcut derin bağlantı akışına verilecek adrese çevirir: aynı host, derin yol (yoksa `/`), `fr_click` ve `utm_*`. Böylece
     * izin kuralları (reklam izni yoksa tıklama kimliği gönderilmez) tek yerde, `handleLink` içinde uygulanır.
     */
    fun syntheticUrl(original: String, resolved: ResolvedShortLink): String? {
        val uri = try { URI(original) } catch (_: Exception) { return null }
        val host = uri.host ?: return null
        val query = buildList {
            resolved.clickId?.let { add("fr_click=" + enc(it)) }
            resolved.utm.forEach { (key, value) -> add("utm_$key=" + enc(value)) }
        }.joinToString("&")
        val path = resolved.deepLinkPath?.substringBefore('?') ?: "/"
        return "https://$host$path" + if (query.isEmpty()) "" else "?$query"
    }

    private fun enc(value: String): String = URLEncoder.encode(value, "UTF-8")
}
