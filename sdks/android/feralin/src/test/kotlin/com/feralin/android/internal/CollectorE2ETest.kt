package com.feralin.android.internal

import com.feralin.android.Consent
import com.feralin.android.FeralinConfig
import com.feralin.android.FlushResult
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Gerçek `services/collect` ile uçtan uca. Yalnız FERALIN_E2E_COLLECT_URL ve FERALIN_E2E_PROJECT_KEY tanımlıysa
 * koşar; yoksa atlanır ve bu atlanma "doğrulandı" sayılmaz. Çalıştırma: sdks/android/scripts/e2e-collect.sh
 *
 * Veritabanı paylaşımlıdır: başka bir süreç aynı anda satır yazabilir veya yayımlayabilir. Bu yüzden testler sayaç
 * farkına bakmaz; kendi batch_id ve event_id değerlerini build/e2e/android-outbox-checks.txt dosyasına yazar,
 * betik bunları outbox_check.go ile satır bazında doğrular.
 */
class CollectorE2ETest {
    private val collectUrl = System.getenv("FERALIN_E2E_COLLECT_URL")
    private val projectKey = System.getenv("FERALIN_E2E_PROJECT_KEY")
    private val referrerWithClick = "fr_click=e2e_click_android_00000001&utm_source=e2e&gclid=atilmali"

    @Before
    fun requireCollector() {
        assumeTrue(
            "FERALIN_E2E_COLLECT_URL/FERALIN_E2E_PROJECT_KEY tanımlı değil",
            !collectUrl.isNullOrBlank() && !projectKey.isNullOrBlank(),
        )
    }

    private class CountingTransport(private val inner: Transport) : Transport {
        val calls = AtomicInteger(0)
        override fun post(url: String, headers: Map<String, String>, body: String): TransportResponse {
            calls.incrementAndGet()
            return inner.post(url, headers, body)
        }
    }

    private fun engine(
        consent: Consent?,
        store: EventStore = MemoryEventStore(),
        transport: Transport = HttpUrlTransport(),
        key: String = projectKey!!,
        referrer: String? = referrerWithClick,
    ): FeralinEngine {
        val created = FeralinEngine(
            config = FeralinConfig(projectKey = key, collectUrl = collectUrl!!, consent = consent),
            storeProvider = { store },
            transport = transport,
            referrer = { it(AttributionParams.parseQuery(referrer)) },
            appContext = { AppContext("tr-TR", "Europe/Istanbul", "0.1.0", "1") },
            state = ExecutorWorker("e2e-state", log = {}),
            net = ExecutorWorker("e2e-net", log = {}),
            sdkVersion = "0.1.0-e2e",
        )
        created.start()
        return created
    }

    private fun FeralinEngine.flushAndWait(): FlushResult {
        val latch = CountDownLatch(1)
        var result: FlushResult? = null
        flush {
            result = it
            latch.countDown()
        }
        assertTrue("flush zaman aşımı", latch.await(20, TimeUnit.SECONDS))
        return result!!
    }

    /** Durum sırasındaki işler bitene kadar gönderir; ilk açılış okuması sıraya sonradan girebilir. */
    private fun FeralinEngine.drain(store: EventStore): List<FlushResult> {
        val results = ArrayList<FlushResult>()
        repeat(6) {
            results.add(flushAndWait())
            Thread.sleep(50)
        }
        assertEquals("kuyruk boşalmalı", 0, store.size())
        return results.filter { it.status != 0 }
    }

    private fun stats(): JSONObject {
        val connection = URL(collectUrl!!.trimEnd('/') + "/v1/stats").openConnection() as HttpURLConnection
        connection.inputStream.use { return JSONObject(it.readBytes().toString(Charsets.UTF_8)) }
    }

    private fun rawBatch(key: String, body: String, idempotencyKey: String): Pair<Int, String> {
        val connection = URL(collectUrl!!.trimEnd('/') + "/v1/batch").openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        connection.setRequestProperty("x-feralin-project-key", key)
        connection.setRequestProperty("Idempotency-Key", idempotencyKey)
        connection.outputStream.use { it.write(body.toByteArray()) }
        val status = connection.responseCode
        val stream = if (status >= 400) connection.errorStream else connection.inputStream
        return status to stream.use { it.readBytes().toString(Charsets.UTF_8) }
    }

    private fun rawEvent(id: String, consent: String) =
        """{"events":[{"event_id":"$id","event_name":"e2e_raw","occurred_at":"${EventJson.formatTime(System.currentTimeMillis())}","platform":"android","schema_version":1,"consent":$consent}]}"""

    @Synchronized
    private fun record(line: String) {
        File("build/e2e").mkdirs()
        File("build/e2e/android-outbox-checks.txt").appendText(line + "\n")
    }

    @Test
    fun reklamIzniyleFrClickOutboxaYazilir() {
        assertEquals("postgres", stats().getString("outbox"))
        val store = MemoryEventStore()
        val sdk = engine(Consent(analytics = true, advertising = true), store)
        val eventId = sdk.track("e2e_android_purchase", mapOf("amount" to 12.5, "currency" to "TRY"))
        assertNotNull(eventId)
        sdk.handleLink("https://go.example.com/o/e2e?fr_click=e2e_click_android_link0001&utm_campaign=yaz&token=GIZLI")

        val results = sdk.drain(store)
        assertTrue(results.all { it.status == 202 })
        assertEquals(3, results.sumOf { it.sent })
        assertEquals(3, results.sumOf { it.accepted })
        results.forEach { record("frclick ${it.batchId}") }
    }

    @Test
    fun yalnizAnalitikIzniyleFrClickGitmez() {
        val store = MemoryEventStore()
        val sdk = engine(Consent(analytics = true), store)
        sdk.handleLink("https://go.example.com/o/e2e?fr_click=e2e_click_android_noad0001&token=GIZLI")
        val results = sdk.drain(store)
        assertTrue(results.all { it.status == 202 })
        assertEquals(2, results.sumOf { it.accepted })
        results.forEach { record("nofrclick ${it.batchId}") }
    }

    @Test
    fun izinsizOlayIcinHicIstekYapilmaz() {
        for (consent in listOf(null, Consent(analytics = false))) {
            val transport = CountingTransport(HttpUrlTransport())
            val sdk = engine(consent, transport = transport)
            assertNull(sdk.track("e2e_no_consent", null))
            assertEquals(FlushResult.NONE, sdk.flushAndWait())
            assertEquals(0, transport.calls.get())
        }
    }

    @Test
    fun ayniIdempotencyTekrariAyniBatchiDondurur() {
        val id = "01JE2EDUP" + System.currentTimeMillis().toString().padStart(17, '0')
        val body = rawEvent(id, """{"analytics":true}""")
        val key = Idempotency.keyFor(listOf(id))
        val (firstStatus, firstBody) = rawBatch(projectKey!!, body, key)
        assertEquals(202, firstStatus)
        val (secondStatus, secondBody) = rawBatch(projectKey, body, key)
        assertEquals(202, secondStatus)
        assertEquals(JSONObject(firstBody).getString("batch_id"), JSONObject(secondBody).getString("batch_id"))
        // İdempotency tekrarında yanıt ilk kabulün olay sayısını taşır (ölçüm denetimi madde 32).
        assertEquals(1, JSONObject(secondBody).getInt("accepted"))
        record("once $id")
    }

    @Test
    fun sunucuIzinsizOlayiReddeder() {
        val id = "01JE2ENOCONSENT" + System.currentTimeMillis().toString().padStart(11, '0')
        val (status, text) = rawBatch(projectKey!!, rawEvent(id, """{"analytics":false}"""), Idempotency.keyFor(listOf(id)))
        assertEquals(202, status)
        val json = JSONObject(text)
        assertEquals(0, json.getInt("accepted"))
        assertEquals(1, json.getInt("rejected"))
        assertEquals(1, json.getJSONObject("rejected_reasons").getInt("consent_denied"))
        record("absent $id")
    }

    @Test
    fun yanlisAnahtarKaliciRettirOlaylarAtilir() {
        val store = MemoryEventStore()
        val sdk = engine(Consent(analytics = true), store, key = "pk_test_yanlis_anahtar")
        val results = sdk.drain(store)
        assertEquals(listOf(401), results.map { it.status }.distinct())
    }
}
