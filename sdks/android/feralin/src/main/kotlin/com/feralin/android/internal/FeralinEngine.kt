package com.feralin.android.internal

import com.feralin.android.Consent
import com.feralin.android.DeferredDeepLink
import com.feralin.android.DeferredDeepLinkStatus
import com.feralin.android.FeralinConfig
import com.feralin.android.FeralinStatus
import com.feralin.android.FlushResult
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.random.Random

/** Play Install Referrer okuma sonucu; ham dizgi taşınmaz, yalnız izin listesindeki değerler. */
internal fun interface InstallReferrerSource {
    /** [callback] bir kez çağrılır; referrer yoksa veya servis erişilemezse `null` ile. */
    fun read(callback: (AttributionParams?) -> Unit)
}

/**
 * SDK çekirdeği (Android API'si kullanmaz, saf JVM'de sınanır). Davranış Web SDK ile aynıdır:
 * izin yoksa olay üretilmez ve gönderilmez, izin reddedilince kuyruk silinir, izin bekleniyorsa kuyruk bekletilir.
 * Durum yalnız [state] iş parçacığında değişir; HTTP [net] üzerindedir, böylece izin reddi süren bir isteği beklemez.
 */
internal class FeralinEngine(
    private val config: FeralinConfig,
    private val storeProvider: () -> EventStore,
    private val transport: Transport,
    private val referrer: InstallReferrerSource,
    private val appContext: () -> AppContext,
    private val state: Worker,
    private val net: Worker,
    private val clock: () -> Long = System::currentTimeMillis,
    private val random: Random = Random.Default,
    private val log: (String) -> Unit = {},
    private val sdkVersion: String = SDK_VERSION_FALLBACK,
    /** Meta Install Referrer zarfı (Facebook/Instagram uygulaması); yalnız reklam ölçümü izniyle, ilk açılışta bir kez okunur. */
    private val metaReferrer: () -> String? = { null },
    /** Kurulum mağazası (Play, Galaxy Store, AppGallery, Amazon…); ilk açılışta bir kez okunur, kişisel veri değildir. */
    private val installStore: () -> String? = { null },
    /** Emülatör bildirimi; yalnız `true` ise ilk açılışa eklenir (evet/hayır, cihaz kimliği değildir). */
    private val emulator: () -> Boolean = { false },
    /** Root bildirimi; yalnız `true` ise ilk açılışa eklenir (evet/hayır, cihaz kimliği değildir). */
    private val rooted: () -> Boolean = { false },
    /** İşletim sistemi sürümü (ör. `14`); ilk açılışa eklenir. Reklam ağına uygulama olayı gönderiminde gerekir; cihaz kimliği değildir. */
    private val osVersion: () -> String? = { null },
    /** Google reklam kimliği; yalnız `collectAdvertisingId` açıksa ve reklam izni verildiyse ilk açılışta bir kez okunur. */
    private val advertisingId: () -> String? = { null },
) {
    // Uygulamanın verdiği karar olduğu gibi saklanır; `consent` çocuk kipi ve izin süresi uygulanmış, kullanılan değerdir.
    @Volatile private var rawConsent: Consent? = config.consent
    @Volatile private var lastPushToken: String? = null
    @Volatile private var consent: Consent? = config.consent?.let(::childSafe)
    @Volatile private var adConsentExpired = false
    @Volatile private var queuedSnapshot = 0
    @Volatile private var anonymousId: String? = null
    @Volatile private var sessionId: String? = null
    @Volatile private var userId: String? = null
    // Kurulum kimliği (ADR-0007, şartname §31.2 yol 5-6): yalnız reklam ölçümü izniyle üretilir ve diske yazılır; durum iş parçacığında değişir.
    private var installId: String? = null
    // Her olaya eklenen uygulama özellikleri: yalnız bellekte, değişmez harita olarak değiştirilir; olayın kendi özelliği önce gelir.
    @Volatile private var globalProperties: Map<String, Any?> = emptyMap()
    // Önceki açılışın ANR/yerel çökme kayıtları: izin kararı gelene kadar bellekte bekler.
    private var pendingExits: List<Pair<Map<String, Any?>, Long>>? = null
    private var pendingExitMarker: Long? = null

    private lateinit var store: EventStore
    private val batchSize = config.batchSize.coerceIn(1, MAX_BATCH_EVENTS)
    private val endpoint = config.collectUrl.trimEnd('/') + "/v1/batch"
    private val reportedSdkName = config.wrapper?.name ?: SDK_NAME
    private val reportedSdkVersion = config.wrapper?.version ?: sdkVersion

    private var foreground = false
    private var lastBackgroundAt = 0L
    private var inflight = false
    private var failures = 0
    private var notBefore = 0L
    private var serverNotBefore = 0L
    private var pendingFlush: Cancellable? = null
    // Sonucu bilinmeyen batch aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda
    // kaybolduysa araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
    private var pinnedBatch: List<StoredEvent>? = null
    private var firstOpenStarted = false
    // Kurulum eşleştirme kodu süreç başına bir kez, kuyruğa giren ilk olayla gider; durum iş parçacığında değişir.
    private var pendingInstallCode: String? = config.installCode?.trim()?.takeIf { INSTALL_CODE_PATTERN.matches(it) }
    private var referrerFollowUpStarted = false
    private var pendingLink: Pair<DeepLink, Long>? = null
    private var linkEvidence: AttributionParams? = null

    // Reklam ölçümü izni henüz bildirilmemişken gelen bağlantının kanıtı; yalnız bellekte, süreç ömrüyle sınırlı.
    private var deferredLink: Pair<DeepLink, Long>? = null
    private val deferredDeepLinkWaiters = ArrayList<(DeferredDeepLink) -> Unit>()
    private var referrerReadInFlight = false

    // Çıkış süren okumadan önceki kurulumun yolunu geçersiz kılar: okuma bitince başka kullanıcıya teslim edilmesin.
    private var deferredDeepLinkEpoch = 0

    private val analyticsAllowed: Boolean get() = consent?.analytics == true

    /** Attribution kanıtı (fr_click, utm_*, referrer okuma) yalnız açık reklam ölçümü izniyle kullanılır. */
    private val advertisingAllowed: Boolean get() = consent?.let { it.analytics && it.advertising == true } == true

    /** Çocuklara yönelik uygulamada reklam ölçümü ve kişiselleştirme izni her zaman kapalıdır (COPPA). */
    private fun childSafe(value: Consent): Consent = if (config.childDirected) value.copy(advertising = false, personalization = false) else value

    /**
     * İzin süresi: reklam izninin verildiği an bir kez yazılır (uygulama her açılışta aynı izni yeniden verse de sıfırlanmaz). Süre dolmuşsa
     * izin "verilmemiş" (null) sayılır; `confirmAdvertisingConsent` zamanı yeniler. Durum iş parçacığında çağrılır.
     */
    private fun aged(value: Consent): Consent {
        if (!value.analytics || value.advertising != true) {
            if (value.advertising == false || !value.analytics) store.remove(KEY_AD_CONSENT_AT)
            adConsentExpired = false
            consent = value
            return value
        }
        val now = clock()
        val grantedAt = store.get(KEY_AD_CONSENT_AT)?.toLongOrNull() ?: now.also { store.put(KEY_AD_CONSENT_AT, it.toString()) }
        val maxDays = config.consentMaxAgeDays
        adConsentExpired = maxDays != null && now - grantedAt > maxDays * MS_PER_DAY
        val result = if (adConsentExpired) value.copy(advertising = null) else value
        consent = result
        return result
    }

    /** Kullanıcı reklam ölçümü iznini yeniden onayladı: izin zamanı yenilenir ve uygulamanın son kararı yeniden uygulanır. */
    fun confirmAdvertisingConsent() = state.execute {
        val value = rawConsent?.let(::childSafe) ?: return@execute
        if (value.analytics && value.advertising == true) store.put(KEY_AD_CONSENT_AT, clock().toString())
        applyConsent(aged(value))
    }

    fun start() = state.execute {
        store = storeProvider()
        anonymousId = store.get(KEY_ANONYMOUS_ID) ?: Ulid.next(clock())
        installId = store.get(KEY_INSTALL_ID)
        sessionId = Ulid.next(clock())
        queuedSnapshot = store.size()
        consent?.let { applyConsent(aged(it)) }
    }

    /** İzin kararı. Ret: kuyruk ve depodaki kimlik silinir. Onay: kimlik yazılır, bekleyen olaylar serbest kalır. */
    fun setConsent(value: Consent) {
        rawConsent = value
        val safe = childSafe(value)
        consent = safe
        // Silme durum sırasında yapılır; getStatus ret anından itibaren doğru görünür.
        if (!safe.analytics) queuedSnapshot = 0
        state.execute { applyConsent(aged(safe)) }
    }

    private fun applyConsent(value: Consent) {
        if (value.analytics) {
            anonymousId?.let { store.put(KEY_ANONYMOUS_ID, it) }
            if (value.advertising != true) {
                stripQueuedAttribution(value)
                linkEvidence = null
                store.remove(KEY_DEFERRED_DEEP_LINK)
            }
            if (value.advertising == false) deferredLink = null
            pendingLink?.let { (link, at) -> emitDeepLink(link, at) }
            pendingLink = null
            maybeFirstOpen()
            if (value.advertising == true) {
                emitDeferredLink()
                maybeReferrerFollowUp()
            }
            settleProcessExits()
            scheduleOrFlush()
            settleDeferredDeepLinks()
        } else {
            store.remove(KEY_DEFERRED_DEEP_LINK)
            installId = null
            store.remove(KEY_INSTALL_ID)
            settleProcessExits()
            settleDeferredDeepLinks()
            pendingLink = null
            linkEvidence = null
            deferredLink = null
            pinnedBatch = null
            cancelPending()
            store.clear()
            store.remove(KEY_ANONYMOUS_ID)
            queuedSnapshot = 0
            failures = 0
            notBefore = 0L
        }
    }

    /**
     * İzin geri çekildiyse veya hiç verilmediyse bekleyen olay kanıt taşımaz. İlk açılış işareti yazılmış olduğu için olay silinirse kurulum
     * bir daha sayılamazdı: olay kanıtsız kalır. Yalnız kanıt taşıyan follow-up atılır.
     */
    private fun stripQueuedAttribution(current: Consent) {
        var changed = false
        for (event in store.peek(config.queueLimit)) {
            val clean = EventJson.withoutAttribution(event.payload, current)
            when {
                clean == null -> {
                    store.ack(listOf(event.eventId))
                    changed = true
                }
                clean != event.payload -> {
                    store.replace(event.eventId, clean)
                    changed = true
                }
            }
        }
        if (changed) {
            pinnedBatch = null
            queuedSnapshot = store.size()
        }
    }

    fun identify(id: String) {
        if (id.isEmpty() || id.length > MAX_ID_LENGTH) return
        userId = id
    }

    /**
     * Çıkış: oturum, anonim kimlik ve kurulum kimliği yenilenir, global özellikler ve kuyruk silinir. İlk açılış işareti kuruluma aittir, korunur.
     */
    fun reset() {
        userId = null
        globalProperties = emptyMap()
        state.execute {
            installId = null
            store.remove(KEY_INSTALL_ID)
            sessionId = Ulid.next(clock())
            anonymousId = Ulid.next(clock())
            if (analyticsAllowed) anonymousId?.let { store.put(KEY_ANONYMOUS_ID, it) } else store.remove(KEY_ANONYMOUS_ID)
            pinnedBatch = null
            deferredLink = null
            linkEvidence = null
            deferredDeepLinkEpoch++
            store.remove(KEY_DEFERRED_DEEP_LINK)
            store.clear()
            queuedSnapshot = 0
        }
    }

    /** Referrer okuması sürüyorsa sonuç okuma bitince verilir; aksi halde hemen. Yol bir kez teslim edilir. */
    fun consumeDeferredDeepLink(callback: (DeferredDeepLink) -> Unit) = state.execute {
        if (deferredDeepLinkPending()) deferredDeepLinkWaiters.add(callback) else deliverDeferredDeepLink(callback)
    }

    private fun deferredDeepLinkPending(): Boolean =
        advertisingAllowed &&
            store.get(KEY_DEFERRED_DEEP_LINK) == null &&
            store.get(KEY_REFERRER_CHECKED) == null &&
            referrerReadInFlight

    private fun settleDeferredDeepLinks() {
        if (deferredDeepLinkWaiters.isEmpty() || deferredDeepLinkPending()) return
        val waiting = ArrayList(deferredDeepLinkWaiters)
        deferredDeepLinkWaiters.clear()
        waiting.forEach(::deliverDeferredDeepLink)
    }

    private fun deliverDeferredDeepLink(callback: (DeferredDeepLink) -> Unit) {
        val path = store.get(KEY_DEFERRED_DEEP_LINK)
        val result = when {
            !advertisingAllowed -> DeferredDeepLink(DeferredDeepLinkStatus.CONSENT_REQUIRED)
            path != null -> {
                store.remove(KEY_DEFERRED_DEEP_LINK)
                DeferredDeepLink(DeferredDeepLinkStatus.DELIVERED, path)
            }
            else -> DeferredDeepLink(DeferredDeepLinkStatus.NONE)
        }
        try {
            callback(result)
        } catch (t: Throwable) {
            // Uygulamanın geri çağrısı SDK iş parçacığını düşüremez.
            log("derin bağlantı geri çağrısı hata verdi: ${t.javaClass.simpleName}")
        }
    }

    /** Olay kimliği döner; izin yoksa veya ad geçersizse `null` ve olay üretilmez. */
    fun track(name: String, properties: Map<String, Any?>?): String? {
        if (!analyticsAllowed) {
            log("izin yok, olay üretilmedi: $name")
            return null
        }
        if (!EventJson.isValidEventName(name)) {
            log("geçersiz olay adı")
            return null
        }
        val at = clock()
        val id = Ulid.next(at)
        val own = EventJson.sanitize(properties)
        // Global özellikler `fr_` sistem olaylarına eklenmez (ortak kural, ProfileRules).
        val clean = if (ProfileRules.acceptsGlobalProperties(name)) withGlobals(own) else own
        state.execute { produce(id, name, at, clean, null) }
        return id
    }

    /** Olayın kendi özellikleri önce gelir; global özellik yalnız boş anahtara ve 100 özellik sınırı içinde eklenir. */
    private fun withGlobals(own: Map<String, Any?>): Map<String, Any?> {
        val globals = globalProperties
        if (globals.isEmpty()) return own
        val merged = LinkedHashMap(own)
        for ((key, value) in globals) {
            if (merged.size >= EventJson.MAX_PROPERTIES) break
            if (key !in merged) merged[key] = value
        }
        return merged
    }

    /**
     * Sonraki her olaya eklenecek özellikleri mevcut global haritaya birleştirir: değeri `null` olan anahtar silinir, `null` harita hepsini
     * temizler. Yalnız bellekte tutulur, [reset] ile silinir. Kurallar [ProfileRules] (anahtar, değer, kişisel veri, en çok 50 özellik);
     * Android ayrıca `fr_` önekli anahtarı global yapmaz (sistem alanlarıyla karışmasın). Kabul edilen (yazılan ya da silinen) anahtar sayısını döner.
     */
    fun setGlobalProperties(properties: Map<String, Any?>?): Int {
        if (properties == null) {
            clearGlobalProperties()
            return 0
        }
        val (clean, dropped) = ProfileRules.sanitize(properties.filterKeys { !it.startsWith("fr_") }, allowNull = true)
        if (dropped > 0) log("global özellik: $dropped anahtar sözleşmeye uymadığı için düştü")
        val next = LinkedHashMap(globalProperties)
        var accepted = 0
        for ((key, value) in clean) {
            if (value == null) {
                next.remove(key)
                accepted++
                continue
            }
            if (key !in next && next.size >= ProfileRules.MAX_PROPERTIES) {
                log("global özellik: en çok ${ProfileRules.MAX_PROPERTIES} anahtar, fazlası düştü")
                continue
            }
            next[key] = value
            accepted++
        }
        globalProperties = java.util.Collections.unmodifiableMap(next)
        return accepted
    }

    /** Bütün global özellikleri siler. */
    fun clearGlobalProperties() {
        globalProperties = emptyMap()
    }

    /**
     * Kullanıcıyı bir gruba bağlar: `fr_group` (`group_id` + isteğe bağlı özellikler). Grup kimliği 1-128 karakter, yalnız boşluk değil, `@` ve
     * kontrol karakteri içermez; aksi hâlde `null`. Özellikler [ProfileRules] ile süzülür.
     */
    fun group(groupId: String, traits: Map<String, Any?>?): String? {
        if (!ProfileRules.validGroupId(groupId)) {
            log("fr_group: geçersiz group_id, olay üretilmedi")
            return null
        }
        val (props, dropped) = ProfileRules.sanitize(traits)
        if (dropped > 0) log("fr_group: $dropped özellik sözleşmeye uymadığı için düştü")
        props[PROP_GROUP_ID] = groupId
        return track(EVENT_GROUP, props)
    }

    /**
     * Push belirteci (kaldırma ölçümü, saas-api 0180): `fr_push_token` olayı. Sunucu belirteci olay deposuna yazmaz; panelde kaldırma
     * ölçümü açıksa günde en çok bir kez içeriksiz bildirim gönderir. Aynı belirteç bu süreçte ikinci kez bildirilmez. Biçimi bozuk
     * belirteç olay üretmez (`null`).
     */
    fun setPushToken(token: String): String? {
        val value = token.trim()
        if (value.length !in 20..4096 || !PUSH_TOKEN_PATTERN.matches(value)) {
            log("fr_push_token: geçersiz belirteç, olay üretilmedi")
            return null
        }
        if (value == lastPushToken) return null
        val id = track(EVENT_PUSH_TOKEN, mapOf(PROP_PUSH_TOKEN to value))
        if (id != null) lastPushToken = value
        return id
    }

    /** Push bildirimi açılışı (madde 15): [PushOpen] alanlarıyla `fr_push_open`; kaldırma ölçümü bildirimi açılış sayılmaz (`null`). */
    fun trackPushOpen(data: Map<String, String>): String? {
        val props = PushOpen.properties(data) ?: return null
        return track(PushOpen.EVENT, props)
    }

    /** Kullanıcı özellikleri: `fr_user_properties`, [ProfileRules] ile süzülür. Geçerli özellik yoksa olay üretilmez (`null`). */
    fun setUserProperties(properties: Map<String, Any?>?): String? {
        val (clean, dropped) = ProfileRules.sanitize(properties)
        if (dropped > 0) log("fr_user_properties: $dropped özellik sözleşmeye uymadığı için düştü")
        if (clean.isEmpty()) {
            log("fr_user_properties: geçerli özellik yok, olay üretilmedi")
            return null
        }
        return track(EVENT_USER_PROPERTIES, clean)
    }

    /**
     * Kurulum kimliği (ADR-0007): hesap eşleştirme (`account-links`, `surface=app`, `subject_id`) ve devam kodu (`install_id`) aynı kimliği kullanır.
     * Yalnız reklam ölçümü izniyle (analitik + reklam) üretilir ve diske yazılır; aksi hâlde `null`. Analitik izni geri çekilince ve [reset] ile
     * silinir. Sonuç durum iş parçacığında [callback] ile verilir.
     */
    fun installIdentifier(callback: (String?) -> Unit) = state.execute {
        val id = if (advertisingAllowed) ensureInstallId() else null
        try {
            callback(id)
        } catch (t: Throwable) {
            log("kurulum kimliği geri çağrısı hata verdi: ${t.javaClass.simpleName}")
        }
    }

    private fun ensureInstallId(): String {
        installId?.let { return it }
        val created = store.get(KEY_INSTALL_ID) ?: Ulid.next(clock())
        installId = created
        store.put(KEY_INSTALL_ID, created)
        return created
    }

    /**
     * Önceki açılışın sistem kayıtlarından ANR ve yerel çökmeleri `fr_error` olarak üretir ([ProcessExits]). Okuma durum iş parçacığında yapılır;
     * işaret (son bakılan kayıt zamanı) yalnız izin kararından sonra yazılır, böylece izin beklenirken kayıt kaybolmaz ve ret sonrası eski kayıt
     * sonradan gönderilmez. Kayıttaki sürüm, bir önceki açılışın uygulama sürümüdür (eşleme dosyası o sürüme göre seçilir).
     */
    fun reportProcessExits(read: () -> List<ExitRecord>) = state.execute {
        val now = clock()
        val checked = store.get(KEY_EXIT_CHECKED_AT)?.toLongOrNull()
        val records = try {
            read()
        } catch (t: Throwable) {
            log("çıkış kayıtları okunamadı: ${t.javaClass.simpleName}")
            emptyList()
        }
        val current = appVersion()
        val previous = store.get(KEY_LAST_APP_VERSION) ?: current
        if (current != null && current.length <= 32) store.put(KEY_LAST_APP_VERSION, current)
        pendingExits = ProcessExits.select(records, checked, now).mapNotNull { record ->
            ProcessExits.properties(record, previous)?.let { it to record.timestampMs }
        }
        pendingExitMarker = maxOf(checked ?: now, records.maxOfOrNull { it.timestampMs } ?: Long.MIN_VALUE)
        settleProcessExits()
    }

    private fun settleProcessExits() {
        val marker = pendingExitMarker ?: return
        val current = consent ?: return
        val reports = pendingExits.orEmpty()
        pendingExits = null
        pendingExitMarker = null
        if (current.analytics) {
            for ((props, at) in reports) produce(Ulid.next(at), ErrorEvent.NAME, at, props, null)
        }
        store.put(KEY_EXIT_CHECKED_AT, marker.toString())
    }

    /**
     * [track] gibi olay üretir, ama olay kalıcı kuyruğa yazılana ya da [timeoutMs] dolana kadar bekler. Yalnız süreç ölmeden önce (yakalanmamış istisna
     * işleyicisi) çağrılır: kuyruk tek iş parçacıklı olduğundan, sonradan eklenen işaret görevi olaydan sonra çalışır.
     */
    fun trackAndWait(name: String, properties: Map<String, Any?>?, timeoutMs: Long): String? {
        val id = track(name, properties) ?: return null
        val done = java.util.concurrent.CountDownLatch(1)
        state.execute { done.countDown() }
        done.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        return id
    }

    /** Uygulama sürümü adı (hata olayında sürüm kırılımı için); okunamazsa `null`. */
    fun appVersion(): String? = try {
        appContext().appVersion
    } catch (_: Exception) {
        null
    }

    /** Derin bağlantı URL'ini işler. Ham URL saklanmaz; izin beklenirken temizlenmiş hali yalnız bellekte tutulur. */
    fun handleLink(url: String?) = handleLink(url, null)

    /** [onResult] durum iş parçacığında çağrılır: çözümlenen kısa link ya da (kısa link değilse, çözülemediyse, izin yoksa) `null`. */
    fun handleLink(url: String?, onResult: ((ResolvedShortLink?) -> Unit)?) = state.execute {
        val link = DeepLink.parse(url)
        if (link == null) {
            onResult?.invoke(null)
            return@execute
        }
        // Fera Fly kısa linki (App Link doğrudan açıldı, yönlendirici atlandı): önce yönlendiriciden çözümlenir. Adreste zaten tıklama kimliği
        // varsa (yönlendiriciden geçmiş) çözümleme gerekmez. Analitik izni yoksa istek de yapılmaz.
        if (consent?.analytics == true && link.params.frClick == null && ShortLinks.isShortLink(url, config.shortLinkHosts)) {
            resolveShortLink(url!!, link, onResult)
            return@execute
        }
        acceptLink(link)
        onResult?.invoke(null)
    }

    private fun acceptLink(link: DeepLink) {
        val at = clock()
        val current = consent
        when {
            current == null -> pendingLink = link to at
            current.analytics -> emitDeepLink(link, at)
        }
    }

    /** Kısa linki ağ iş parçacığında çözümler; sonuç (ya da hata hâlinde linkin kendisi) durum iş parçacığında olaylaştırılır. */
    private fun resolveShortLink(url: String, link: DeepLink, onResult: ((ResolvedShortLink?) -> Unit)?) {
        val headers = ShortLinks.headers(osVersion(), advertisingAllowed)
        net.execute {
            val resolved = try {
                transport.get(url, headers).takeIf { it.status == 200 }?.let { ShortLinks.parse(it.body) }
            } catch (_: IOException) {
                null
            } catch (_: RuntimeException) {
                null
            }
            state.execute {
                lastShortLink = resolved
                val effective = resolved?.let { ShortLinks.syntheticUrl(url, it) }?.let(DeepLink::parse) ?: link
                acceptLink(effective)
                onResult?.invoke(resolved)
            }
        }
    }

    /** Son çözümlenen kısa link (uygulama yönlendirmesi için `Feralin.lastShortLink`); bellekte tutulur, diske yazılmaz. */
    @Volatile var lastShortLink: ResolvedShortLink? = null
        private set

    private fun emitDeepLink(link: DeepLink, at: Long) {
        val props = LinkedHashMap<String, Any?>()
        if (advertisingAllowed) {
            if (!link.params.isEmpty) linkEvidence = link.params
            props[PROP_SOURCE] = AttributionSource.APP_LINK
            link.params.writeTo(props)
        } else {
            // İzin yoksa attribution yok: açılış sayılır, kanıt gönderilmez. İzin henüz sorulmadıysa bellekte beklenir.
            props[PROP_SOURCE] = AttributionSource.NONE
            if (consent?.advertising == null && !link.params.isEmpty) deferredLink = link to at
        }
        produce(Ulid.next(at), EVENT_DEEP_LINK, at, props, link.cleanUrl)
        flushIfForeground()
    }

    /** Reklam ölçümü izni sonradan geldi: açılış zaten sayıldığı için kanıt işaretli ayrı olayla taşınır. */
    private fun emitDeferredLink() {
        val (link, at) = deferredLink ?: return
        deferredLink = null
        val props = LinkedHashMap<String, Any?>()
        props[PROP_SOURCE] = AttributionSource.APP_LINK
        props[PROP_FOLLOW_UP] = true
        link.params.writeTo(props)
        linkEvidence = link.params
        produce(Ulid.next(at), EVENT_DEEP_LINK, at, props, link.cleanUrl)
        flushIfForeground()
    }

    private fun maybeFirstOpen() {
        if (firstOpenStarted || !analyticsAllowed) return
        firstOpenStarted = true
        if (store.get(KEY_FIRST_OPEN) != null) return
        val at = clock()
        // Referrer yalnız reklam ölçümü izniyle okunur; izin yoksa ilk açılış kanıtsız üretilir.
        if (advertisingAllowed) readReferrer { params -> completeFirstOpen(at, params) } else completeFirstOpen(at, null)
    }

    private fun readReferrer(onResult: (AttributionParams?) -> Unit) {
        val completed = AtomicBoolean(false)
        referrerReadInFlight = true
        val epoch = deferredDeepLinkEpoch
        val finish: (AttributionParams?) -> Unit = { params ->
            if (completed.compareAndSet(false, true)) {
                state.execute {
                    referrerReadInFlight = false
                    onResult(if (epoch == deferredDeepLinkEpoch) params else params?.copy(deepLinkPath = null))
                }
            }
        }
        try {
            referrer.read(finish)
        } catch (t: Throwable) {
            // Referrer kütüphanesi uygulamadan çıkarılmışsa (NoClassDefFoundError) kanıt yoktur.
            log("referrer okunamadı: ${t.javaClass.simpleName}")
            finish(null)
        }
    }

    private fun completeFirstOpen(at: Long, params: AttributionParams?) {
        if (!analyticsAllowed) {
            // İzin okuma sırasında geri çekildi: işaret yazılmadı, sonraki onayda yeniden denenir.
            firstOpenStarted = false
            settleDeferredDeepLinks()
            return
        }
        val props = LinkedHashMap<String, Any?>()
        val link = linkEvidence
        val allowed = advertisingAllowed
        when {
            allowed && params != null && !params.isEmpty && !params.isPlayOrganicDefault -> {
                props[PROP_SOURCE] = params.source
                params.writeTo(props)
            }
            allowed && link != null -> {
                props[PROP_SOURCE] = AttributionSource.APP_LINK
                link.writeTo(props)
            }
            else -> props[PROP_SOURCE] = AttributionSource.NONE
        }
        // Kurulum mağazası izinden bağımsızdır: cihaz ya da kişi kimliği değil, uygulamanın hangi mağazadan kurulduğudur.
        val store = try {
            installStore()
        } catch (t: Throwable) {
            log("kurulum mağazası okunamadı: ${t.javaClass.simpleName}")
            null
        }
        store?.let { props[PROP_INSTALL_STORE] = it }
        val emulated = try {
            emulator()
        } catch (t: Throwable) {
            log("emülatör denetimi yapılamadı: ${t.javaClass.simpleName}")
            false
        }
        if (emulated) props[EmulatorCheck.PROPERTY] = true
        val isRooted = try {
            rooted()
        } catch (t: Throwable) {
            log("root denetimi yapılamadı: ${t.javaClass.simpleName}")
            false
        }
        if (isRooted) props[RootCheck.PROPERTY] = true
        val os = try {
            osVersion()
        } catch (t: Throwable) {
            null
        }
        if (os != null && OS_VERSION_PATTERN.matches(os)) props[PROP_OS_VERSION] = os
        if (allowed) {
            // Meta reklamından gelen kurulumun şifreli kampanya verisi; sunucu projenin anahtarıyla çözer, burada açılmaz.
            val meta = try {
                metaReferrer()
            } catch (t: Throwable) {
                log("meta referrer okunamadı: ${t.javaClass.simpleName}")
                null
            }
            meta?.let { props[PROP_META_REFERRER] = it }
            // İsteğe bağlı reklam kimliği: varsayılan kapalı; çocuklara yönelik uygulamada hiçbir koşulda okunmaz.
            if (config.collectAdvertisingId && !config.childDirected) {
                val adId = try {
                    advertisingId()
                } catch (t: Throwable) {
                    log("reklam kimliği okunamadı: ${t.javaClass.simpleName}")
                    null
                }
                adId?.let { props[AdvertisingIdSource.PROPERTY] = it }
            }
        }
        val id = Ulid.next(at)
        val markers = LinkedHashMap<String, String>()
        markers[KEY_FIRST_OPEN] = id
        // Sonradan gelen izinde lookback gerçek ilk açılışa göre işlesin: izin anı kanıtın yaşını değiştirmemeli.
        markers[KEY_FIRST_OPEN_AT] = at.toString()
        if (allowed) {
            markers[KEY_REFERRER_CHECKED] = "1"
            params?.deepLinkPath?.let { markers[KEY_DEFERRED_DEEP_LINK] = it }
        }
        try {
            produce(id, EVENT_FIRST_OPEN, at, props, null, markers)
        } finally {
            // Depo hatası bekleyen geri çağrıyı asılı bırakmaz.
            settleDeferredDeepLinks()
        }
        flushIfForeground()
    }

    /**
     * İlk açılış izinsiz üretildiyse ve reklam ölçümü izni sonradan geldiyse referrer o zaman, kurulumda bir kez okunur.
     * Sunucu kurulum başına tek `app_first_open` kararı verdiği için kanıt işaretli `deep_link_opened` ile taşınır.
     */
    private fun maybeReferrerFollowUp() {
        if (referrerFollowUpStarted || !advertisingAllowed) return
        if (store.get(KEY_FIRST_OPEN) == null || store.get(KEY_REFERRER_CHECKED) != null) return
        referrerFollowUpStarted = true
        readReferrer(::completeReferrerFollowUp)
    }

    private fun completeReferrerFollowUp(params: AttributionParams?) {
        referrerFollowUpStarted = false
        if (!advertisingAllowed) {
            settleDeferredDeepLinks()
            return
        }
        if (params == null || params.isEmpty || params.isPlayOrganicDefault) {
            store.put(KEY_REFERRER_CHECKED, "1")
            settleDeferredDeepLinks()
            return
        }
        val at = clock()
        val props = LinkedHashMap<String, Any?>()
        props[PROP_SOURCE] = params.source
        props[PROP_FOLLOW_UP] = true
        store.get(KEY_FIRST_OPEN_AT)?.toLongOrNull()?.let { props[PROP_FIRST_OPEN_AT] = EventJson.formatTime(it) }
        params.writeTo(props)
        val markers = LinkedHashMap<String, String>()
        markers[KEY_REFERRER_CHECKED] = "1"
        params.deepLinkPath?.let { markers[KEY_DEFERRED_DEEP_LINK] = it }
        try {
            produce(Ulid.next(at), EVENT_DEEP_LINK, at, props, null, markers)
        } finally {
            settleDeferredDeepLinks()
        }
        flushIfForeground()
    }

    private fun produce(
        id: String,
        name: String,
        at: Long,
        properties: Map<String, Any?>,
        pageUrl: String?,
        markers: Map<String, String> = emptyMap(),
    ) {
        val current = consent
        if (current?.analytics != true) return
        // Son güvence: uygulamanın kendi verdiği özellik dahil, fr_click izinsiz hiçbir olaya girmez.
        val consented = if (current.advertising == true) properties else properties - PROP_FR_CLICK
        // Yapılandırmadaki kod ilk olaya eklenir. Sarmalayıcılar (React Native, Unity) kodu olay özelliği olarak da verebilir; o dokunulmadan geçer.
        val code = pendingInstallCode
        val withCode = if (code != null) consented + (PROP_INSTALL_CODE to code) else consented
        // Atıf olayı reklam izninin verildiği anı taşır: sunucu projenin izin süresi kuralını bu değerle uygular.
        val attributionEvent = name == EVENT_FIRST_OPEN || name == EVENT_DEEP_LINK
        val grantedAt = if (attributionEvent && current.advertising == true) store.get(KEY_AD_CONSENT_AT)?.toLongOrNull() else null
        val withConsentAt = if (grantedAt != null) withCode + (PROP_CONSENT_AT to EventJson.formatTime(grantedAt)) else withCode
        // Atıf olayları imzalanır (anahtar verildiyse): imza olayın kimliğine ve kurulum kimliğine bağlıdır.
        val key = config.signingKey
        val safeProperties = if (key != null && attributionEvent) {
            withConsentAt + (EventSigner.PROPERTY to EventSigner.sign(key.id, key.secret, at / 1000L, id, name, anonymousId.orEmpty()))
        } else {
            withConsentAt
        }
        val payload = EventJson.encode(
            EventFields(
                eventId = id,
                eventName = name,
                occurredAtMs = at,
                sdkName = reportedSdkName,
                sdkVersion = reportedSdkVersion,
                platform = config.wrapper?.platform ?: "android",
                anonymousId = anonymousId,
                sessionId = sessionId,
                userId = userId,
                consent = current,
                properties = safeProperties,
                pageUrl = pageUrl,
                app = appContext(),
            ),
        )
        if (payload.length > MAX_EVENT_CHARS) {
            log("olay boyut sınırını aşıyor, atıldı: $name")
            return
        }
        store.add(StoredEvent(id, payload), config.queueLimit, markers)
        // Kod yalnız kuyruğa gerçekten giren olayla tüketilir: boyut sınırına takılan olay kodu harcamaz.
        if (code != null) pendingInstallCode = null
        queuedSnapshot = store.size()
        scheduleOrFlush()
    }

    private fun scheduleOrFlush() {
        if (queuedSnapshot >= batchSize) {
            attemptFlush(null)
        } else if (foreground && queuedSnapshot > 0 && pendingFlush == null && !inflight) {
            scheduleAttempt(config.flushIntervalMs)
        }
    }

    private fun flushIfForeground() {
        if (foreground) attemptFlush(null)
    }

    private fun scheduleAttempt(delayMs: Long) {
        cancelPending()
        pendingFlush = state.schedule(delayMs.coerceAtLeast(0L)) {
            pendingFlush = null
            attemptFlush(null)
        }
    }

    private fun cancelPending() {
        pendingFlush?.cancel()
        pendingFlush = null
    }

    fun flush(callback: ((FlushResult) -> Unit)?) = state.execute {
        // Açık çağrı üstel bekleyişi atlar; sunucunun Retry-After süresine yine uyulur.
        notBefore = 0L
        attemptFlush(callback)
    }

    private fun attemptFlush(callback: ((FlushResult) -> Unit)?) {
        val current = consent
        if (current?.analytics != true) {
            if (current != null) {
                pinnedBatch = null
                store.clear()
                queuedSnapshot = 0
            }
            callback?.invoke(FlushResult.NONE)
            return
        }
        if (inflight || queuedSnapshot == 0) {
            callback?.invoke(FlushResult.NONE)
            return
        }
        val now = clock()
        val gate = maxOf(notBefore, serverNotBefore)
        if (now < gate) {
            if (foreground) scheduleAttempt(gate - now)
            callback?.invoke(FlushResult.NONE)
            return
        }
        cancelPending()
        val batch = pinnedBatch ?: takeBatch()
        val body = EventJson.batchBody(now, batch)
        val headers = mapOf(
            "Content-Type" to "application/json",
            "Accept" to "application/json, application/problem+json",
            "x-feralin-project-key" to config.projectKey,
            "Idempotency-Key" to Idempotency.keyFor(batch.map { it.eventId }),
            // HttpURLConnection'ın varsayılan User-Agent'ı cihaz modelini içerir; parmak izi kaynağı olmasın.
            "User-Agent" to "$reportedSdkName/$reportedSdkVersion",
        )
        inflight = true
        net.execute {
            val response = try {
                transport.post(endpoint, headers, body)
            } catch (_: IOException) {
                null
            } catch (_: RuntimeException) {
                null
            }
            state.execute {
                inflight = false
                handleResponse(batch, response, callback)
            }
        }
    }

    /** 1 MiB gövde sınırına takılmamak için olay sayısı ve karakter bütçesiyle batch keser. */
    private fun takeBatch(): List<StoredEvent> {
        val out = ArrayList<StoredEvent>()
        var chars = 0
        for (event in store.peek(batchSize)) {
            if (out.isNotEmpty() && chars + event.payload.length > MAX_BATCH_CHARS) break
            out.add(event)
            chars += event.payload.length
        }
        return out
    }

    private fun handleResponse(
        batch: List<StoredEvent>,
        response: TransportResponse?,
        callback: ((FlushResult) -> Unit)?,
    ) {
        val ids = batch.map { it.eventId }
        val result: FlushResult
        when {
            response == null -> {
                log("ağ hatası, kuyrukta tutuluyor")
                pinnedBatch = batch
                noteFailure(null)
                result = FlushResult(batch.size, 0, 0, 0)
            }
            response.status == 202 -> {
                pinnedBatch = null
                store.ack(ids)
                failures = 0
                notBefore = 0L
                serverNotBefore = 0L
                val json = try {
                    JSONObject(response.body)
                } catch (_: Exception) {
                    null
                }
                result = FlushResult(
                    sent = batch.size,
                    accepted = json?.optInt("accepted", batch.size) ?: batch.size,
                    rejected = json?.optInt("rejected", 0) ?: 0,
                    status = 202,
                    batchId = json?.optString("batch_id", "")?.takeIf { it.isNotEmpty() },
                )
                log("gönderildi: kabul=${result.accepted} ret=${result.rejected}")
            }
            response.status in 400..499 && response.status != 429 -> {
                pinnedBatch = null
                store.ack(ids)
                log("kalıcı ret: ${response.status}")
                result = FlushResult(batch.size, 0, batch.size, response.status)
            }
            else -> {
                log("geçici hata: ${response.status}")
                pinnedBatch = batch
                noteFailure(response.retryAfterSeconds)
                result = FlushResult(batch.size, 0, 0, response.status)
            }
        }
        queuedSnapshot = store.size()
        callback?.invoke(result)
        if (failures == 0 && queuedSnapshot > 0 && (foreground || queuedSnapshot >= batchSize)) attemptFlush(null)
    }

    /** Üstel geri çekilme + yarım jitter. Yalnız ön plandayken yeniden denenir; arka planda cihaz uyandırılmaz. */
    private fun noteFailure(retryAfterSeconds: Long?) {
        failures++
        val exponent = (failures - 1).coerceAtMost(MAX_BACKOFF_SHIFT)
        val ceiling = (BASE_BACKOFF_MS shl exponent).coerceAtMost(MAX_BACKOFF_MS)
        val delay = ceiling / 2 + random.nextLong(ceiling / 2 + 1)
        val now = clock()
        notBefore = now + delay
        if (retryAfterSeconds != null && retryAfterSeconds > 0) {
            serverNotBefore = now + retryAfterSeconds.coerceAtMost(MAX_RETRY_AFTER_SECONDS) * 1_000L
        }
        if (foreground) scheduleAttempt(maxOf(notBefore, serverNotBefore) - now)
    }

    fun onForeground() = state.execute {
        if (foreground) return@execute
        val now = clock()
        foreground = true
        if (lastBackgroundAt > 0L && now - lastBackgroundAt >= config.sessionTimeoutMs) {
            sessionId = Ulid.next(now)
        }
        if (queuedSnapshot > 0) attemptFlush(null)
    }

    fun onBackground() = state.execute {
        foreground = false
        lastBackgroundAt = clock()
        cancelPending()
        attemptFlush(null)
    }

    /** Ağ geri geldi: üstel bekleyiş sıfırlanır, sunucunun Retry-After süresi korunur. */
    fun onNetworkAvailable() = state.execute {
        if (!foreground || queuedSnapshot == 0) return@execute
        failures = 0
        notBefore = 0L
        attemptFlush(null)
    }

    fun status(): FeralinStatus = FeralinStatus(
        initialized = true,
        sdk = reportedSdkName,
        version = reportedSdkVersion,
        queued = queuedSnapshot,
        consent = consent,
        advertisingConsentExpired = adConsentExpired,
        anonymousId = anonymousId,
        sessionId = sessionId,
        userId = userId,
    )

    internal companion object {
        const val SDK_NAME = "feralin-android"
        const val SDK_VERSION_FALLBACK = "0.0.0-dev"
        const val EVENT_FIRST_OPEN = "app_first_open"
        const val EVENT_DEEP_LINK = "deep_link_opened"
        const val PROP_SOURCE = "attribution_source"
        const val PROP_META_REFERRER = "meta_install_referrer"
        const val PROP_INSTALL_STORE = "install_store"
        const val PROP_FR_CLICK = "fr_click"
        const val PROP_INSTALL_CODE = "fr_install_code"
        // Sunucudaki kanonik biçimle aynı alfabe (Crockford Base32, I/L/O/U yok); tire, boşluk ve alt çizgi ayraçtır.
        val INSTALL_CODE_PATTERN = Regex("^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$")
        const val PROP_FOLLOW_UP = "consent_followup"
        const val PROP_CONSENT_AT = "consent_at"
        const val PROP_OS_VERSION = "os_version"
        const val EVENT_PUSH_TOKEN = "fr_push_token"
        const val PROP_PUSH_TOKEN = "push_token"
        /** FCM kayıt belirteci biçimi (sunucu ve toplayıcıdaki denetimle aynı). */
        val PUSH_TOKEN_PATTERN = Regex("^[A-Za-z0-9:_\\-.=]+$")
        /** Sunucunun kaldırma ölçümü için gönderdiği içeriksiz bildirimin tek alanı. */
        const val UNINSTALL_CHECK_KEY = "fr_uninstall_check"
        val OS_VERSION_PATTERN = Regex("^[0-9][0-9A-Za-z._ -]{0,31}$")
        const val KEY_AD_CONSENT_AT = "ad_consent_at"
        const val MS_PER_DAY = 86_400_000L
        const val PROP_FIRST_OPEN_AT = "first_open_at"
        const val KEY_REFERRER_CHECKED = "referrer_checked"
        const val KEY_DEFERRED_DEEP_LINK = "deferred_deep_link"
        const val KEY_ANONYMOUS_ID = "anonymous_id"
        const val KEY_FIRST_OPEN = "first_open_event_id"
        const val KEY_FIRST_OPEN_AT = "first_open_at_ms"
        const val KEY_INSTALL_ID = "install_id"
        const val KEY_EXIT_CHECKED_AT = "exit_info_checked_at_ms"
        const val KEY_LAST_APP_VERSION = "last_app_version"
        const val EVENT_GROUP = "fr_group"
        const val EVENT_USER_PROPERTIES = "fr_user_properties"
        const val PROP_GROUP_ID = "group_id"
        const val MAX_BATCH_EVENTS = 500
        const val MAX_ID_LENGTH = 128
        const val MAX_EVENT_CHARS = 256 * 1024
        const val MAX_BATCH_CHARS = 900 * 1024
        const val BASE_BACKOFF_MS = 5_000L
        const val MAX_BACKOFF_MS = 15L * 60L * 1_000L
        const val MAX_BACKOFF_SHIFT = 10
        const val MAX_RETRY_AFTER_SECONDS = 3_600L
    }
}
