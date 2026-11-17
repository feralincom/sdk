package com.feralin.kmp

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

class FeralinClientTest {
    private fun client(collector: Transport, config: FeralinConfig = config()) = FeralinClient(config, collector)

    @Test
    fun rejectsSecretAndNonPublicKeys() {
        val collector = FakeCollector()
        assertFailsWith<FeralinException.Configuration> { FeralinClient(FeralinConfig("sk_live_abcdefgh", TEST_COLLECT), collector) }
        assertFailsWith<FeralinException.Configuration> { FeralinClient(FeralinConfig("dev_key_change_me_0001", TEST_COLLECT), collector) }
        assertFailsWith<FeralinException.Configuration> { FeralinClient(FeralinConfig("", TEST_COLLECT), collector) }
    }

    @Test
    fun installCodeGoesOnlyOnFirstConsentedEvent() {
        val consented = FeralinClient(FeralinConfig(TEST_KEY, TEST_COLLECT, consent = Consent(analytics = true), flushIntervalMillis = 0, installCode = " K7M2-Q9XR4 "), FakeCollector())
        val first = assertNotNull(consented.track("ilk_olay", mapOf("a" to 1)))
        assertEquals("K7M2-Q9XR4", first.payload["properties"]!!.jsonObject[INSTALL_CODE_PROPERTY]!!.jsonPrimitive.content)
        val second = assertNotNull(consented.track("ikinci_olay"))
        assertNull(second.payload["properties"]?.jsonObject?.get(INSTALL_CODE_PROPERTY))
        // İzin yokken kod harcanmaz; izin gelince ilk olaya eklenir.
        val waiting = FeralinClient(FeralinConfig(TEST_KEY, TEST_COLLECT, flushIntervalMillis = 0, installCode = "K7M2-Q9XR4"), FakeCollector())
        assertNull(waiting.track("olay"))
        waiting.setConsent(Consent(analytics = true))
        assertEquals("K7M2-Q9XR4", assertNotNull(waiting.track("olay")).payload["properties"]!!.jsonObject[INSTALL_CODE_PROPERTY]!!.jsonPrimitive.content)
        // Biçimi geçersiz kod yok sayılır.
        val bad = FeralinClient(FeralinConfig(TEST_KEY, TEST_COLLECT, consent = Consent(analytics = true), flushIntervalMillis = 0, installCode = "x;DROP"), FakeCollector())
        assertNull(assertNotNull(bad.track("olay")).payload["properties"]?.jsonObject?.get(INSTALL_CODE_PROPERTY))
    }

    @Test
    fun rejectsBadCollectUrl() {
        val collector = FakeCollector()
        assertFailsWith<FeralinException.Configuration> { FeralinClient(FeralinConfig(TEST_KEY, "collect.example.test"), collector) }
        assertFailsWith<FeralinException.Configuration> { FeralinClient(FeralinConfig(TEST_KEY, "ftp://collect.example.test"), collector) }
        assertFailsWith<FeralinException.Configuration> { FeralinClient(FeralinConfig(TEST_KEY, "https://"), collector) }
    }

    @Test
    fun endpointBuiltFromRootAndKeyHiddenFromTextForms() {
        val configuration = FeralinConfig(TEST_KEY, "https://collect.example.test/", flushIntervalMillis = 0)
        val status = FeralinClient(configuration, FakeCollector()).status()
        assertEquals("https://collect.example.test/v1/batch", status.endpoint)
        assertFalse(status.toString().contains("pk_"))
        assertFalse(configuration.toString().contains("pk_"))
    }

    @Test
    fun trackAndFlushAccepted() = runTest {
        val collector = FakeCollector()
        val client = client(collector)
        client.identify("user_42")
        val event = assertNotNull(
            client.track(
                "order_completed",
                mapOf("order_id" to "ord_1", "amount" to 12.5, "items" to 2),
                anonymousId = "anon_1",
                sessionId = "ses_1",
                context = EventContext(locale = "tr-TR", timezone = "Europe/Istanbul", app = AppInfo(version = "1.2.3")),
            ),
        )
        assertEquals("user_42", event.payload.getValue("user_id").jsonPrimitive.content)
        assertEquals(1, client.queued)

        val result = client.flush()
        assertTrue(result.ok, "${result.error}")
        assertEquals(202, result.status)
        assertEquals(1, result.sent)
        assertEquals(1, result.accepted)
        assertEquals(0, result.rejected)
        assertEquals("01TESTBATCH0000000000000000", result.batchId)
        assertEquals(0, client.queued)
        assertEquals(1, collector.count)

        val request = collector.request(0)
        assertEquals("https://collect.example.test/v1/batch", request.url)
        assertEquals(TEST_KEY, request.headers["X-Feralin-Project-Key"])
        assertEquals(idempotencyKeyFor(listOf(event.eventId)), request.headers["Idempotency-Key"])
        assertEquals("application/json", request.headers["Content-Type"])
        assertTrue(request.body.getValue("sent_at").jsonPrimitive.isString)

        val wire = request.events.single()
        assertEquals(event.eventId, wire.getValue("event_id").jsonPrimitive.content)
        assertTrue(isUlid(event.eventId))
        assertEquals(platformName, wire.getValue("platform").jsonPrimitive.content)
        assertEquals(1, wire.getValue("schema_version").jsonPrimitive.int)
        assertEquals(SDK_NAME, wire.getValue("sdk").jsonObject.getValue("name").jsonPrimitive.content)
        assertEquals("anon_1", wire.getValue("anonymous_id").jsonPrimitive.content)
        assertEquals("ses_1", wire.getValue("session_id").jsonPrimitive.content)
        val properties = wire.getValue("properties").jsonObject
        assertEquals("ord_1", properties.getValue("order_id").jsonPrimitive.content)
        assertEquals(12.5, properties.getValue("amount").jsonPrimitive.double)
        assertEquals(2, properties.getValue("items").jsonPrimitive.int)
        val context = wire.getValue("context").jsonObject
        assertEquals("tr-TR", context.getValue("locale").jsonPrimitive.content)
        assertEquals("1.2.3", context.getValue("app").jsonObject.getValue("version").jsonPrimitive.content)
        val consent = wire.getValue("consent").jsonObject
        assertTrue(consent.getValue("analytics").jsonPrimitive.boolean)
        assertFalse(consent.getValue("advertising").jsonPrimitive.boolean)
        for (forbidden in listOf("tenant_id", "project_id", "verified", "source_ip", "ip")) {
            assertFalse(wire.containsKey(forbidden), "gönderilmemeli: $forbidden")
        }
    }

    @Test
    fun optionalFieldsAreOmitted() {
        val event = assertNotNull(client(FakeCollector()).track("signup"))
        for (key in listOf("user_id", "anonymous_id", "session_id", "properties", "context")) {
            assertFalse(event.payload.containsKey(key), key)
        }
    }

    @Test
    fun idempotencyKeyMatchesOtherSdks() {
        assertEquals("8f95d6b736d56c98-2", idempotencyKeyFor(listOf("01JC0000000000000000000002", "01JC0000000000000000000001")))
    }

    @Test
    fun temporaryFailureKeepsQueueAndIdempotencyKey() = runTest {
        val collector = FakeCollector(
            listOf(
                Step.Respond(503, "{\"title\":\"Outbox yazılamadı\"}", "5"),
                Step.Respond(429, "{\"title\":\"Çok fazla istek\"}", "1"),
            ),
        )
        val client = client(collector)
        val event = assertNotNull(client.track("signup"))

        var result = client.flush()
        assertEquals(DeliveryError.Temporary(503, "olaylar kuyrukta tutuldu"), result.error)
        assertEquals(1, result.retained)
        assertEquals(5, client.status().backoffSeconds)

        result = client.flush()
        assertEquals(429, result.error?.status)
        assertEquals(10, client.status().backoffSeconds)
        assertEquals(1, client.queued)

        result = client.flush()
        assertTrue(result.ok)
        assertEquals(202, result.status)
        assertEquals(0, client.status().backoffSeconds)
        assertEquals(0, client.queued)

        assertEquals(3, collector.count)
        val expected = idempotencyKeyFor(listOf(event.eventId))
        for (index in 0..2) assertEquals(expected, collector.request(index).headers["Idempotency-Key"])
    }

    @Test
    fun backoffIsExponentialAndCapped() = runTest {
        val client = client(FakeCollector(List(7) { Step.Respond(503) }))
        client.track("signup")
        val seen = ArrayList<Long>()
        repeat(7) {
            client.flush()
            seen.add(client.status().backoffSeconds)
        }
        assertEquals(listOf(1L, 2L, 4L, 8L, 16L, 30L, 30L), seen)
    }

    @Test
    fun frClickRequiresAdvertisingConsent() {
        val client = client(FakeCollector())
        var event = assertNotNull(client.track("order_completed", mapOf("fr_click" to "clk", "order_id" to "o1")))
        assertEquals(setOf("order_id"), event.payload.getValue("properties").jsonObject.keys)
        event = assertNotNull(client.track("order_completed", mapOf("fr_click" to "clk")))
        assertFalse(event.payload.containsKey("properties"))
        client.setConsent(Consent(analytics = true, advertising = true))
        event = assertNotNull(client.track("order_completed", mapOf("fr_click" to "clk")))
        assertEquals("clk", event.payload.getValue("properties").jsonObject.getValue("fr_click").jsonPrimitive.content)
    }

    @Test
    fun pinnedBatchKeepsContentAcrossRetries() = runTest {
        val collector = FakeCollector(listOf(Step.Fail("yanıt yolda kayboldu")))
        val client = client(collector)
        val first = assertNotNull(client.track("first_event"))
        assertFalse(client.flush().ok)
        val second = assertNotNull(client.track("second_event"))
        assertTrue(client.flush().ok)
        assertEquals(3, collector.count)
        val key = idempotencyKeyFor(listOf(first.eventId))
        assertEquals(key, collector.request(0).headers["Idempotency-Key"])
        assertEquals(key, collector.request(1).headers["Idempotency-Key"])
        assertEquals(idempotencyKeyFor(listOf(second.eventId)), collector.request(2).headers["Idempotency-Key"])
    }

    @Test
    fun networkErrorKeepsQueue() = runTest {
        val client = client(FakeCollector(listOf(Step.Fail("ağ hatası: bağlantı yok"))))
        client.track("ping")
        val result = client.flush()
        assertEquals(DeliveryError.Temporary(0, "ağ hatası: bağlantı yok"), result.error)
        assertEquals(0, result.status)
        assertEquals(1, client.queued)
        assertEquals(1, client.status().backoffSeconds)
    }

    @Test
    fun permanentRejectionDropsEvents() = runTest {
        val collector = FakeCollector(listOf(Step.Respond(401, "{\"title\":\"Geçersiz anahtar\",\"detail\":\"x\"}")))
        val client = client(collector)
        client.track("order_completed")
        val result = client.flush()
        assertEquals(DeliveryError.Rejected(401, "Geçersiz anahtar x"), result.error)
        assertEquals(1, result.rejected)
        assertEquals(0, client.queued)
        assertTrue(client.flush().ok)
        assertEquals(1, collector.count, "atılan olay yeniden gönderilmemeli")
    }

    @Test
    fun consentGate() = runTest {
        val collector = FakeCollector()
        val client = client(collector, config(consent = Consent()))
        assertNull(client.track("page_view"))
        assertEquals(0, client.queued)

        client.setConsent(ANALYTICS)
        assertNotNull(client.track("page_view"))
        assertEquals(1, client.queued)

        client.setConsent(Consent())
        assertEquals(0, client.queued, "izin geri çekilince kuyruk temizlenmeli")
        assertTrue(client.flush().ok)
        assertEquals(0, collector.count, "izin yokken sunucuya istek gitmemeli")
    }

    @Test
    fun consentWithdrawnDuringRequestDoesNotPin() = runTest {
        lateinit var client: FeralinClient
        val transport = Transport { _, _, _, _ ->
            client.setConsent(Consent())
            TransportResponse(503)
        }
        client = client(transport)
        client.track("e")
        assertFalse(client.flush().ok)
        assertEquals(0, client.queued)
        assertEquals(0, client.flush().sent)
    }

    @Test
    fun validation() {
        val client = client(FakeCollector())
        for (name in listOf("", "orderCompleted", "1_event", "a".repeat(101), "has-dash")) {
            assertFailsWith<FeralinException.InvalidEvent>(name) { client.track(name) }
        }
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", mapOf("1bad" to 1)) }
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", mapOf("bad-key" to 1)) }
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", mapOf("a" + "b".repeat(64) to 1)) }
        val many = (0 until 101).associate { "k$it" to it }
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", many) }
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", userId = "u".repeat(129)) }
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", mapOf("obj" to Any())) }
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", mapOf("nan" to Double.NaN)) }
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", mapOf("inf" to Float.POSITIVE_INFINITY)) }
        // Döngüsel yapı yığın taşması (Error) ile süreci düşürmez, geçersiz olay olarak reddedilir.
        val cyclicMap = HashMap<String, Any?>()
        cyclicMap["self"] = cyclicMap
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", mapOf("dongu" to cyclicMap)) }
        val cyclicList = ArrayList<Any?>()
        cyclicList.add(cyclicList)
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", mapOf("dongu" to cyclicList)) }
        var deep: Any? = "yaprak"
        repeat(40) { deep = listOf(deep) }
        assertFailsWith<FeralinException.InvalidEvent> { client.track("ok", mapOf("derin" to deep)) }
        assertFailsWith<FeralinException.InvalidEvent> { client.identify("u".repeat(129)) }
        assertEquals(0, client.queued, "geçersiz olaylar kuyruğa girmemeli")

        assertNotNull(client.track("ok", many - "k100"))
        assertNotNull(client.track("fr_system_event_9", mapOf("Camel_Key9" to "x")))
        assertEquals(2, client.queued)
    }

    @Test
    fun propertyTypesConvert() {
        val client = client(FakeCollector())
        val direct = buildJsonObject { put("x", 1) }
        val event = assertNotNull(
            client.track(
                "types",
                mapOf(
                    "text" to "a",
                    "flag" to true,
                    "whole" to 3L,
                    "none" to null,
                    "list" to listOf(1, "b"),
                    "nested" to mapOf("k" to 2),
                    "json" to direct,
                ),
            ),
        )
        val properties = event.payload.getValue("properties").jsonObject
        assertEquals(JsonPrimitive("a"), properties["text"])
        assertEquals(JsonPrimitive(true), properties["flag"])
        assertEquals(JsonPrimitive(3L), properties["whole"])
        assertEquals(JsonNull, properties["none"])
        assertEquals(2, properties.getValue("list").jsonArray.size)
        assertEquals(2, properties.getValue("nested").jsonObject.getValue("k").jsonPrimitive.int)
        assertEquals(direct, properties["json"])
    }

    @Test
    fun queueLimitDropsOldest() = runTest {
        val collector = FakeCollector()
        val client = client(collector, config(batchSize = 10, queueLimit = 3))
        val ids = List(5) { assertNotNull(client.track("e")).eventId }
        assertEquals(3, client.queued)
        assertEquals(2, client.status().dropped)
        assertTrue(client.flush().ok)
        assertEquals(ids.drop(2), collector.request(0).eventIds)
    }

    @Test
    fun batchSplitting() = runTest {
        val collector = FakeCollector()
        val client = client(collector, config(batchSize = 2, queueLimit = 100))
        repeat(5) { client.track("e") }
        val result = client.flush()
        assertTrue(result.ok)
        assertEquals(5, result.sent)
        assertEquals(5, result.accepted)
        assertEquals(0, client.queued)
        assertEquals(3, collector.count)
        val first = collector.request(0)
        assertEquals(2, first.eventIds.size)
        assertEquals(idempotencyKeyFor(first.eventIds), first.headers["Idempotency-Key"])
        assertEquals(1, collector.request(2).eventIds.size)
    }

    @Test
    fun backgroundFlush() = runTest {
        val collector = FakeCollector()
        val client = client(collector, config(flushIntervalMillis = 20))
        client.track("bg")
        assertTrue(eventually(3.seconds) { client.queued == 0 }, "arka plan gönderici 3 sn içinde göndermedi")
        assertTrue(collector.count >= 1)
        client.close(1_000)
    }

    @Test
    fun fullBatchWakesBackgroundFlush() = runTest {
        val collector = FakeCollector()
        val client = client(collector, config(flushIntervalMillis = 3_600_000, batchSize = 2))
        client.track("a")
        client.track("b")
        assertTrue(eventually(3.seconds) { collector.count == 1 }, "dolu batch göndericiyi uyandırmalı")
        client.close(1_000)
    }

    @Test
    fun backgroundFlushRespectsBackoff() = runTest {
        val collector = FakeCollector(listOf(Step.Respond(503)))
        val client = client(collector, config(flushIntervalMillis = 10))
        client.track("bg")
        assertTrue(eventually(3.seconds) { collector.count == 1 })
        realDelay(150)
        assertEquals(1, collector.count, "geri çekilme sırasında yeniden deneme olmamalı")
        assertEquals(1, client.queued)
        client.setConsent(Consent())
        client.close(1_000)
    }

    @Test
    fun closeFlushesAndBlocksTrack() = runTest {
        val collector = FakeCollector()
        val client = client(collector)
        repeat(3) { client.track("e") }
        val result = client.close()
        assertTrue(result.ok)
        assertEquals(1, collector.count)
        assertEquals(3, collector.request(0).eventIds.size)
        assertEquals(0, client.queued)
        assertTrue(client.status().closed)
        assertFailsWith<FeralinException.ClientClosed> { client.track("late") }
        assertFailsWith<FeralinException.ClientClosed> { client.flush() }
        assertTrue(client.close().ok, "ikinci close hatasız olmalı")
    }

    @Test
    fun closeReportsUndelivered() = runTest {
        val client = client(FakeCollector(listOf(Step.Respond(503))))
        client.track("e")
        val result = client.close(1_000)
        assertIs<DeliveryError.Temporary>(result.error)
        assertEquals(1, result.retained)
    }

    @Test
    fun concurrentTrackKeepsEveryEvent() = runTest {
        val collector = FakeCollector()
        val client = client(collector, config(batchSize = MAX_BATCH_SIZE, queueLimit = 5000))
        withContext(Dispatchers.Default) {
            repeat(8) {
                launch { repeat(100) { client.track("c") } }
            }
        }
        assertEquals(800, client.queued)
        val result = client.flush()
        assertTrue(result.ok)
        assertEquals(800, result.accepted)
        assertEquals(0, client.queued)
        assertEquals(2, collector.count)
        val ids = collector.request(0).eventIds + collector.request(1).eventIds
        assertEquals(800, ids.toSet().size)
    }

    @Test
    fun occurredAtUsesInjectedClock() {
        val client = FeralinClient(config(), FakeCollector(), now = { 1_793_703_600_123L })
        var event = assertNotNull(client.track("clock"))
        assertEquals("2026-11-03T11:00:00.123Z", event.payload.getValue("occurred_at").jsonPrimitive.content)
        event = assertNotNull(client.track("clock", occurredAtMillis = 1_767_323_045_000L))
        assertEquals("2026-01-02T03:04:05.000Z", event.payload.getValue("occurred_at").jsonPrimitive.content)
    }

    @Test
    fun formatTimeHandlesCalendarEdges() {
        assertEquals("1970-01-01T00:00:00.000Z", formatTime(0))
        assertEquals("2024-02-29T00:00:00.000Z", formatTime(1_709_164_800_000))
        assertEquals("2024-12-31T23:59:59.999Z", formatTime(1_735_689_599_999))
    }
}
