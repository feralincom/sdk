package com.feralin.android.internal

import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Yalnız sahte bağlantı: gerçek Play servisi yanıtı bu testte yoktur. */
class PlayInstallReferrerSourceTest {
    private val worker = ManualWorker()

    private inner class FakeConnection(
        private val code: Int?,
        private val referrer: String? = null,
        private val disconnect: Boolean = false,
    ) : ReferrerConnection {
        var ended = false
        override fun start(onSetupFinished: (Int) -> Unit, onDisconnected: () -> Unit) {
            if (disconnect) onDisconnected()
            code?.let(onSetupFinished)
        }
        override fun referrer(): String? = referrer
        override fun end() { ended = true }
    }

    private fun read(vararg connections: FakeConnection): Pair<AttributionParams?, Int> {
        var opened = 0
        var result: AttributionParams? = AttributionParams.EMPTY
        var calls = 0
        PlayInstallReferrerSource({ connections[opened++] }, worker).read {
            result = it
            calls++
        }
        worker.drain()
        repeat(4) { worker.advance(10_000) }
        assertEquals("geri çağrı tam bir kez", 1, calls)
        return result to opened
    }

    @Test
    fun basaridaIzinListesiDonerBaglantiKapanir() {
        val connection = FakeConnection(InstallReferrerResponse.OK, "fr_click=c1&gclid=x")
        val (params, opened) = read(connection)
        assertEquals("c1", params!!.frClick)
        assertTrue(params.utm.isEmpty())
        assertEquals(1, opened)
        assertTrue(connection.ended)
    }

    @Test
    fun desteklenmeyenCihazdaYenidenDenenmez() {
        val (params, opened) = read(FakeConnection(InstallReferrerResponse.FEATURE_NOT_SUPPORTED))
        assertNull(params)
        assertEquals(1, opened)
    }

    @Test
    fun servisYoksaUcKezDenenipVazgecilir() {
        val (params, opened) = read(
            FakeConnection(InstallReferrerResponse.SERVICE_UNAVAILABLE),
            FakeConnection(InstallReferrerResponse.SERVICE_UNAVAILABLE),
            FakeConnection(InstallReferrerResponse.SERVICE_UNAVAILABLE),
        )
        assertNull(params)
        assertEquals(3, opened)
    }

    @Test
    fun kopmaSonrasiYenidenDenemeBasarili() {
        val (params, opened) = read(
            FakeConnection(null, disconnect = true),
            FakeConnection(InstallReferrerResponse.OK, "utm_source=ads"),
        )
        assertEquals("ads", params!!.utm["utm_source"])
        assertEquals(2, opened)
    }

    @Test
    fun yanitGelmezseZamanAsiminaUgrar() {
        val (params, opened) = read(FakeConnection(null), FakeConnection(null), FakeConnection(null))
        assertNull(params)
        assertEquals(3, opened)
    }
}
