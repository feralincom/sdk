package com.feralin.kmp

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

private class CheckoutFailure(message: String) : IllegalStateException(message)

/** `fr_error` sözleşmesi (Android `ErrorEvent.kt`, Web ve React Native ile aynı alanlar ve temizlik). */
class ErrorEventTest {
    @Test
    fun fnvMatchesKnownVectors() {
        assertEquals("cbf29ce484222325", ErrorEvents.fnv1a64(""))
        assertEquals("af63dc4c8601ec8c", ErrorEvents.fnv1a64("a"))
    }

    @Test
    fun scrubRemovesPiiAndTruncates() {
        val raw = "user ali@example.com at https://x.test/a?b=1 id 123e4567-e89b-12d3-a456-426614174000 " +
            "tok abcdefghijklmnopqrstuvwx12 tel +90 532 123 45 67 v1.4.2 UnsupportedOperationExceptionWithLongName"
        val clean = ErrorEvents.scrub(raw)
        assertEquals("user [email] at [url] id [id] tok [token] tel [num] v1.4.2 UnsupportedOperationExceptionWithLongName", clean)
        assertEquals(200, ErrorEvents.scrub("x ".repeat(300)).length)
        // Vekil çifti ortadan bölünmez.
        val emoji = "a".repeat(199) + "😀"
        assertEquals(199, ErrorEvents.scrub(emoji).length)
    }

    @Test
    fun framesAreNormalizedAndAppFramesPreferred() {
        val trace = """
            com.example.CheckoutFailure: kart reddedildi
            	at com.example.Checkout${'$'}pay${'$'}1.invoke(Checkout.kt:42)
            	at com.example.Checkout${'$'}${'$'}ExternalSyntheticLambda0.run(Unknown Source:2)
            	at java.base/java.lang.Thread.run(Thread.java:833)
            	at app//com.example.Main.main(Main.kt:7)
            Caused by: java.io.IOException: boom
            	at com.example.Net.call(Net.kt:9)
        """.trimIndent()
        assertEquals(listOf("com.example.Checkout\$pay.invoke", "com.example.Checkout.run", "com.example.Main.main"), ErrorEvents.frames(trace))
        val onlyFramework = "x\n\tat java.lang.Thread.run(Thread.java:1)\n\tat kotlin.io.Foo.bar(Foo.kt:2)"
        assertEquals(listOf("java.lang.Thread.run", "kotlin.io.Foo.bar"), ErrorEvents.frames(onlyFramework))
        assertEquals(emptyList(), ErrorEvents.frames("Native biçim\n    at 1   test.kexe   0x0000 kfun:a.b#c(){} + 70"))
    }

    @Test
    fun fingerprintUsesFramesOrDigitlessMessage() {
        val withFrames = ErrorEvents.fingerprint("E", listOf("a.B.c", "a.B.d"), "x 1")
        assertEquals(ErrorEvents.fnv1a64("E|a.B.c|a.B.d"), withFrames)
        assertEquals(ErrorEvents.fingerprint("E", emptyList(), "sipariş 12 bulunamadı"), ErrorEvents.fingerprint("E", emptyList(), "sipariş 99 bulunamadı"))
        assertTrue(Regex("^[0-9a-f]{16}$").matches(withFrames))
    }

    @Test
    fun captureErrorBuildsContractBody() = runTest {
        val collector = FakeCollector()
        val client = FeralinClient(config().copy(appVersion = "2.4.1"), collector)
        val event = assertNotNull(client.captureError(CheckoutFailure("kart reddedildi: ali@example.com")))
        assertEquals(ERROR_EVENT_NAME, event.payload.getValue("event_name").jsonPrimitive.content)
        val props = event.payload.getValue("properties").jsonObject
        assertEquals("CheckoutFailure", props.getValue("error_type").jsonPrimitive.content)
        assertEquals("kart reddedildi: [email]", props.getValue("message").jsonPrimitive.content)
        assertTrue(Regex("^[0-9a-f]{16}$").matches(props.getValue("fingerprint").jsonPrimitive.content))
        assertEquals("2.4.1", props.getValue("app_version").jsonPrimitive.content)
        assertTrue(props.getValue("handled").jsonPrimitive.boolean)
        assertFalse(props.getValue("fatal").jsonPrimitive.boolean)
        assertEquals("handled", props.getValue("origin").jsonPrimitive.content)
        val allowed = setOf("error_type", "message", "fingerprint", "top_frame", "frame_count", "app_version", "handled", "fatal", "origin")
        assertTrue(allowed.containsAll(props.keys), props.keys.toString())
        props["top_frame"]?.let { assertTrue(it.jsonPrimitive.content.length <= 160) }
        client.flush()
        assertEquals(1, collector.request(0).events.size)
    }

    @Test
    fun uncaughtIsFatalAndUnhandled() {
        val client = FeralinClient(config(), FakeCollector())
        val props = assertNotNull(client.captureError(RuntimeException("x"), uncaught = true)).payload.getValue("properties").jsonObject
        assertEquals("uncaught_exception", props.getValue("origin").jsonPrimitive.content)
        assertTrue(props.getValue("fatal").jsonPrimitive.boolean)
        assertFalse(props.getValue("handled").jsonPrimitive.boolean)
        assertFalse("app_version" in props)
    }

    @Test
    fun limiterCapsPerFingerprintAndTotal() {
        val client = FeralinClient(config(), FakeCollector())
        val same = (0 until 5).map { client.captureError(IllegalArgumentException("aynı")) }
        assertEquals(3, same.count { it != null })
        val limiter = ErrorLimiter(maxEvents = 20, maxPerFingerprint = 3)
        assertEquals(20, (0 until 30).count { limiter.allow("fp$it") })
        assertFalse(ErrorLimiter(sampleRate = 0.5, random = { 0.9 }).allow("fp"))
        assertTrue(ErrorLimiter(sampleRate = 0.5, random = { 0.1 }).allow("fp"))
    }

    @Test
    fun noConsentOrClosedProducesNothingAndNeverThrows() = runTest {
        val denied = FeralinClient(config(consent = Consent()), FakeCollector())
        assertNull(denied.captureError(RuntimeException("x")))
        val closed = FeralinClient(config(), FakeCollector())
        closed.close()
        assertNull(closed.captureError(RuntimeException("x")))
        val valid = FeralinClient(config(), FakeCollector())
        assertNull(valid.captureError(RuntimeException("x"), userId = "u".repeat(200)))
    }

    @Test
    fun emptyMessageOmitted() {
        val client = FeralinClient(config(), FakeCollector())
        val props = assertNotNull(client.captureError(RuntimeException())).payload.getValue("properties").jsonObject
        assertFalse("message" in props)
        assertEquals("RuntimeException", props.getValue("error_type").jsonPrimitive.content)
    }
}
