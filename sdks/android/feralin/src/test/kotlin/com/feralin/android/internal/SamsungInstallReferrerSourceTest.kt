package com.feralin.android.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SamsungInstallReferrerSourceTest {
    private val worker = ManualWorker()

    private class FakeConnection(private val bind: Boolean = true, private val reply: String? = null, private val answers: Boolean = true) : SamsungReferrerConnection {
        var ended = 0
        var deliver: ((String?) -> Unit)? = null

        override fun start(onReferrer: (String?) -> Unit): Boolean {
            if (!bind) return false
            deliver = onReferrer
            if (answers) onReferrer(reply)
            return true
        }

        override fun end() {
            ended++
        }
    }

    private fun read(connection: FakeConnection): Pair<Int, AttributionParams?> {
        var calls = 0
        var result: AttributionParams? = null
        SamsungInstallReferrerSource({ connection }, worker).read {
            calls++
            result = it
        }
        worker.drain()
        return calls to result
    }

    @Test
    fun linktekiReferrerIzinListesindenGecerVeKaynakSamsungOlur() {
        val connection = FakeConnection(reply = "fr_click=clk_ss_1&utm_source=galaxy&fr_dl=%2Furun%2F42&token=gizli")
        val (calls, params) = read(connection)
        assertEquals(1, calls)
        assertEquals("clk_ss_1", params?.frClick)
        assertEquals(mapOf("utm_source" to "galaxy"), params?.utm)
        assertEquals("/urun/42", params?.deepLinkPath)
        assertEquals("samsung_install_referrer", params?.source)
        assertEquals(1, connection.ended)
        // Sonuç geldikten sonra süre sayacı iptal edilir.
        assertTrue(worker.pendingDelays().isEmpty())
    }

    @Test
    fun organikVarsayilanVeBosYanitKanitSayilmaz() {
        assertNull(read(FakeConnection(reply = "utm_source=galaxystore&utm_medium=organic")).second)
        assertNull(read(FakeConnection(reply = null)).second)
        assertNull(read(FakeConnection(reply = "")).second)
        assertNull(read(FakeConnection(reply = "fr_click=" + "a".repeat(3_000))).second)
    }

    @Test
    fun galaxyStoreYoksaKanitYokturVeBaglantiKapatilir() {
        val connection = FakeConnection(bind = false)
        val (calls, params) = read(connection)
        assertEquals(1, calls)
        assertNull(params)
        assertEquals(1, connection.ended)
    }

    @Test
    fun servisYanitVermezseSureDolarVeGecYanitYokSayilir() {
        val connection = FakeConnection(answers = false)
        var calls = 0
        var result: AttributionParams? = AttributionParams.EMPTY
        SamsungInstallReferrerSource({ connection }, worker, timeoutMs = 5_000L).read {
            calls++
            result = it
        }
        worker.drain()
        assertEquals(0, calls)
        worker.advance(5_000L)
        worker.drain()
        assertEquals(1, calls)
        assertNull(result)
        // Süre dolduktan sonra gelen yanıt ikinci kez bildirilmez.
        connection.deliver?.invoke("fr_click=clk_gec")
        worker.drain()
        assertEquals(1, calls)
    }

    @Test
    fun baglantiHatasiKanitYokSayilir() {
        var result: AttributionParams? = AttributionParams.EMPTY
        SamsungInstallReferrerSource({ throw SecurityException("servis görünmüyor") }, worker).read { result = it }
        worker.drain()
        assertNull(result)
    }

    @Test
    fun zincirSirasiPlaySamsungHuawei() {
        val organic = AttributionParams(null, mapOf("utm_medium" to "organic"))
        val samsung = AttributionParams("clk_ss", emptyMap(), source = AttributionSource.SAMSUNG_INSTALL_REFERRER)
        val huawei = AttributionParams("clk_hw", emptyMap(), source = AttributionSource.HUAWEI_INSTALL_REFERRER)
        val play = AttributionParams("clk_play", emptyMap())
        var result: AttributionParams? = null
        var huaweiAsked = 0

        // Play kanıt verirse ötekilere sorulmaz.
        StoreReferrerChain({ it(play) }, { huaweiAsked++; huawei }, { error("Samsung'a sorulmamalıydı") }).read { result = it }
        assertSame(play, result)
        assertEquals(0, huaweiAsked)

        // Play organik, Galaxy Store kanıt verir: AppGallery'ye sorulmaz.
        StoreReferrerChain({ it(organic) }, { huaweiAsked++; huawei }, { it(samsung) }).read { result = it }
        assertSame(samsung, result)
        assertEquals(0, huaweiAsked)

        // Galaxy Store da kanıt vermez: AppGallery.
        StoreReferrerChain({ it(organic) }, { huaweiAsked++; huawei }, { it(null) }).read { result = it }
        assertSame(huawei, result)
        assertEquals(1, huaweiAsked)

        // Hiçbiri kanıt vermez: Play sonucu korunur.
        StoreReferrerChain({ it(organic) }, { null }, { it(null) }).read { result = it }
        assertSame(organic, result)
    }
}
