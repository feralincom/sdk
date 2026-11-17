package com.feralin.kmp

import kotlin.time.Duration
import kotlin.time.TimeSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

internal const val TEST_KEY = "pk_test_kmp_0001"
internal const val TEST_COLLECT = "https://collect.example.test"

internal sealed interface Step {
    data class Respond(val status: Int, val body: String = "{}", val retryAfter: String? = null) : Step
    data class Fail(val message: String) : Step
}

internal class SeenRequest(val url: String, val body: JsonObject, val headers: Map<String, String>) {
    val events: List<JsonObject> get() = body.getValue("events").jsonArray.map { it.jsonObject }
    val eventIds: List<String> get() = events.map { it.getValue("event_id").jsonPrimitive.content }
}

/** Sahte toplayıcı: istekleri kaydeder, sıradaki yanıtı döner; sıra bitince 202. */
internal class FakeCollector(steps: List<Step> = emptyList()) : Transport {
    private val lock = createLock()
    private val steps = ArrayDeque(steps)
    private val seen = ArrayList<SeenRequest>()

    val count: Int get() = lock.withLock { seen.size }

    fun request(index: Int): SeenRequest = lock.withLock { seen[index] }

    override suspend fun post(url: String, body: String, headers: Map<String, String>, timeoutMillis: Long): TransportResponse {
        val parsed = Json.parseToJsonElement(body).jsonObject
        val request = SeenRequest(url, parsed, headers)
        val step = lock.withLock {
            seen.add(request)
            steps.removeFirstOrNull()
        }
        return when (step) {
            is Step.Respond -> TransportResponse(step.status, step.body, step.retryAfter)
            is Step.Fail -> throw TransportException(step.message)
            null -> TransportResponse(202, "{\"accepted\":${request.events.size},\"rejected\":0,\"batch_id\":\"01TESTBATCH0000000000000000\"}")
        }
    }
}

internal val ANALYTICS = Consent(analytics = true)

internal fun config(
    consent: Consent = ANALYTICS,
    flushIntervalMillis: Long = 0,
    batchSize: Int = 100,
    queueLimit: Int = 1000,
): FeralinConfig = FeralinConfig(TEST_KEY, TEST_COLLECT, consent, flushIntervalMillis, batchSize, queueLimit)

/** `runTest` sanal saati `delay`'i atlar; arka plan göndericisi gerçek saatte çalıştığından bekleme de gerçek saatte yapılır. */
internal suspend fun eventually(limit: Duration, condition: () -> Boolean): Boolean = withContext(Dispatchers.Default) {
    val start = TimeSource.Monotonic.markNow()
    while (start.elapsedNow() < limit) {
        if (condition()) return@withContext true
        delay(5)
    }
    condition()
}

internal suspend fun realDelay(millis: Long) = withContext(Dispatchers.Default) { delay(millis) }
