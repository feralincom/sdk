package com.feralin.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HuaweiInstallReferrerTest {
    @Test
    fun linktekiReferrerIzinListesindenGecer() {
        val params = HuaweiInstallReferrer { "fr_click=clk_hw_1&utm_source=petal&fr_dl=%2Furun%2F42&email=a%40b.c" }.read()
        assertEquals(mapOf("fr_click" to "clk_hw_1", "utm_source" to "petal", "fr_dl" to "/urun/42"), params)
    }

    @Test
    fun kanitYoksaNullDoner() {
        assertNull(HuaweiInstallReferrer { null }.read())
        assertNull(HuaweiInstallReferrer { "" }.read())
        // İzin listesinde hiçbir alan yok: kanıt sayılmaz.
        assertNull(HuaweiInstallReferrer { "channel=abc&taskid=7" }.read())
        // Yol tek başına kanıt değildir.
        assertNull(HuaweiInstallReferrer { "fr_dl=%2Furun%2F42" }.read())
        assertNull(HuaweiInstallReferrer { "fr_click=" + "a".repeat(3_000) }.read())
    }

    @Test
    fun saglayiciHatasiKanitYokSayilir() {
        assertNull(HuaweiInstallReferrer { throw SecurityException("sağlayıcı görünmüyor") }.read())
    }
}
