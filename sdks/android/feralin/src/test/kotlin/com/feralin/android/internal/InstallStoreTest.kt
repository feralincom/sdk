package com.feralin.android.internal

import org.junit.Assert.assertEquals
import org.junit.Test

class InstallStoreTest {
    @Test
    fun bilinenMagazalarSiniflanir() {
        assertEquals("google_play", InstallStore.classify("com.android.vending"))
        assertEquals("samsung_galaxy_store", InstallStore.classify("com.sec.android.app.samsungapps"))
        assertEquals("huawei_appgallery", InstallStore.classify("com.huawei.appmarket"))
        assertEquals("amazon_appstore", InstallStore.classify("com.amazon.venezia"))
        assertEquals("xiaomi_getapps", InstallStore.classify("com.xiaomi.mipicks"))
        assertEquals("oppo_app_market", InstallStore.classify("com.heytap.market"))
        assertEquals("vivo_app_store", InstallStore.classify("com.vivo.appstore"))
        assertEquals("honor_app_market", InstallStore.classify("com.hihonor.appmarket"))
    }

    @Test
    fun dosyadanKurulumBilinmeyenVeDigerAyridir() {
        assertEquals("sideload", InstallStore.classify("com.google.android.packageinstaller"))
        assertEquals("sideload", InstallStore.classify("com.android.packageinstaller"))
        assertEquals("unknown", InstallStore.classify(null))
        assertEquals("unknown", InstallStore.classify("  "))
        assertEquals("other", InstallStore.classify("com.ornek.ozelmagaza"))
    }

    @Test
    fun paketAdiBuyukKucukHarfVeBoslukDuyarsizdir() {
        assertEquals("google_play", InstallStore.classify(" Com.Android.Vending "))
    }

    @Test
    fun bilinmeyenKurucununPaketAdiDisariCikmaz() {
        // Sınıflama yalnız kapalı listeden değer döner: özel mağazanın paket adı olaya yazılmaz.
        val allowed = setOf("google_play", "samsung_galaxy_store", "huawei_appgallery", "amazon_appstore", "xiaomi_getapps", "oppo_app_market", "vivo_app_store", "honor_app_market", "sideload", "unknown", "other")
        for (name in listOf("com.ornek.ozelmagaza", "kisi@example.com", "", null, "com.android.vending")) {
            assertEquals(true, InstallStore.classify(name) in allowed)
        }
    }
}
