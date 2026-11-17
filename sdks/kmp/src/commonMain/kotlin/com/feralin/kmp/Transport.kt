package com.feralin.kmp

import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.timeout
import io.ktor.client.request.header
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.content.ByteArrayContent
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readAvailable
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

private const val MAX_RESPONSE_BODY = 64 * 1024

/** HTTP yanıtı. Hata kodları da normal yanıttır. */
data class TransportResponse(val status: Int, val body: String = "", val retryAfter: String? = null)

/** Ağ veya zaman aşımı hatası: olaylar kuyrukta kalır. */
class TransportException(message: String) : Exception(message)

/** Testler ve özel ağ yığınları için değiştirilebilir taşıma. */
fun interface Transport {
    @Throws(TransportException::class, CancellationException::class)
    suspend fun post(url: String, body: String, headers: Map<String, String>, timeoutMillis: Long): TransportResponse
}

/** Ktor ile taşıma. Motor hedefe göre seçilir: JVM CIO, Android OkHttp, iOS Darwin. */
class KtorTransport internal constructor(private val client: HttpClient) : Transport {
    constructor() : this(
        HttpClient(platformEngineFactory()) {
            expectSuccess = false
            install(HttpTimeout)
        },
    )

    override suspend fun post(url: String, body: String, headers: Map<String, String>, timeoutMillis: Long): TransportResponse {
        try {
            return client.preparePost(url) {
                timeout { requestTimeoutMillis = timeoutMillis }
                for ((name, value) in headers) {
                    // Ktor Content-Type başlığını gövdeden alır; elle verilmesi hata fırlatır.
                    if (!name.equals(HttpHeaders.ContentType, ignoreCase = true)) header(name, value)
                }
                setBody(ByteArrayContent(body.encodeToByteArray(), ContentType.Application.Json))
            }.execute { response ->
                // Blok bitince Ktor kalan gövdeyi indirmeden isteği sonlandırır.
                val limited = readLimited(response.bodyAsChannel())
                TransportResponse(response.status.value, limited.decodeToString(), response.headers[HttpHeaders.RetryAfter])
            }
        } catch (error: CancellationException) {
            // Çağıran iptal edildiyse iptal yayılır; yalnız isteğin kendisi iptal olduysa (zaman aşımı) ağ hatasıdır.
            currentCoroutineContext().ensureActive()
            throw TransportException("ağ hatası: istek iptal oldu")
        } catch (error: Exception) {
            // Mesaj ağ katmanından gelir; adres içerebilir ama başlık ve anahtar içermez.
            throw TransportException("ağ hatası: ${error.message ?: error::class.simpleName}")
        }
    }

    /** Bozuk veya kötü niyetli sunucu belleği dolduramasın diye gövde indirme sırasında sınırlanır. */
    private suspend fun readLimited(channel: ByteReadChannel): ByteArray {
        val buffer = ByteArray(MAX_RESPONSE_BODY)
        var total = 0
        while (total < MAX_RESPONSE_BODY) {
            val read = channel.readAvailable(buffer, total, MAX_RESPONSE_BODY - total)
            if (read < 0) break
            total += read
        }
        return buffer.copyOf(total)
    }
}
