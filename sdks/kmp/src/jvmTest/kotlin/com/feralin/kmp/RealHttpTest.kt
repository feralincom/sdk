package com.feralin.kmp

import com.sun.net.httpserver.HttpServer
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

private const val OVERSIZED_RESPONSE_BYTES = 512L * 1024 * 1024

/** Gerçek CIO motoru ve gerçek TCP: JDK'nın HTTP sunucusuna istek gider. */
class RealHttpTest {
    private class Captured(val key: String?, val idempotency: String?, val contentType: String?, val body: String)

    private fun server(status: Int, response: String, retryAfter: String? = null, block: suspend (String, ArrayBlockingQueue<Captured>) -> Unit) {
        val seen = ArrayBlockingQueue<Captured>(8)
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/v1/batch") { exchange ->
            seen.add(
                Captured(
                    exchange.requestHeaders.getFirst("X-Feralin-Project-Key"),
                    exchange.requestHeaders.getFirst("Idempotency-Key"),
                    exchange.requestHeaders.getFirst("Content-Type"),
                    exchange.requestBody.readBytes().decodeToString(),
                ),
            )
            retryAfter?.let { exchange.responseHeaders.add("Retry-After", it) }
            val bytes = response.encodeToByteArray()
            exchange.sendResponseHeaders(status, if (bytes.isEmpty()) -1 else bytes.size.toLong())
            if (bytes.isNotEmpty()) exchange.responseBody.use { it.write(bytes) }
            exchange.close()
        }
        server.start()
        try {
            runBlocking { block("http://127.0.0.1:${server.address.port}", seen) }
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun responseBodyIsCutWhileDownloading() = runBlocking {
        val written = AtomicLong()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.executor = Executors.newCachedThreadPool()
        server.createContext("/v1/batch") { exchange ->
            exchange.requestBody.readBytes()
            exchange.sendResponseHeaders(202, 0)
            val chunk = ByteArray(64 * 1024) { 'x'.code.toByte() }
            try {
                exchange.responseBody.use { out ->
                    while (written.get() < OVERSIZED_RESPONSE_BYTES) {
                        out.write(chunk)
                        written.addAndGet(chunk.size.toLong())
                    }
                }
            } catch (_: IOException) {
                // İstemci bağlantıyı kesti: beklenen yol.
            }
            exchange.close()
        }
        server.start()
        try {
            val response = KtorTransport().post("http://127.0.0.1:${server.address.port}/v1/batch", "{}", mapOf("Content-Type" to "application/json"), 30_000)
            assertEquals(202, response.status)
            assertEquals(64 * 1024, response.body.length)
            // Yuva tamponları yüzünden biraz fazlası yazılabilir; önemli olan gövdenin tamamının indirilmemesi.
            assertTrue(written.get() < OVERSIZED_RESPONSE_BYTES, "gövde indirme sırasında kesilmeli: ${written.get()} bayt yazıldı")
        } finally {
            server.stop(0)
            (server.executor as ExecutorService).shutdownNow()
        }
    }

    @Test
    fun acceptedOverRealHttp() = server(202, "{\"accepted\":1,\"rejected\":0,\"batch_id\":\"batch_real\"}") { url, seen ->
        val client = FeralinClient(FeralinConfig(TEST_KEY, url, ANALYTICS, flushIntervalMillis = 0))
        val event = assertNotNull(client.track("order_completed", mapOf("order_id" to "ord_1")))
        val result = client.flush()
        assertTrue(result.ok, "${result.error}")
        assertEquals(202, result.status)
        assertEquals("batch_real", result.batchId)
        assertEquals(0, client.queued)

        val captured = seen.take()
        assertEquals(TEST_KEY, captured.key)
        assertEquals(idempotencyKeyFor(listOf(event.eventId)), captured.idempotency)
        assertEquals("application/json", captured.contentType)
        val events = Json.parseToJsonElement(captured.body).jsonObject.getValue("events").jsonArray
        assertEquals(1, events.size)
        client.close(1_000)
    }

    @Test
    fun serverErrorKeepsQueueAndHonoursRetryAfter() = server(503, "", "7") { url, _ ->
        val client = FeralinClient(FeralinConfig(TEST_KEY, url, ANALYTICS, flushIntervalMillis = 0))
        client.track("e")
        val result = client.flush()
        assertEquals(DeliveryError.Temporary(503, "olaylar kuyrukta tutuldu"), result.error)
        assertEquals(1, client.queued)
        assertEquals(7, client.status().backoffSeconds)
        client.setConsent(Consent())
        client.close(1_000)
    }

    @Test
    fun rejectionCarriesProblemSummary() = server(401, "{\"title\":\"Yetki\"}") { url, _ ->
        val client = FeralinClient(FeralinConfig(TEST_KEY, url, ANALYTICS, flushIntervalMillis = 0))
        client.track("e")
        val result = client.flush()
        assertEquals(DeliveryError.Rejected(401, "Yetki"), result.error)
        assertEquals(0, client.queued)
        client.close(1_000)
    }

    @Test
    fun connectionRefusedKeepsQueue() = runBlocking {
        // Boş port: dinleyici kapatılır, bağlantı reddedilir. Zaman aşımı değil, ret sınanır.
        val port = ServerSocket(0, 0, InetAddress.getLoopbackAddress()).use { it.localPort }
        val client = FeralinClient(FeralinConfig(TEST_KEY, "http://127.0.0.1:$port", ANALYTICS, flushIntervalMillis = 0))
        client.track("e")
        val result = client.flush()
        val error = assertIs<DeliveryError.Temporary>(result.error)
        assertEquals(0, error.status)
        assertEquals(1, client.queued)
        client.setConsent(Consent())
        client.close(1_000)
        Unit
    }

    @Test
    fun jvmPlatformNameIsInSchema() {
        assertEquals("java", platformName)
    }
}
