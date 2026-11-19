package com.feralin.android.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class HuaweiInstallReferrerSourceTest {
    private val play = AttributionParams("clk_play", mapOf("utm_source" to "ads"))

    @Test
    fun linktekiReferrerIzinListesindenGecerVeKaynakHuaweiOlur() {
        val params = HuaweiInstallReferrerSource { "fr_click=clk_hw_1&utm_source=petal&fr_dl=%2Furun%2F42&email=a%40b.c" }.read()
        assertEquals("clk_hw_1", params?.frClick)
        assertEquals(mapOf("utm_source" to "petal"), params?.utm)
        assertEquals("/urun/42", params?.deepLinkPath)
        assertEquals("huawei_install_referrer", params?.source)
    }

    @Test
    fun kanitYoksaNullDoner() {
        assertNull(HuaweiInstallReferrerSource { null }.read())
        assertNull(HuaweiInstallReferrerSource { "" }.read())
        // İzin listesinde hiçbir alan yok: kanıt sayılmaz.
        assertNull(HuaweiInstallReferrerSource { "channel=abc&taskid=7" }.read())
        assertNull(HuaweiInstallReferrerSource { "fr_click=" + "a".repeat(3_000) }.read())
    }

    @Test
    fun saglayiciHatasiKanitYokSayilir() {
        assertNull(HuaweiInstallReferrerSource { throw SecurityException("sağlayıcı görünmüyor") }.read())
    }

    @Test
    fun playKanitVerirseHuaweiyeSorulmaz() {
        var asked = 0
        var result: AttributionParams? = null
        StoreReferrerChain({ it(play) }, { asked++; null }).read { result = it }
        assertSame(play, result)
        assertEquals(0, asked)
        assertEquals("play_install_referrer", result?.source)
    }

    @Test
    fun playKanitVermezseHuaweiOkunur() {
        val huawei = AttributionParams("clk_hw", emptyMap(), source = AttributionSource.HUAWEI_INSTALL_REFERRER)
        val organic = AttributionParams(null, mapOf("utm_source" to "google-play", "utm_medium" to "organic"))
        for (fromPlay in listOf<AttributionParams?>(null, AttributionParams.EMPTY, organic)) {
            var result: AttributionParams? = null
            StoreReferrerChain({ it(fromPlay) }, { huawei }).read { result = it }
            assertSame(huawei, result)
        }
    }

    @Test
    fun ikisiDeKanitVermezsePlaySonucuKorunur() {
        val organic = AttributionParams(null, mapOf("utm_medium" to "organic"))
        var result: AttributionParams? = play
        StoreReferrerChain({ it(organic) }, { null }).read { result = it }
        assertSame(organic, result)
        StoreReferrerChain({ it(null) }, { null }).read { result = it }
        assertNull(result)
    }
}
