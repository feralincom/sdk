package com.feralin.android.internal

import android.content.Context

/**
 * İsteğe bağlı Google reklam kimliği (GAID). Varsayılan olarak hiç okunmaz: yalnız `FeralinConfig.collectAdvertisingId = true` ise,
 * kullanıcı reklam ölçümü iznini verdiyse ve uygulama çocuklara yönelik değilse, ilk açılışta bir kez okunur.
 *
 * SDK, Google Play Services kütüphanesine bağımlı değildir: `com.google.android.gms:play-services-ads-identifier` uygulamada varsa
 * yansımayla çağrılır, yoksa değer okunmaz. Uygulamanın `com.google.android.gms.permission.AD_ID` iznini kendi manifestine eklemesi
 * gerekir (Android 13+); SDK bu izni eklemez. Kullanıcı reklam kişiselleştirmeyi kapattıysa kimlik gönderilmez.
 */
internal object AdvertisingIdSource {
    const val PROPERTY = "advertising_id"
    private const val CLIENT = "com.google.android.gms.ads.identifier.AdvertisingIdClient"
    private val PATTERN = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private const val ZERO = "00000000-0000-0000-0000-000000000000"

    /** Ana iş parçacığında çağrılmamalıdır (Google'ın çağrısı engelleyicidir); motor işçi iş parçacığından çağırır. */
    fun read(context: Context): String? {
        val info = try {
            Class.forName(CLIENT).getMethod("getAdvertisingIdInfo", Context::class.java).invoke(null, context)
        } catch (t: Throwable) {
            // Kütüphane yok, Play Services yok ya da izin eksik: kimlik okunmaz.
            null
        } ?: return null
        return try {
            val limited = info.javaClass.getMethod("isLimitAdTrackingEnabled").invoke(info) as? Boolean
            val id = info.javaClass.getMethod("getId").invoke(info) as? String
            normalize(id, limited)
        } catch (t: Throwable) {
            null
        }
    }

    /** Kişiselleştirme kapalıysa, kimlik boşsa, sıfırlanmışsa ya da UUID biçiminde değilse `null`; aksi halde küçük harfli kimlik. */
    fun normalize(id: String?, limitAdTracking: Boolean?): String? {
        if (limitAdTracking != false || id == null) return null
        val value = id.trim().lowercase()
        return if (PATTERN.matches(value) && value != ZERO) value else null
    }
}
