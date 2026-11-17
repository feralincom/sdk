package com.feralin.kmp

import kotlin.coroutines.cancellation.CancellationException
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeMark
import kotlin.time.TimeSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

const val SDK_NAME: String = "feralin-kmp"
const val SDK_VERSION: String = "0.1.0"
const val SCHEMA_VERSION: Int = 1
const val MAX_BATCH_SIZE: Int = 500

/** [FeralinClient] ayarları. Varsayılan izin hepsi kapalıdır. */
data class FeralinConfig(
    val projectKey: String,
    val collectUrl: String,
    val consent: Consent = Consent(),
    /** 0 ise arka plan gönderici başlatılmaz. */
    val flushIntervalMillis: Long = 2_000,
    /** 1 ile 500 arasına çekilir. */
    val batchSize: Int = 100,
    val queueLimit: Int = 1_000,
    val timeoutMillis: Long = 10_000,
    /**
     * Kurulum eşleştirme kodu: panelin "Kurulumu doğrula" ekranında üretilen tek kullanımlık kod. İzin verildikten sonra kuyruğa giren
     * ilk olaya `fr_install_code` olarak eklenir; sunucu kurulumu projeye bağlar. Biçimi geçersizse yok sayılır (Android SDK ile aynı kural).
     */
    val installCode: String? = null,
    /** Uygulama sürümü (1-32 karakter); yalnız `fr_error` olaylarının `app_version` alanına yazılır. */
    val appVersion: String? = null,
    /** `fr_error` örnekleme oranı 0..1; yalnız kayıp kabul edilen yüksek hacimde düşürün. */
    val errorSampleRate: Double = 1.0,
) {
    override fun toString(): String = "FeralinConfig(collectUrl=$collectUrl, consent=$consent)"
}

/** Kurulum eşleştirme kodu özelliği ve biçimi (toplayıcı `installcode.go` ile aynı). */
const val INSTALL_CODE_PROPERTY: String = "fr_install_code"
private val INSTALL_CODE_PATTERN = Regex("^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$")

private class Queued(val id: String, val raw: String)

/**
 * UTP v1 toplayıcısına (`POST /v1/batch`) olay gönderen, iş parçacığı güvenli istemci.
 *
 * İzin yoksa olay üretilmez, reklam izni yoksa `fr_click` çıkarılır. 202 → onay; 4xx (429 hariç) → olaylar atılır;
 * 5xx, 429 ve ağ hatası → kuyrukta kalır, aynı içerik aynı `Idempotency-Key` ile 1 sn → 30 sn geri çekilmeyle yeniden denenir.
 * Yalnız proje public anahtarı (`pk_…`) kabul edilir. `tenant_id`, `project_id` ve `verified` gönderilmez.
 */
class FeralinClient(
    config: FeralinConfig,
    private val transport: Transport = KtorTransport(),
    private val now: () -> Long = ::currentTimeMillis,
) {
    private val projectKey: String
    private val endpoint: String
    private val batchSize: Int = config.batchSize.coerceIn(1, MAX_BATCH_SIZE)
    private val queueLimit: Int = config.queueLimit.coerceAtLeast(1)
    private val timeoutMillis: Long = config.timeoutMillis
    private val ulid = UlidGenerator()
    private val appVersion: String? = config.appVersion?.takeIf { it.isNotEmpty() && it.length <= 32 }
    private val errorLimiter = ErrorLimiter(config.errorSampleRate.let { if (it.isNaN()) 1.0 else it.coerceIn(0.0, 1.0) })

    private val lock = createLock()
    private var consent: Consent = config.consent
    // Eşleştirme kodu yalnız ilk olaya eklenir; olay kuyruğa girmezse (izin geri çekildi) geri konur.
    private var pendingInstallCode: String? = config.installCode?.trim()?.takeIf { INSTALL_CODE_PATTERN.matches(it) }
    private val queue = ArrayList<Queued>()
    // Sonucu bilinmeyen batch aynı içerik ve aynı anahtarla yeniden denenir; sunucu yanıtı yolda kaybolduysa
    // araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
    private var pinned: List<Queued>? = null
    private var userId: String? = null
    // Global özellikler (UTP §8.2): `fr_` ile başlamayan her olaya eklenir; olayın kendi özelliği aynı anahtarda kazanır.
    private val globals = LinkedHashMap<String, JsonElement>()
    private var closed = false
    private var dropped = 0L
    private var backoff: Duration = Duration.ZERO
    private var backoffUntil: TimeMark? = null

    // Aynı anda tek gönderici: sabit Idempotency-Key için.
    private val sendMutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var worker: Job? = null

    init {
        val key = config.projectKey.trim()
        if (key.startsWith("sk_")) {
            throw FeralinException.Configuration("gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin")
        }
        if (!key.startsWith("pk_") || key.length < 8) {
            throw FeralinException.Configuration("proje anahtarı pk_ ile başlamalı")
        }
        val root = config.collectUrl.trim().trimEnd('/')
        if (!isAbsoluteHttpUrl(root)) {
            throw FeralinException.Configuration("collectUrl http veya https şemalı mutlak adres olmalı")
        }
        if (config.timeoutMillis <= 0) throw FeralinException.Configuration("timeoutMillis pozitif olmalı")
        projectKey = key
        endpoint = "$root/v1/batch"

        if (config.flushIntervalMillis > 0) {
            val interval = config.flushIntervalMillis.milliseconds
            worker = scope.launch {
                while (isActive) {
                    // Aralık dolunca ya da kuyruk batch boyutuna ulaşınca uyanır.
                    withTimeoutOrNull(interval) { wake.receive() }
                    val waiting = lock.withLock { backoffUntil?.hasNotPassedNow() == true }
                    if (!waiting) runFlush(deadline = null)
                }
            }
        }
    }

    /** İzin durumunu günceller. `analytics` false ise bekleyen olaylar atılır ve yeni olay üretilmez. */
    fun setConsent(value: Consent) {
        lock.withLock {
            consent = value
            if (!value.analytics) {
                queue.clear()
                pinned = null
            }
        }
    }

    /** Sonraki olaylar için varsayılan `user_id`. null varsayılanı kaldırır. Yalnız uygulamanın opak kimliği verilir, e-posta verilmez. */
    fun identify(id: String?) {
        val value = validateIdentifier(id, "user_id")
        lock.withLock { userId = value }
    }

    /**
     * Olayı doğrular, UTP v1 biçimine çevirir ve kuyruğa ekler; ağ çağrısı yapmaz.
     * `analytics` izni yoksa olay üretilmez ve null döner. Doğrulama hatasında [FeralinException.InvalidEvent] fırlatır.
     */
    fun track(
        eventName: String,
        properties: Map<String, Any?>? = null,
        userId: String? = null,
        anonymousId: String? = null,
        sessionId: String? = null,
        occurredAtMillis: Long? = null,
        context: EventContext? = null,
    ): TrackedEvent? {
        val (isClosed, currentConsent, defaultUser) = lock.withLock { Triple(closed, consent, this.userId) }
        if (isClosed) throw FeralinException.ClientClosed()
        if (!currentConsent.analytics) return null

        validateEventName(eventName)
        val props = convertProperties(properties)
        if (!ProfileRules.isSystemEvent(eventName)) {
            val shared = lock.withLock { globals.toList() }
            for ((key, value) in shared) {
                if (props.size >= MAX_PROPERTIES) break
                if (key !in props) props[key] = value
            }
        }
        // fr_click yalnız açık reklam ölçümü izniyle gönderilir.
        if (!currentConsent.advertising) props.remove(ATTRIBUTION_CLICK_PROPERTY)
        val installCode = lock.withLock { pendingInstallCode.also { pendingInstallCode = null } }
        if (installCode != null) props[INSTALL_CODE_PROPERTY] = JsonPrimitive(installCode)
        val uid = validateIdentifier(userId, "user_id") ?: defaultUser
        val aid = validateIdentifier(anonymousId, "anonymous_id")
        val sid = validateIdentifier(sessionId, "session_id")

        val moment = now()
        val eventId = ulid.next(moment)
        val payload = buildJsonObject {
            put("event_id", eventId)
            put("event_name", eventName)
            put("occurred_at", formatTime(occurredAtMillis ?: moment))
            put("platform", platformName)
            put("schema_version", SCHEMA_VERSION)
            put(
                "sdk",
                buildJsonObject {
                    put("name", SDK_NAME)
                    put("version", SDK_VERSION)
                },
            )
            put("consent", currentConsent.toJson())
            aid?.let { put("anonymous_id", it) }
            uid?.let { put("user_id", it) }
            sid?.let { put("session_id", it) }
            if (props.isNotEmpty()) put("properties", JsonObject(props))
            context?.toJson()?.takeIf { it.isNotEmpty() }?.let { put("context", it) }
        }
        val raw = Json.encodeToString(JsonObject.serializer(), payload)

        // Serileştirme sürerken izin geri çekildiyse olay kuyruğa girmez (null).
        val full: Boolean? = lock.withLock {
            if (closed) throw FeralinException.ClientClosed()
            if (consent.analytics) {
                queue.add(Queued(eventId, raw))
                val over = queue.size - queueLimit
                if (over > 0) {
                    queue.subList(0, over).clear()
                    dropped += over
                }
                queue.size >= batchSize
            } else {
                if (installCode != null && pendingInstallCode == null) pendingInstallCode = installCode
                null
            }
        }
        if (full == null) return null
        if (full) wake.trySend(Unit)
        return TrackedEvent(eventId, payload)
    }

    /**
     * Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve temizlenmiş özellikler. Grup kimliği 1-128
     * karakter olmalı, `@` ve kontrol karakteri içermemelidir; uymazsa olay üretilmez ve null döner (fırlatmaz). Kişisel veriye benzeyen,
     * doğrulama alanı olan ve sözleşme dışı değerli özellik düşer. Toplayıcı yalnız projenin izin listesindeki özellikleri saklar.
     */
    fun group(
        groupId: String,
        traits: Map<String, Any?>? = null,
        userId: String? = null,
        anonymousId: String? = null,
        sessionId: String? = null,
    ): TrackedEvent? {
        if (!ProfileRules.isValidGroupId(groupId)) return null
        val props = LinkedHashMap<String, Any?>(ProfileRules.sanitize(traits).properties)
        props["group_id"] = groupId
        return track(GROUP_EVENT_NAME, props, userId, anonymousId, sessionId)
    }

    /**
     * Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad vb.),
     * doğrulama alanı ve sözleşme dışı değer düşer; geçerli özellik kalmazsa olay üretilmez ve null döner. Toplayıcı yalnız projenin
     * izin listesindeki anahtarları saklar (liste boşsa hiçbirini).
     */
    fun setUserProperties(
        properties: Map<String, Any?>,
        userId: String? = null,
        anonymousId: String? = null,
        sessionId: String? = null,
    ): TrackedEvent? {
        val clean = ProfileRules.sanitize(properties).properties
        if (clean.isEmpty()) return null
        return track(USER_PROPERTIES_EVENT_NAME, clean, userId, anonymousId, sessionId)
    }

    /**
     * Satın alma ya da abonelik beyanını `feralin_purchase` olayı olarak kuyruğa ekler. İstemci beyanıdır: sunucu satırı yalnız makbuz
     * doğrulayıcısı onaylarsa REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` ve türevleri çağıranın özelliklerinden düşer.
     * Sözleşme dışı girdide ([revenueProperties]) olay üretilmez ve null döner; izin ve kuyruk kuralları [track] ile aynıdır.
     */
    fun trackRevenue(
        revenue: Revenue,
        userId: String? = null,
        anonymousId: String? = null,
        sessionId: String? = null,
        occurredAtMillis: Long? = null,
        context: EventContext? = null,
    ): TrackedEvent? {
        val props = revenueProperties(revenue) ?: return null
        return track(REVENUE_EVENT_NAME, props, userId, anonymousId, sessionId, occurredAtMillis, context)
    }

    /**
     * Yakalanan (try/catch) bir hatayı `fr_error` olarak bildirir. Ham yığın izi gitmez: hata sınıfı adı, temizlenmiş mesaj (e-posta, URL,
     * UUID, belirteç ve uzun sayı etiketlenir, en çok 200 karakter), çerçeve özeti olan parmak izi ve en üst çerçeve gider. [uncaught] true
     * ise `origin: uncaught_exception`, `fatal: true` yazılır (uygulamanın kendi yakalanmamış hata işleyicisinden çağırmak için).
     * İstemci başına en çok 20 olay, aynı parmak izi için en çok 3; izin yoksa, sınır dolduysa ya da istemci kapandıysa null döner ve
     * hiçbir durumda fırlatmaz.
     */
    fun captureError(
        error: Throwable,
        uncaught: Boolean = false,
        userId: String? = null,
        anonymousId: String? = null,
        sessionId: String? = null,
    ): TrackedEvent? {
        if (!lock.withLock { !closed && consent.analytics }) return null
        return try {
            val origin = if (uncaught) ErrorEvents.ORIGIN_UNCAUGHT else ErrorEvents.ORIGIN_HANDLED
            val props = ErrorEvents.properties(error, origin, fatal = uncaught, appVersion = appVersion)
            if (!errorLimiter.allow(props["fingerprint"] as String)) return null
            track(ERROR_EVENT_NAME, props, userId, anonymousId, sessionId)
        } catch (_: FeralinException) {
            // Hata bildirimi uygulamayı ikinci kez düşürmez (geçersiz kimlik, eşzamanlı kapanış).
            null
        }
    }

    /**
     * Global özellikleri birleştirir: `fr_` ile başlamayan her olaya eklenir, olayın kendi özelliği aynı anahtarda kazanır. Değer null
     * anahtarı siler. Kurallar [setUserProperties] ile aynıdır; toplam en çok 50 anahtar tutulur, fazlası düşer. Düşen anahtar sayısını döner.
     */
    fun setGlobalProperties(properties: Map<String, Any?>): Int {
        val result = ProfileRules.sanitize(properties, allowNull = true)
        var dropped = result.dropped
        lock.withLock {
            for ((key, value) in result.properties) {
                when {
                    value == null -> globals.remove(key)
                    key in globals || globals.size < MAX_PROFILE_PROPERTIES -> globals[key] = value
                    else -> dropped++
                }
            }
        }
        return dropped
    }

    /** Bütün global özellikleri siler. */
    fun clearGlobalProperties() {
        lock.withLock { globals.clear() }
    }

    /**
     * Kuyruktaki tüm olayları batch'ler hâlinde gönderir; geri çekilme beklemez, çünkü açık çağrı niyet sayılır.
     * Teslim hatası fırlatmaz, sonuç [FlushResult.error] içinde döner.
     */
    suspend fun flush(): FlushResult {
        if (lock.withLock { closed }) throw FeralinException.ClientClosed()
        return runFlush(deadline = null)
    }

    /** Arka plan göndericiyi durdurur ve kalan olayları en fazla [timeoutMillis] içinde göndermeyi dener. Birden çok çağrı güvenlidir. */
    suspend fun close(timeoutMillis: Long = 5_000): FlushResult {
        val first = lock.withLock {
            if (closed) {
                false
            } else {
                closed = true
                true
            }
        }
        if (!first) return FlushResult()
        worker?.cancel()
        scope.cancel()
        wake.close()
        return runFlush(deadline = TimeSource.Monotonic.markNow() + timeoutMillis.coerceAtLeast(0).milliseconds)
    }

    val queued: Int get() = lock.withLock { queue.size }

    fun status(): ClientStatus = lock.withLock {
        ClientStatus(
            sdk = SDK_NAME,
            version = SDK_VERSION,
            queued = queue.size,
            dropped = dropped,
            consent = consent,
            userId = userId,
            closed = closed,
            backoffSeconds = backoff.inWholeSeconds,
            endpoint = endpoint,
        )
    }

    private suspend fun runFlush(deadline: TimeMark?): FlushResult = sendMutex.withLock {
        var sent = 0
        var accepted = 0
        var rejected = 0
        var batchId: String? = null
        var status = 0
        var error: DeliveryError? = null
        // Üretici sürekli ekliyorsa döngü sonsuz olmasın: kuyruk sınırı kadar olay + bir tur.
        val maxRounds = queueLimit / batchSize + 2
        for (ignored in 0 until maxRounds) {
            val batch = lock.withLock { pinned ?: queue.take(batchSize) }
            if (batch.isEmpty()) break
            var requestTimeout = timeoutMillis
            if (deadline != null) {
                val remaining = (-deadline.elapsedNow()).inWholeMilliseconds
                if (remaining <= 0) {
                    error = DeliveryError.Temporary(0, "kapanış zaman aşımı; olaylar gönderilemedi")
                    break
                }
                requestTimeout = minOf(requestTimeout, remaining)
            }
            val result = send(batch, requestTimeout)
            sent += result.sent
            accepted += result.accepted
            rejected += result.rejected
            status = result.status
            batchId = result.batchId ?: batchId
            if (result.error != null) {
                error = result.error
                break
            }
        }
        FlushResult(sent, accepted, rejected, batchId, status, lock.withLock { queue.size }, error)
    }

    private suspend fun send(batch: List<Queued>, requestTimeout: Long): FlushResult {
        val count = batch.size
        val ids = batch.map { it.id }
        // Olaylar zaten serileştirilmiş; gövde metin birleştirme ile kurulur.
        val body = "{\"sent_at\":\"" + formatTime(now()) + "\",\"events\":[" + batch.joinToString(",") { it.raw } + "]}"
        val headers = linkedMapOf(
            "Content-Type" to "application/json",
            "Accept" to "application/json, application/problem+json",
            "X-Feralin-Project-Key" to projectKey,
            "Idempotency-Key" to idempotencyKeyFor(ids),
            "User-Agent" to "$SDK_NAME/$SDK_VERSION",
        )

        val response = try {
            transport.post(endpoint, body, headers, requestTimeout)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            pin(batch)
            noteFailure(null)
            return FlushResult(sent = count, retained = count, error = DeliveryError.Temporary(0, error.message ?: "ağ hatası"))
        }

        if (response.status == 202) {
            val ack = parseObject(response.body)
            acknowledge(ids)
            noteSuccess()
            return FlushResult(
                sent = count,
                accepted = (ack?.get("accepted") as? JsonPrimitive)?.intOrNull ?: count,
                rejected = (ack?.get("rejected") as? JsonPrimitive)?.intOrNull ?: 0,
                batchId = (ack?.get("batch_id") as? JsonPrimitive)?.contentOrNull,
                status = 202,
            )
        }
        if (response.status in 400..499 && response.status != 429) {
            acknowledge(ids)
            return FlushResult(
                sent = count,
                rejected = count,
                status = response.status,
                error = DeliveryError.Rejected(response.status, problemSummary(response.body)),
            )
        }
        pin(batch)
        noteFailure(response.retryAfter)
        return FlushResult(
            sent = count,
            retained = count,
            status = response.status,
            error = DeliveryError.Temporary(response.status, "olaylar kuyrukta tutuldu"),
        )
    }

    private fun acknowledge(ids: List<String>) {
        val sent = ids.toSet()
        lock.withLock {
            pinned = null
            queue.removeAll { it.id in sent }
        }
    }

    /** İstek sürerken izin geri çekildiyse olaylar çoktan silinmiştir, sabitlenmez. */
    private fun pin(batch: List<Queued>) {
        lock.withLock {
            if (consent.analytics) pinned = batch
        }
    }

    /** Üstel geri çekilme 1 sn → 30 sn; `Retry-After` verilmişse en az o kadar beklenir. Yarım jitter süreçleri ayrıştırır. */
    private fun noteFailure(retryAfter: String?) {
        lock.withLock {
            var next = maxOf(backoff * 2, MIN_BACKOFF)
            val seconds = retryAfter?.trim()?.toLongOrNull()
            var floor = Duration.ZERO
            if (seconds != null && seconds > 0) {
                floor = minOf(seconds.seconds, MAX_BACKOFF)
                next = maxOf(next, seconds.seconds)
            }
            next = minOf(next, MAX_BACKOFF)
            backoff = next
            backoffUntil = TimeSource.Monotonic.markNow() + maxOf(floor, next * (0.5 + Random.nextDouble() * 0.5))
        }
    }

    private fun noteSuccess() {
        lock.withLock {
            backoff = Duration.ZERO
            backoffUntil = null
        }
    }

    private companion object {
        val MIN_BACKOFF = 1.seconds
        val MAX_BACKOFF = 30.seconds
    }
}

private fun isAbsoluteHttpUrl(value: String): Boolean {
    val rest = when {
        value.startsWith("https://") -> value.removePrefix("https://")
        value.startsWith("http://") -> value.removePrefix("http://")
        else -> return false
    }
    val host = rest.substringBefore('/').substringBefore('?').substringBefore('#')
    return host.isNotEmpty() && host.none { it.isWhitespace() }
}

private fun parseObject(raw: String): JsonObject? = try {
    Json.parseToJsonElement(raw) as? JsonObject
} catch (_: SerializationException) {
    null
}

/** RFC 7807 gövdesinden kısa, loglanabilir özet; ham gövde sızdırılmaz. */
private fun problemSummary(raw: String): String {
    val problem = parseObject(raw) ?: return "problem+json yok"
    val text = listOf("title", "detail")
        .mapNotNull { (problem[it] as? JsonPrimitive)?.contentOrNull?.trim() }
        .filter { it.isNotEmpty() }
        .joinToString(" ")
    return if (text.isEmpty()) "problem+json yok" else text.take(200)
}
