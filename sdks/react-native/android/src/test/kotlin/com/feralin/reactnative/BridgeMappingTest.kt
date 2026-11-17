package com.feralin.reactnative

import com.feralin.android.Consent
import com.feralin.android.FeralinStatus
import com.feralin.android.FlushResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class BridgeMappingTest {
    private val base = mapOf<String, Any?>("projectKey" to "pk_test_rn_0001", "collectUrl" to "https://c.example")

    @Test
    fun `yapilandirma sarmalayici kimligi ve platformu tasir`() {
        val config = BridgeMapping.configFrom(base + mapOf("wrapperName" to "@feralin/react-native", "wrapperVersion" to "0.1.0"))!!
        assertEquals("react_native", config.wrapper?.platform)
        assertEquals("@feralin/react-native", config.wrapper?.name)
        assertEquals("0.1.0", config.wrapper?.version)
        assertNull("izin verilmediyse bekleniyor demektir", config.consent)
    }

    @Test
    fun `kopruden gelen Double alanlar tam sayiya cevrilir`() {
        val config = BridgeMapping.configFrom(base + mapOf("flushIntervalMs" to 500.0, "batchSize" to 10.0, "queueLimit" to 20.0, "sessionTimeoutMs" to 1000.0, "autoCaptureDeepLinks" to false, "debug" to true))!!
        assertEquals(500L, config.flushIntervalMs)
        assertEquals(10, config.batchSize)
        assertEquals(20, config.queueLimit)
        assertEquals(1000L, config.sessionTimeoutMs)
        assertFalse(config.autoCaptureDeepLinks)
        assertEquals(true, config.debug)
    }

    @Test
    fun `kurulum eslestirme kodu cekirdege iletilir, bossa iletilmez`() {
        assertEquals("K7M2-Q9XR4", BridgeMapping.configFrom(base + mapOf("installCode" to " K7M2-Q9XR4 "))!!.installCode)
        assertNull(BridgeMapping.configFrom(base + mapOf("installCode" to "  "))!!.installCode)
        assertNull(BridgeMapping.configFrom(base)!!.installCode)
    }

    @Test
    fun `eksik anahtar veya adres reddedilir`() {
        assertNull(BridgeMapping.configFrom(mapOf("collectUrl" to "https://c")))
        assertNull(BridgeMapping.configFrom(mapOf("projectKey" to "pk_x")))
    }

    @Test
    fun `izin alanlari eslenir ve analytics yoksa izin yok sayilir`() {
        assertEquals(Consent(true, false, null, true), BridgeMapping.consentFrom(mapOf("analytics" to true, "advertising" to false, "session_replay" to true)))
        assertNull(BridgeMapping.consentFrom(mapOf("advertising" to true)))
        assertNull(BridgeMapping.consentFrom("evet"))
        assertNull(BridgeMapping.consentFrom(mapOf("analytics" to "evet")))
    }

    @Test
    fun `ozellik sayilari kesirsizse tam sayi olur, ic ice yapi korunur`() {
        val out = BridgeMapping.propertiesFrom(mapOf("n" to 3.0, "d" to 3.5, "m" to mapOf("x" to 1.0), "l" to listOf(2.0, "s"), "b" to true))!!
        assertEquals(3L, out["n"])
        assertEquals(3.5, out["d"])
        assertEquals(mapOf("x" to 1L), out["m"])
        assertEquals(listOf(2L, "s"), out["l"])
        assertEquals(true, out["b"])
        assertNull(BridgeMapping.propertiesFrom(null))
    }

    @Test
    fun `durum ve gonderim sonucu haritaya cevrilir, anahtar yoktur`() {
        val status = BridgeMapping.statusToMap(FeralinStatus(true, "@feralin/react-native", "0.1.0", 2, Consent(true, advertising = true), "a", "s", null))
        assertEquals(true, status["initialized"])
        assertEquals(2, status["queued"])
        assertEquals(mapOf("analytics" to true, "advertising" to true), status["consent"])
        assertFalse(status.containsKey("projectKey"))
        assertEquals(mapOf("sent" to 1, "accepted" to 1, "rejected" to 0, "status" to 202, "batchId" to "b"), BridgeMapping.flushToMap(FlushResult(1, 1, 0, 202, "b")))
    }
}
