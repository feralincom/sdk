package com.feralin.android.internal

import android.content.Context
import android.net.Uri
import org.json.JSONObject

/** Bir Meta uygulamasının (Facebook, Instagram, Facebook Lite) sağlayıcı yanıtı. */
internal data class MetaReferrerRow(val provider: String, val installReferrer: String, val isCt: Int?, val actualTimestamp: Long?)

/**
 * Meta Install Referrer: Facebook, Instagram ve Facebook Lite uygulamaları, Meta reklamından gelen kurulumun şifreli kampanya verisini
 * ContentProvider üzerinden verir. Facebook SDK gerekmez; yalnız uygulamanın Facebook App ID'si (`FeralinConfig.metaAppId`) gerekir.
 * Veri şifrelidir ve SDK'da çözülmez: zarf olduğu gibi ilk açılışa eklenir, sunucu projenin çözme anahtarıyla açar.
 * Yalnız reklam ölçümü izni açıkken okunur (motor çağırır). Birden çok uygulama yanıt verirse en yeni etkileşim seçilir.
 */
internal class MetaInstallReferrerSource(
    private val query: (provider: String, authority: String) -> MetaReferrerRow?,
    private val appId: String?,
) {
    constructor(context: Context, appId: String?) : this({ provider, authority -> queryProvider(context, provider, authority, appId) }, appId)

    /** Sunucuya giden zarf: `{"r": install_referrer, "ct": 0|1, "ts": saniye, "p": sağlayıcı}`; yanıt yoksa null. */
    fun read(): String? {
        if (appId.isNullOrBlank()) return null
        val rows = AUTHORITIES.mapNotNull { (provider, authority) ->
            try {
                query(provider, authority)
            } catch (_: Exception) {
                // Uygulama yüklü değil, sağlayıcı yok ya da izin verilmedi: kanıt yoktur.
                null
            }
        }.filter { it.installReferrer.isNotBlank() }
        val best = rows.maxByOrNull { it.actualTimestamp ?: 0L } ?: return null
        return envelope(best)
    }

    companion object {
        /** Meta'nın belgelediği sağlayıcılar; `<queries>` bildirimi SDK manifestindedir (Android 11+ paket görünürlüğü). */
        val AUTHORITIES = listOf(
            "facebook" to "com.facebook.katana.provider.InstallReferrerProvider",
            "instagram" to "com.instagram.contentprovider.InstallReferrerProvider",
            "facebook_lite" to "com.facebook.lite.provider.InstallReferrerProvider",
        )
        private const val MAX_REFERRER_CHARS = 7_000

        fun envelope(row: MetaReferrerRow): String? {
            if (row.installReferrer.length > MAX_REFERRER_CHARS) return null
            val json = JSONObject()
            json.put("r", row.installReferrer)
            row.isCt?.let { json.put("ct", it) }
            row.actualTimestamp?.let { json.put("ts", it) }
            json.put("p", row.provider)
            return json.toString()
        }

        private fun queryProvider(context: Context, provider: String, authority: String, appId: String?): MetaReferrerRow? {
            if (appId.isNullOrBlank()) return null
            val uri = Uri.parse("content://$authority/$appId")
            context.contentResolver.query(uri, arrayOf("install_referrer", "is_ct", "actual_timestamp"), null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return null
                val referrerIndex = cursor.getColumnIndex("install_referrer")
                if (referrerIndex < 0 || cursor.isNull(referrerIndex)) return null
                val ctIndex = cursor.getColumnIndex("is_ct")
                val tsIndex = cursor.getColumnIndex("actual_timestamp")
                return MetaReferrerRow(
                    provider = provider,
                    installReferrer = cursor.getString(referrerIndex),
                    isCt = if (ctIndex >= 0 && !cursor.isNull(ctIndex)) cursor.getInt(ctIndex) else null,
                    actualTimestamp = if (tsIndex >= 0 && !cursor.isNull(tsIndex)) cursor.getLong(tsIndex) else null,
                )
            }
            return null
        }
    }
}
