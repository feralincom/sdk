package com.feralin.kmp

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.client.plugins.HttpTimeout
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class KtorTransportTest {
    private fun transport(engine: MockEngine) = KtorTransport(
        HttpClient(engine) {
            expectSuccess = false
            install(HttpTimeout)
        },
    )

    private val headers = mapOf(
        "Content-Type" to "application/json",
        "X-Feralin-Project-Key" to TEST_KEY,
        "Idempotency-Key" to "abc-1",
    )

    @Test
    fun sendsBodyAndHeadersAndReturnsResponse() = runTest {
        var seenKey: String? = null
        var seenBody = ""
        var seenContentType: String? = null
        val engine = MockEngine { request ->
            seenKey = request.headers["X-Feralin-Project-Key"]
            seenBody = request.body.toByteArray().decodeToString()
            seenContentType = request.body.contentType?.toString()
            respond("{\"accepted\":1}", HttpStatusCode.Accepted)
        }
        val response = transport(engine).post("https://collect.example.test/v1/batch", "{\"events\":[]}", headers, 1_000)
        assertEquals(202, response.status)
        assertEquals("{\"accepted\":1}", response.body)
        assertEquals(TEST_KEY, seenKey)
        assertEquals("{\"events\":[]}", seenBody)
        assertEquals("application/json", seenContentType)
    }

    @Test
    fun errorStatusIsResponseWithRetryAfter() = runTest {
        val engine = MockEngine {
            respond("", HttpStatusCode.ServiceUnavailable, headersOf(HttpHeaders.RetryAfter, "7"))
        }
        val response = transport(engine).post("https://collect.example.test/v1/batch", "{}", headers, 1_000)
        assertEquals(503, response.status)
        assertEquals("7", response.retryAfter)
    }

    @Test
    fun engineFailureBecomesTransportExceptionWithoutKey() = runTest {
        val engine = MockEngine { throw IllegalStateException("bağlantı yok") }
        val error = assertFailsWith<TransportException> {
            transport(engine).post("https://collect.example.test/v1/batch", "{}", headers, 1_000)
        }
        assertTrue(error.message.orEmpty().startsWith("ağ hatası"))
        assertTrue(!error.message.orEmpty().contains(TEST_KEY))
    }
}
