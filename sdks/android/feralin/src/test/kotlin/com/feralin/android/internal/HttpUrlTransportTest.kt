package com.feralin.android.internal

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/** Yerel gerçek soket üzerinde HTTP davranışı (android.jar'da JDK HttpServer yok; küçük soket sunucusu). */
class HttpUrlTransportTest {
    private lateinit var server: ServerSocket
    @Volatile private var receivedBody = ""
    @Volatile private var receivedHeaders = emptyMap<String, String>()
    @Volatile private var targetHits = 0

    private val base get() = "http://127.0.0.1:${server.localPort}"

    @Before
    fun setUp() {
        server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        thread(isDaemon = true) {
            try {
                while (true) server.accept().use(::serve)
            } catch (_: IOException) {
                // Sunucu kapatıldı.
            }
        }
    }

    private fun serve(socket: Socket) {
        val input = socket.getInputStream()
        val head = ByteArrayOutputStream()
        while (!head.toString("UTF-8").endsWith("\r\n\r\n")) {
            val next = input.read()
            if (next < 0) return
            head.write(next)
        }
        val lines = head.toString("UTF-8").trim().split("\r\n")
        val path = lines.first().split(" ")[1]
        val headers = lines.drop(1).associate { it.substringBefore(':').lowercase() to it.substringAfter(':').trim() }
        val body = ByteArray(headers["content-length"]?.toInt() ?: 0)
        var read = 0
        while (read < body.size) {
            val n = input.read(body, read, body.size - read)
            if (n < 0) break
            read += n
        }
        val response = when (path) {
            "/ok" -> {
                receivedBody = String(body, Charsets.UTF_8)
                receivedHeaders = headers
                reply("202 Accepted", "{\"accepted\":1}")
            }
            "/limited" -> reply("429 Too Many Requests", "{}", "Retry-After: 7\r\n")
            "/redirect" -> reply("302 Found", "", "Location: $base/target\r\n")
            else -> {
                targetHits++
                reply("204 No Content", "")
            }
        }
        socket.getOutputStream().write(response.toByteArray(Charsets.UTF_8))
        socket.getOutputStream().flush()
    }

    private fun reply(status: String, body: String, extra: String = ""): String =
        "HTTP/1.1 $status\r\n${extra}Content-Length: ${body.toByteArray().size}\r\nConnection: close\r\n\r\n$body"

    @After
    fun tearDown() = server.close()

    @Test
    fun govdeVeBasliklarGider() {
        val response = HttpUrlTransport().post(
            "$base/ok",
            mapOf("x-feralin-project-key" to "pk_test_1", "User-Agent" to "feralin-android/1"),
            "{\"türkçe\":\"ığüş\"}",
        )
        assertEquals(202, response.status)
        assertEquals("{\"accepted\":1}", response.body)
        assertEquals("{\"türkçe\":\"ığüş\"}", receivedBody)
        assertEquals("pk_test_1", receivedHeaders["x-feralin-project-key"])
        assertEquals("feralin-android/1", receivedHeaders["user-agent"])
        assertNull(response.retryAfterSeconds)
    }

    @Test
    fun retryAfterOkunur() {
        val response = HttpUrlTransport().post("$base/limited", emptyMap(), "{}")
        assertEquals(429, response.status)
        assertEquals(7L, response.retryAfterSeconds)
    }

    @Test
    fun yonlendirmeIzlenmez() {
        val response = HttpUrlTransport().post("$base/redirect", emptyMap(), "{}")
        assertEquals(302, response.status)
        assertEquals(0, targetHits)
        assertFalse(response.body.contains("target"))
    }

    @Test(expected = IOException::class)
    fun kapaliPortIoHatasiVerir() {
        val port = server.localPort
        server.close()
        HttpUrlTransport(connectTimeoutMs = 500, readTimeoutMs = 500).post("http://127.0.0.1:$port/ok", emptyMap(), "{}")
    }
}
