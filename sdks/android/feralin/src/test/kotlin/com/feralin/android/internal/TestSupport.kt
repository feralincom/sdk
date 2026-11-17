package com.feralin.android.internal

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException

/** Deterministik sıra: görevler `drain` ile, gecikmeliler sanal saatle çalışır. */
internal class ManualWorker : Worker {
    var now = 1_780_000_000_000L
    private val ready = ArrayDeque<() -> Unit>()
    private data class Delayed(val at: Long, val task: () -> Unit, var cancelled: Boolean = false)
    private val delayed = ArrayList<Delayed>()

    override fun execute(task: () -> Unit) {
        ready.addLast(task)
    }

    override fun schedule(delayMs: Long, task: () -> Unit): Cancellable {
        val item = Delayed(now + delayMs, task)
        delayed.add(item)
        return Cancellable { item.cancelled = true }
    }

    fun drain() {
        while (ready.isNotEmpty()) ready.removeFirst().invoke()
    }

    fun pendingDelays(): List<Long> = delayed.filter { !it.cancelled }.map { it.at - now }

    fun advance(ms: Long) {
        val target = now + ms
        while (true) {
            val next = delayed.filter { !it.cancelled && it.at <= target }.minByOrNull { it.at } ?: break
            delayed.remove(next)
            now = maxOf(now, next.at)
            next.task()
            drain()
        }
        delayed.removeAll { it.cancelled }
        now = target
        drain()
    }
}

internal data class RecordedRequest(val url: String, val headers: Map<String, String>, val body: String) {
    val events: List<JSONObject>
        get() {
            val array: JSONArray = JSONObject(body).getJSONArray("events")
            return (0 until array.length()).map { array.getJSONObject(it) }
        }
}

/** Sıradaki yanıtları döner; yanıt yoksa 202. `null` ağ hatası demektir. */
internal class FakeTransport : Transport {
    val requests = ArrayList<RecordedRequest>()
    val responses = ArrayDeque<TransportResponse?>()

    override fun post(url: String, headers: Map<String, String>, body: String): TransportResponse {
        requests.add(RecordedRequest(url, headers, body))
        if (responses.isEmpty()) {
            val count = JSONObject(body).getJSONArray("events").length()
            return TransportResponse(202, """{"batch_id":"b1","accepted":$count,"rejected":0}""", null)
        }
        return responses.removeFirst() ?: throw IOException("ağ yok")
    }
}

internal fun JSONObject.props(): JSONObject = getJSONObject("properties")
