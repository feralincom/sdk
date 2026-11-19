package com.feralin.android.internal

import android.os.Build
import java.io.File

/**
 * Cihazın root'lu görünüp görünmediği. Tek bir evet/hayır değeri üretir ve yalnız `true` ise ilk açılışa eklenir (`device_rooted`);
 * dosya listesi, `Build` alanları ya da cihaz kimliği gönderilmez.
 *
 * Sezgiseldir: sınama anahtarlarıyla imzalanmış sistem görüntüsüne ve bilinen `su` yollarına bakar. Kendini gizleyen root'u
 * (ör. Magisk'in gizleme kipi) görmez; komut çalıştırmaz, paket listesi okumaz. Sunucuda kesin kanıt değil, işaret sayılır.
 */
internal object RootCheck {
    const val PROPERTY = "device_rooted"

    private val SU_PATHS = listOf(
        "/system/bin/su",
        "/system/xbin/su",
        "/sbin/su",
        "/su/bin/su",
        "/system/sd/xbin/su",
        "/system/bin/failsafe/su",
        "/data/local/su",
        "/data/local/bin/su",
        "/data/local/xbin/su",
        "/system/app/Superuser.apk",
    )

    fun read(): Boolean = isRooted(Build.TAGS) { File(it).exists() }

    fun isRooted(buildTags: String?, exists: (String) -> Boolean): Boolean {
        if (buildTags.orEmpty().contains("test-keys")) return true
        return SU_PATHS.any { path ->
            try {
                exists(path)
            } catch (_: SecurityException) {
                false
            }
        }
    }
}
