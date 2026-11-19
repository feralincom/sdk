package com.feralin.android.internal

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

internal data class TransportResponse(val status: Int, val body: String, val retryAfterSeconds: Long?)

internal interface Transport {
    /** Ağ hatasında [IOException] fırlatır. */
    @Throws(IOException::class)
    fun post(url: String, headers: Map<String, String>, body: String): TransportResponse

    /** Kısa link çözümlemesi (Fera Fly) için gövdesiz GET; desteklemeyen taşıma çözümlemeyi atlatır. */
    @Throws(IOException::class)
    fun get(url: String, headers: Map<String, String>): TransportResponse = throw IOException("GET desteklenmiyor")
}

/** Bağımlılıksız HTTP. Yönlendirme izlenmez: anahtar başlığı başka bir ana makineye taşınmamalıdır. */
internal class HttpUrlTransport(
    private val connectTimeoutMs: Int = 10_000,
    private val readTimeoutMs: Int = 15_000,
) : Transport {
    override fun post(url: String, headers: Map<String, String>, body: String): TransportResponse {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            connection.doOutput = true
            for ((name, value) in headers) connection.setRequestProperty(name, value)
            val bytes = body.toByteArray(Charsets.UTF_8)
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val text = stream?.use { input ->
                input.readBytes().let { raw -> String(raw, 0, minOf(raw.size, MAX_RESPONSE_BYTES), Charsets.UTF_8) }
            }.orEmpty()
            return TransportResponse(status, text, connection.getHeaderField("Retry-After")?.trim()?.toLongOrNull())
        } finally {
            connection.disconnect()
        }
    }

    override fun get(url: String, headers: Map<String, String>): TransportResponse {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "GET"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            for ((name, value) in headers) connection.setRequestProperty(name, value)
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val text = stream?.use { input ->
                input.readBytes().let { raw -> String(raw, 0, minOf(raw.size, MAX_RESPONSE_BYTES), Charsets.UTF_8) }
            }.orEmpty()
            return TransportResponse(status, text, null)
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        const val MAX_RESPONSE_BYTES = 64 * 1024
    }
}
