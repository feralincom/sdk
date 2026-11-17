package com.feralin.android.internal

import com.feralin.android.AdFormat
import com.feralin.android.AdPrecision
import com.feralin.android.AdRevenueInput
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** X4: `fr_error`, oyun olayları ve `fr_ad_revenue` sözleşmeleri; ham yığın izi ve PII gitmez, parmak izi kararlıdır, sözleşme dışı girdi olay üretmez. */
class ErrorAndGameEventTest {
    private fun errorWith(message: String, vararg frames: StackTraceElement): Throwable =
        IllegalStateException(message).apply { stackTrace = arrayOf(*frames) }

    private val appFrame = StackTraceElement("com.example.shop.OrderScreen", "submit", "OrderScreen.kt", 42)
    private val frameworkFrame = StackTraceElement("android.os.Handler", "dispatchMessage", "Handler.java", 100)

    @Test
    fun hataGovdesiSozlesmeAlanlariniTasirYiginIziGitmez() {
        val props = ErrorEvent.properties(errorWith("sipariş başarısız", frameworkFrame, appFrame), ErrorEvent.ORIGIN_UNCAUGHT, fatal = true, appVersion = "1.4.2")
        assertEquals("IllegalStateException", props["error_type"])
        assertEquals("com.example.shop.OrderScreen.submit", props["top_frame"])
        assertEquals(1, props["frame_count"])
        assertEquals("1.4.2", props["app_version"])
        assertEquals(true, props["fatal"])
        assertEquals(false, props["handled"])
        assertEquals("uncaught_exception", props["origin"])
        assertTrue((props["fingerprint"] as String).matches(Regex("^[0-9a-f]{32}$")))
        // Satır numarası, dosya adı ve ham yığın hiçbir alanda yoktur.
        assertFalse(props.values.any { it.toString().contains("OrderScreen.kt") || it.toString().contains(":42") })
        assertFalse(props.containsKey("stack"))
    }

    @Test
    fun ayniHataSatirKaysaDaAyniParmakIziniUretirFarkliHataFarkliUretir() {
        val a = ErrorEvent.properties(errorWith("x", appFrame), "handled", false, null)["fingerprint"]
        val moved = StackTraceElement("com.example.shop.OrderScreen", "submit", "OrderScreen.kt", 99)
        val b = ErrorEvent.properties(errorWith("x", moved), "handled", false, null)["fingerprint"]
        assertEquals(a, b)
        val other = StackTraceElement("com.example.shop.CartScreen", "add", "CartScreen.kt", 7)
        assertNotEquals(a, ErrorEvent.properties(errorWith("x", other), "handled", false, null)["fingerprint"])
        // Derleyici lambda ekleri parmak izini bozmaz.
        val lambda = StackTraceElement("com.example.shop.OrderScreen\$\$ExternalSyntheticLambda3", "run", "D8\$\$SyntheticClass", 0)
        assertEquals("com.example.shop.OrderScreen.run", ErrorEvent.frame(lambda))
    }

    @Test
    fun mesajdakiKisiselVeriTemizlenir() {
        val text = ErrorEvent.scrub("ali@example.com sipariş 5551234567 https://x.test/a?t=1 eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 sürüm 1.4.2")
        assertFalse(text.contains("ali@"))
        assertFalse(text.contains("5551234567"))
        assertFalse(text.contains("x.test"))
        assertFalse(text.contains("eyJ"))
        assertTrue(text.contains("[email]"))
        assertTrue(text.contains("1.4.2"))
        assertTrue(ErrorEvent.scrub("a".repeat(500) + " b").length <= ErrorEvent.MAX_MESSAGE)
        assertEquals("UnsupportedOperationException", ErrorEvent.scrub("UnsupportedOperationException"))
    }

    @Test
    fun sinirlayiciAyniParmakIziniVeToplamiSinirlar() {
        val limiter = ErrorLimiter(maxEvents = 4, maxPerFingerprint = 2)
        assertTrue(limiter.allow("a"))
        assertTrue(limiter.allow("a"))
        assertFalse(limiter.allow("a"))
        assertTrue(limiter.allow("b"))
        assertTrue(limiter.allow("c"))
        assertFalse(limiter.allow("d"))
        assertFalse(ErrorLimiter(sampleRate = 0.5, random = { 0.9 }).allow("x"))
        assertTrue(ErrorLimiter(sampleRate = 0.5, random = { 0.1 }).allow("x"))
    }

    @Test
    fun oyunOlaylariSozlesmeyeUyar() {
        assertEquals(mapOf("level_id" to "level_3", "attempt" to 2L), GameEvents.levelStart("level_3", 2))
        val complete = requireNotNull(GameEvents.levelComplete("l1", null, 1200, 45_000))
        assertEquals(1200L, complete["score"])
        assertEquals(45_000L, complete["duration_ms"])
        assertEquals("timeout", GameEvents.levelFail("l1", null, null, null, "timeout")?.get("fail_reason"))
        assertNull(GameEvents.levelStart("", null))
        assertNull(GameEvents.levelStart("x".repeat(65), null))
        assertNull(GameEvents.levelStart("l", 0))
        assertNull(GameEvents.levelComplete("l", null, -1, null))
        assertNull(GameEvents.levelComplete("l", null, null, 86_400_001))
        assertEquals(mapOf("currency_name" to "gold", "amount" to 50L, "reason" to "quest"), GameEvents.economy("gold", 50, "quest", null))
        assertNull(GameEvents.economy("gold", 0, null, null))
        assertNull(GameEvents.economy("gold", GameEvents.MAX_AMOUNT + 1, null, null))
        assertNull(GameEvents.economy("", 5, null, null))
        assertEquals(mapOf("placement" to "level_end", "network" to "admob"), GameEvents.rewardedShown("level_end", "admob"))
        assertEquals(10L, GameEvents.rewardedComplete("p", null, 10, "gold")?.get("reward_amount"))
        assertNull(GameEvents.rewardedShown("", null))
        assertEquals("tx_1", GameEvents.iapInitiated("pack_small", "shop", "tx_1")?.get("transaction_id"))
        assertNull(GameEvents.iapOfferShown("", null))
    }

    @Test
    fun reklamGeliriSozlesmeyeUyarVerifiedDuser() {
        val props = requireNotNull(
            AdRevenueEvent.properties(
                AdRevenueInput("admob", AdFormat.REWARDED, 12_500, "USD", adUnit = "ca-app-pub-1/2", precision = AdPrecision.ESTIMATED, placement = "level_end", properties = mapOf("verified" to true, "receipt_digest" to "x", "extra" to "y")),
            ),
        )
        assertEquals("admob", props["network"])
        assertEquals("rewarded", props["ad_format"])
        assertEquals(12_500L, props["revenue_micros"])
        assertEquals("USD", props["currency"])
        assertEquals("estimated", props["precision"])
        assertEquals("ca-app-pub-1/2", props["ad_unit"])
        assertFalse(props.containsKey("verified"))
        assertFalse(props.containsKey("receipt_digest"))
        assertNotNull(props["extra"])
        val bad = listOf(
            AdRevenueInput("AdMob", AdFormat.BANNER, 1, "USD"),
            AdRevenueInput("", AdFormat.BANNER, 1, "USD"),
            AdRevenueInput("admob", AdFormat.BANNER, -1, "USD"),
            AdRevenueInput("admob", AdFormat.BANNER, AdRevenueEvent.MAX_REVENUE_MICROS + 1, "USD"),
            AdRevenueInput("admob", AdFormat.BANNER, 1, "usd"),
            AdRevenueInput("admob", AdFormat.BANNER, 1, "USD", adUnit = ""),
            AdRevenueInput("admob", AdFormat.BANNER, 1, "USD", impressionId = "i".repeat(129)),
        )
        for (input in bad) assertNull(input.toString(), AdRevenueEvent.properties(input))
        // Sanitize sonrası da bütün alanlar kalır.
        assertEquals(12_500L, EventJson.sanitize(props)["revenue_micros"])
    }
}
