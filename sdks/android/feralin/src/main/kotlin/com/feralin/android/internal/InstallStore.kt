package com.feralin.android.internal

import android.content.Context
import android.os.Build

/**
 * Kurulum mağazası: uygulamayı cihaza kuran paketin adından türetilir (`PackageManager`). Kişisel veri değildir; cihaz ya da kullanıcı
 * kimliği taşımaz. Değer işletim sisteminin bildirdiğidir, mağaza tarafından doğrulanmaz: yan yükleme (APK dosyası) ve geliştirme
 * kurulumu ayrı sınıflardır, bilinmeyen kurucu `other` olur ve paket adı ayrıca gönderilmez.
 */
internal object InstallStore {
    const val GOOGLE_PLAY = "google_play"
    const val SAMSUNG_GALAXY_STORE = "samsung_galaxy_store"
    const val HUAWEI_APPGALLERY = "huawei_appgallery"
    const val AMAZON_APPSTORE = "amazon_appstore"
    const val XIAOMI_GETAPPS = "xiaomi_getapps"
    const val OPPO_APP_MARKET = "oppo_app_market"
    const val VIVO_APP_STORE = "vivo_app_store"
    const val HONOR_APP_MARKET = "honor_app_market"
    /** Dosyadan kurulum (tarayıcı, dosya yöneticisi, sistem paket kurucusu). */
    const val SIDELOAD = "sideload"
    /** Kurucu bildirilmedi: `adb install`, Android Studio ya da ön yüklü uygulama. */
    const val UNKNOWN = "unknown"
    const val OTHER = "other"

    private val STORES = mapOf(
        "com.android.vending" to GOOGLE_PLAY,
        "com.google.android.feedback" to GOOGLE_PLAY,
        "com.sec.android.app.samsungapps" to SAMSUNG_GALAXY_STORE,
        "com.huawei.appmarket" to HUAWEI_APPGALLERY,
        "com.amazon.venezia" to AMAZON_APPSTORE,
        "com.xiaomi.market" to XIAOMI_GETAPPS,
        "com.xiaomi.mipicks" to XIAOMI_GETAPPS,
        "com.oppo.market" to OPPO_APP_MARKET,
        "com.heytap.market" to OPPO_APP_MARKET,
        "com.vivo.appstore" to VIVO_APP_STORE,
        "com.bbk.appstore" to VIVO_APP_STORE,
        "com.hihonor.appmarket" to HONOR_APP_MARKET,
        "com.google.android.packageinstaller" to SIDELOAD,
        "com.android.packageinstaller" to SIDELOAD,
        "com.samsung.android.packageinstaller" to SIDELOAD,
        "com.miui.packageinstaller" to SIDELOAD,
    )

    /** Kurucu paket adından mağaza sınıfı. */
    fun classify(installerPackage: String?): String {
        val name = installerPackage?.trim()?.lowercase()
        if (name.isNullOrEmpty()) return UNKNOWN
        return STORES[name] ?: OTHER
    }

    /** Uygulamanın kurucusunu okur. Android 11+ `getInstallSourceInfo`, öncesi `getInstallerPackageName`. Okunamazsa `unknown`. */
    @Suppress("DEPRECATION")
    fun read(context: Context): String {
        val installer = try {
            val manager = context.packageManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                manager.getInstallSourceInfo(context.packageName).installingPackageName
            } else {
                manager.getInstallerPackageName(context.packageName)
            }
        } catch (_: Throwable) {
            null
        }
        return classify(installer)
    }
}
