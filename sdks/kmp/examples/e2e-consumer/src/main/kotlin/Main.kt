// Gerçek services/collect tüketicisi: scripts/sdk-e2e/run.mjs kmp tarafından çalıştırılır.
// Denetim satırları sdks/android/scripts/outbox_check.go ile PostgreSQL üzerinde doğrulanır.
import com.feralin.kmp.Consent
import com.feralin.kmp.DeliveryError
import com.feralin.kmp.FeralinClient
import com.feralin.kmp.FeralinConfig
import com.feralin.kmp.KtorTransport
import com.feralin.kmp.Transport
import com.feralin.kmp.TransportException
import com.feralin.kmp.TransportResponse
import com.feralin.kmp.idempotencyKeyFor
import java.io.File
import kotlin.system.exitProcess
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

private val collectUrl = System.getenv("FERALIN_E2E_COLLECT_URL")
private val projectKey = System.getenv("FERALIN_E2E_PROJECT_KEY")
private val checks = File(System.getenv("FERALIN_E2E_CHECKS"))

private fun must(condition: Boolean, message: String) {
    if (!condition) {
        System.err.println("KALDI: $message")
        exitProcess(1)
    }
}

private fun expect(line: String) = checks.appendText("$line\n")

private fun make(key: String = projectKey, consent: Consent = Consent(), transport: Transport? = null): FeralinClient {
    val config = FeralinConfig(key, collectUrl, consent, flushIntervalMillis = 0)
    return if (transport == null) FeralinClient(config) else FeralinClient(config, transport)
}

fun main(): Unit = runBlocking<Unit> {
    val analytics = Consent(analytics = true)

    // 202 + outbox satırı + fr_click reklam izniyle
    var client = make(consent = Consent(analytics = true, advertising = true))
    val first = client.track("order_completed", mapOf("order_id" to "ord_kmp_1", "fr_click" to "clk_kmp_1"), userId = "user_kmp_1")
    var result = client.flush()
    must(first != null && result.status == 202 && result.accepted == 1, "202 bekleniyordu")
    expect("frclick ${result.batchId}")
    expect("once ${first!!.eventId}")
    println("  OK 202-outbox-frclick: ${result.status} ${result.batchId}")

    // Reklam izni yok: fr_click çıkarılır
    client = make(consent = analytics)
    val second = client.track("order_completed", mapOf("order_id" to "ord_kmp_2", "fr_click" to "clk_kmp_2"))
    must(second != null && second.payload.getValue("properties").jsonObject["fr_click"] == null, "fr_click çıkarılmalıydı")
    result = client.flush()
    must(result.status == 202, "202 bekleniyordu")
    expect("nofrclick ${result.batchId}")
    println("  OK frclick-izinsiz-cikarildi: ${result.status}")

    // İzinsiz: SDK olay üretmez
    client = make()
    must(client.track("order_completed") == null && client.flush().sent == 0, "izinsiz olay üretilmemeliydi")
    println("  OK izinsiz-sdk-uretmez: 0")

    // İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
    val rawId = ("01JCKT" + System.nanoTime().toString().padStart(20, '0')).take(26)
    val rawBody = """{"events":[{"event_id":"$rawId","event_name":"denied_event","occurred_at":"2026-11-06T10:00:00Z","platform":"java","schema_version":1,"consent":{"analytics":false}}]}"""
    val raw = KtorTransport().post(
        "$collectUrl/v1/batch",
        rawBody,
        mapOf("X-Feralin-Project-Key" to projectKey, "Idempotency-Key" to idempotencyKeyFor(listOf(rawId))),
        10_000,
    )
    val denied = Json.parseToJsonElement(raw.body).jsonObject
    must(
        raw.status == 202 &&
            denied.getValue("accepted").jsonPrimitive.int == 0 &&
            denied.getValue("rejected_reasons").jsonObject.getValue("consent_denied").jsonPrimitive.int == 1,
        "toplayıcı izinsiz olayı reddetmeliydi",
    )
    expect("absent $rawId")
    println("  OK izinsiz-toplayici-red: $denied")

    // Yanlış anahtar: 401, olay atılır, uygulama düşmez
    client = make(key = "pk_test_wrong_key_000", consent = analytics)
    val wrong = client.track("order_completed", mapOf("order_id" to "ord_kmp_wrong"))
    result = client.flush()
    must(result.error is DeliveryError.Rejected && result.status == 401 && result.rejected == 1 && client.queued == 0, "401 bekleniyordu")
    expect("absent ${wrong!!.eventId}")
    println("  OK yanlis-anahtar-401: ${result.status}")

    // Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
    val keys = ArrayList<String>()
    val real = KtorTransport()
    val lossy = Transport { url, body, headers, timeout ->
        keys.add(headers.getValue("Idempotency-Key"))
        val response: TransportResponse = real.post(url, body, headers, timeout)
        if (keys.size == 1) throw TransportException("yanıt yolda kayboldu")
        response
    }
    client = make(consent = analytics, transport = lossy)
    val retried = client.track("order_completed", mapOf("order_id" to "ord_kmp_retry"))
    val lost = client.flush()
    must(lost.error is DeliveryError.Temporary && client.queued == 1, "yanıt kaybı kuyrukta tutulmalıydı")
    val following = client.track("order_shipped", mapOf("order_id" to "ord_kmp_retry"))
    result = client.flush()
    must(result.ok && result.status == 202 && client.queued == 0, "tekrar 202 vermeliydi")
    must(keys.size == 3 && keys[0] == keys[1], "aynı anahtar bekleniyordu")
    expect("once ${retried!!.eventId}")
    expect("once ${following!!.eventId}")
    println("  OK idempotency-tekrar: ${keys[0]}")

    println("kmp tüketici: tüm senaryolar geçti")
    // Ktor motorlarının iş parçacıkları süreci açık tutmasın.
    exitProcess(0)
}
