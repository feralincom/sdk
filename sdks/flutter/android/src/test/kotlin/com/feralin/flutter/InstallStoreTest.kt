package com.feralin.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InstallStoreTest {
    @Test
    fun bilinenMagazalarSiniflanir() {
        assertEquals("google_play", InstallStore.classify("com.android.vending"))
        assertEquals("google_play", InstallStore.classify("com.google.android.feedback"))
        assertEquals("samsung_galaxy_store", InstallStore.classify("com.sec.android.app.samsungapps"))
        assertEquals("huawei_appgallery", InstallStore.classify("com.huawei.appmarket"))
        assertEquals("amazon_appstore", InstallStore.classify("com.amazon.venezia"))
        assertEquals("xiaomi_getapps", InstallStore.classify("com.xiaomi.market"))
        assertEquals("xiaomi_getapps", InstallStore.classify("com.xiaomi.mipicks"))
        assertEquals("oppo_app_market", InstallStore.classify("com.oppo.market"))
        assertEquals("oppo_app_market", InstallStore.classify("com.heytap.market"))
        assertEquals("vivo_app_store", InstallStore.classify("com.vivo.appstore"))
        assertEquals("vivo_app_store", InstallStore.classify("com.bbk.appstore"))
        assertEquals("honor_app_market", InstallStore.classify("com.hihonor.appmarket"))
    }

    @Test
    fun yanYuklemeVeBilinmeyenAyridir() {
        assertEquals("sideload", InstallStore.classify("com.google.android.packageinstaller"))
        assertEquals("sideload", InstallStore.classify("com.android.packageinstaller"))
        assertEquals("sideload", InstallStore.classify("com.samsung.android.packageinstaller"))
        assertEquals("sideload", InstallStore.classify("com.miui.packageinstaller"))
        assertEquals("unknown", InstallStore.classify(null))
        assertEquals("unknown", InstallStore.classify(""))
        assertEquals("unknown", InstallStore.classify("  "))
    }

    @Test
    fun bosluklarVeBuyukHarfDuzeltilir() {
        assertEquals("google_play", InstallStore.classify(" Com.Android.Vending "))
    }

    @Test
    fun listedeOlmayanKurucununPaketAdiDisariCikmaz() {
        // Kanaldan yalnız kapalı listedeki sınıflar geçer; paket adı hiçbir girdide sonuç olmaz.
        val allowed = setOf(
            "google_play", "samsung_galaxy_store", "huawei_appgallery", "amazon_appstore", "xiaomi_getapps", "oppo_app_market",
            "vivo_app_store", "honor_app_market", "sideload", "unknown", "other",
        )
        for (name in listOf("com.ornek.ozelmagaza", "com.android.vending.sahte", "x", "google_play", "com.aurora.store", null)) {
            assertTrue(InstallStore.classify(name) in allowed)
        }
        assertEquals("other", InstallStore.classify("com.ornek.ozelmagaza"))
        assertEquals("other", InstallStore.classify("google_play"))
    }
}
