package com.feralin.android

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.TrafficStats
import android.os.Build
import android.util.Log
import com.feralin.android.internal.AppContext
import com.feralin.android.internal.AppExitReader
import com.feralin.android.internal.AppLifecycleTracker
import com.feralin.android.internal.AesGcmPayloadCipher
import com.feralin.android.internal.AdRevenueEvent
import com.feralin.android.internal.EncryptedEventStore
import com.feralin.android.internal.ErrorEvent
import com.feralin.android.internal.ErrorLimiter
import com.feralin.android.internal.EventStore
import com.feralin.android.internal.GameEvents
import com.feralin.android.internal.ExecutorWorker
import com.feralin.android.internal.FeralinEngine
import com.feralin.android.internal.HttpUrlTransport
import com.feralin.android.internal.InstallStore
import com.feralin.android.internal.IntentLinks
import com.feralin.android.internal.KeystoreKey
import com.feralin.android.internal.MemoryEventStore
import com.feralin.android.internal.MetaInstallReferrerSource
import com.feralin.android.internal.EmulatorCheck
import com.feralin.android.internal.HuaweiInstallReferrerSource
import com.feralin.android.internal.PlayInstallReferrerSource
import com.feralin.android.internal.RootCheck
import com.feralin.android.internal.SamsungInstallReferrerSource
import com.feralin.android.internal.StoreReferrerChain
import com.feralin.android.internal.RevenueEvent
import com.feralin.android.internal.SqliteEventStore
import java.util.Locale
import java.util.TimeZone

/**
 * Feralin Android SDK girişi. Hiçbir metot uygulamaya hata fırlatmaz; geçersiz yapılandırma Logcat'e yazılır ve
 * SDK kapalı kalır. Consent-first: izin verilene kadar olay üretilmez, gönderilmez ve anonim kimlik diske yazılmaz.
 */
public object Feralin {
    private const val TAG = "Feralin"
    private const val THREAD_STATS_TAG = 0xFE21

    @Volatile private var engine: FeralinEngine? = null
    @Volatile private var appContext: Context? = null
    private var networkMonitor: NetworkMonitor? = null

    /** `Application.onCreate` içinde çağrılması önerilir; ikinci çağrı yok sayılır. `true`: SDK etkin. */
    @JvmStatic
    @Synchronized
    public fun initialize(context: Context, config: FeralinConfig): Boolean = guarded(false) {
        if (engine != null) return@guarded true
        config.validationError()?.let {
            Log.e(TAG, "SDK kapalı: $it")
            return@guarded false
        }
        val app = context.applicationContext
        appContext = app
        val log: (String) -> Unit = { if (config.debug) Log.d(TAG, it) }
        val state = ExecutorWorker("feralin-state", log = log)
        val net = ExecutorWorker("feralin-net", { TrafficStats.setThreadStatsTag(THREAD_STATS_TAG) }, log)
        val created = FeralinEngine(
            config = config,
            storeProvider = { openStore(app, log) },
            transport = HttpUrlTransport(),
            referrer = StoreReferrerChain(PlayInstallReferrerSource(app, state, log), HuaweiInstallReferrerSource(app)::read, SamsungInstallReferrerSource(app, state, log)),
            appContext = { readAppContext(app) },
            state = state,
            net = net,
            log = log,
            sdkVersion = BuildConfig.FERALIN_VERSION,
            metaReferrer = MetaInstallReferrerSource(app, config.metaAppId)::read,
            installStore = { InstallStore.read(app) },
            emulator = EmulatorCheck::read,
            rooted = RootCheck::read,
            osVersion = { android.os.Build.VERSION.RELEASE },
            advertisingId = { com.feralin.android.internal.AdvertisingIdSource.read(app) },
        )
        engine = created
        created.start()
        val monitor = NetworkMonitor(app, created::onNetworkAvailable, log)
        networkMonitor = monitor
        (app as? Application)?.registerActivityLifecycleCallbacks(
            AppLifecycleTracker(
                onForeground = {
                    monitor.start()
                    created.onForeground()
                },
                onBackground = {
                    monitor.stop()
                    created.onBackground()
                },
                onIntent = { intent -> IntentLinks.consume(intent)?.let(created::handleLink) },
                captureLinks = config.autoCaptureDeepLinks,
            ),
        )
        if (isProcessForeground()) {
            monitor.start()
            created.onForeground()
        }
        true
    }

    private fun openStore(app: Context, log: (String) -> Unit): EventStore = try {
        // Gövdeler Android Keystore anahtarıyla şifrelenir; Keystore yoksa düz metne düşülmez, kuyruk bellekte kalır.
        EncryptedEventStore(SqliteEventStore(app), AesGcmPayloadCipher(KeystoreKey.getOrCreate())).also { it.size() }
    } catch (e: Exception) {
        // Disk ya da Keystore açılamazsa SDK yine çalışır; kuyruk süreç ömrüyle sınırlı kalır.
        log("kalıcı kuyruk açılamadı: ${e.javaClass.simpleName}")
        MemoryEventStore()
    }

    private fun readAppContext(app: Context): AppContext {
        var version: String? = null
        var build: String? = null
        try {
            val info = app.packageManager.getPackageInfo(app.packageName, 0)
            version = info.versionName
            build = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode.toString()
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toString()
            }
        } catch (_: PackageManager.NameNotFoundException) {
            // Kendi paketimiz için beklenmez; alan gönderilmez.
        }
        return AppContext(Locale.getDefault().toLanguageTag(), TimeZone.getDefault().id, version, build)
    }

    private fun isProcessForeground(): Boolean {
        val state = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(state)
        return state.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    /** İzin kararını bildirir. `analytics=false`: kuyruk ve depodaki anonim kimlik silinir. */
    @JvmStatic
    public fun setConsent(consent: Consent): Unit = guarded(Unit) { engine?.setConsent(consent) }

    /**
     * Kullanıcı reklam ölçümü iznini yeniden onayladı (izin süresi dolduktan sonra yeniden soruldu): izin zamanı yenilenir.
     * `consentMaxAgeDays` verilmemişse etkisizdir.
     */
    @JvmStatic
    public fun confirmAdvertisingConsent(): Unit = guarded(Unit) { engine?.confirmAdvertisingConsent() }

    /** `setConsent(Consent(analytics = false))` ile aynıdır. */
    @JvmStatic
    public fun optOut(): Unit = setConsent(Consent(analytics = false))

    /** Olay üretir ve kuyruğa alır. Olay kimliği döner; izin yoksa, ad geçersizse veya SDK kapalıysa `null`. */
    @JvmStatic
    @JvmOverloads
    public fun track(name: String, properties: Map<String, Any?>? = null): String? =
        guarded(null) { engine?.track(name, properties) }

    /** `screen_view` olayı üretir. */
    @JvmStatic
    @JvmOverloads
    public fun screen(name: String, properties: Map<String, Any?>? = null): String? =
        track("screen_view", (properties ?: emptyMap()) + ("screen_name" to name))

    /**
     * Satın alma ya da abonelik beyanı (`feralin_purchase`). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa
     * REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez. Sözleşme dışı girdide `null` döner.
     */
    @JvmStatic
    public fun trackRevenue(input: RevenueInput): String? = guarded(null) {
        val props = RevenueEvent.properties(input)
        if (props == null) {
            Log.w(TAG, "geçersiz gelir girdisi, olay üretilmedi")
            null
        } else {
            engine?.track(RevenueEvent.NAME, props)
        }
    }

    /**
     * Reklam gösterimi geliri (`fr_ad_revenue`, X4). Satın alma gelirinden ([trackRevenue]) ve reklam harcamasından ayrı bir gelir sınıfıdır; istemci
     * beyanıdır ve sunucuda ESTIMATED kalır, reklam ağı raporuyla mutabakat yoktur. Sözleşme dışı girdide `null` döner.
     */
    @JvmStatic
    public fun trackAdRevenue(input: AdRevenueInput): String? = guarded(null) {
        val props = AdRevenueEvent.properties(input)
        if (props == null) {
            Log.w(TAG, "geçersiz reklam geliri girdisi, olay üretilmedi")
            null
        } else {
            engine?.track(AdRevenueEvent.NAME, props)
        }
    }

    /** Bölüm başladı (`level_start`). `levelId` 1-64 karakter. Sözleşme dışı girdide `null`. */
    @JvmStatic
    @JvmOverloads
    public fun trackLevelStart(levelId: String, attempt: Long? = null): String? = gameEvent(GameEvents.LEVEL_START, GameEvents.levelStart(levelId, attempt))

    /** Bölüm tamamlandı (`level_complete`). Süre milisaniyedir (0-86 400 000). */
    @JvmStatic
    @JvmOverloads
    public fun trackLevelComplete(levelId: String, attempt: Long? = null, score: Long? = null, durationMs: Long? = null): String? =
        gameEvent(GameEvents.LEVEL_COMPLETE, GameEvents.levelComplete(levelId, attempt, score, durationMs))

    /** Bölüm başarısız (`level_fail`). */
    @JvmStatic
    @JvmOverloads
    public fun trackLevelFail(levelId: String, attempt: Long? = null, score: Long? = null, durationMs: Long? = null, failReason: String? = null): String? =
        gameEvent(GameEvents.LEVEL_FAIL, GameEvents.levelFail(levelId, attempt, score, durationMs, failReason))

    /** Oyun içi para birimi kazanıldı (`economy_source`). Sanal para birimidir; gerçek gelir değildir. Miktar 1..10^12. */
    @JvmStatic
    @JvmOverloads
    public fun trackEconomySource(currencyName: String, amount: Long, reason: String? = null, itemId: String? = null): String? =
        gameEvent(GameEvents.ECONOMY_SOURCE, GameEvents.economy(currencyName, amount, reason, itemId))

    /** Oyun içi para birimi harcandı (`economy_sink`). */
    @JvmStatic
    @JvmOverloads
    public fun trackEconomySink(currencyName: String, amount: Long, reason: String? = null, itemId: String? = null): String? =
        gameEvent(GameEvents.ECONOMY_SINK, GameEvents.economy(currencyName, amount, reason, itemId))

    /** Ödüllü reklam gösterildi (`rewarded_ad_shown`). Gelir taşımaz; reklam geliri [trackAdRevenue] ile bildirilir. */
    @JvmStatic
    @JvmOverloads
    public fun trackRewardedAdShown(placement: String, network: String? = null): String? =
        gameEvent(GameEvents.REWARDED_SHOWN, GameEvents.rewardedShown(placement, network))

    /** Ödüllü reklam tamamlandı (`rewarded_ad_complete`). */
    @JvmStatic
    @JvmOverloads
    public fun trackRewardedAdComplete(placement: String, network: String? = null, rewardAmount: Long? = null, rewardCurrency: String? = null): String? =
        gameEvent(GameEvents.REWARDED_COMPLETE, GameEvents.rewardedComplete(placement, network, rewardAmount, rewardCurrency))

    /** Uygulama içi satın alma teklifi gösterildi (`iap_offer_shown`). Gelir değildir; gelir [trackRevenue] ile bildirilir. */
    @JvmStatic
    @JvmOverloads
    public fun trackIapOfferShown(productId: String, placement: String? = null): String? =
        gameEvent(GameEvents.IAP_OFFER_SHOWN, GameEvents.iapOfferShown(productId, placement))

    /**
     * Satın alma başlatıldı (`iap_initiated`). `transactionId` sonradan [trackRevenue] ile bildirilen işlemle aynıysa panel satın almayı bu basamağa bağlar.
     */
    @JvmStatic
    @JvmOverloads
    public fun trackIapInitiated(productId: String, placement: String? = null, transactionId: String? = null): String? =
        gameEvent(GameEvents.IAP_INITIATED, GameEvents.iapInitiated(productId, placement, transactionId))

    private fun gameEvent(name: String, properties: Map<String, Any?>?): String? = guarded(null) {
        if (properties == null) {
            Log.w(TAG, "geçersiz oyun olayı girdisi, olay üretilmedi")
            null
        } else {
            engine?.track(name, properties)
        }
    }

    @Volatile private var errorLimiter = ErrorLimiter()
    private var uncaughtHandlerInstalled = false

    /**
     * Yakalanan (try/catch) bir hatayı `fr_error` olarak bildirir. Ham yığın izi gitmez: hata sınıfı adı, temizlenmiş mesaj, çerçeve özeti olan
     * parmak izi ve sembolleştirme için en çok 5 uygulama çerçevesinin konumu (sınıf, yöntem, satır) gider. Süreç başına en çok 20 olay, aynı parmak izi için en çok 3 olay. Sınır dolduysa ya da izin yoksa `null`.
     */
    @JvmStatic
    public fun captureError(error: Throwable): String? = guarded(null) {
        val current = engine ?: return@guarded null
        val props = ErrorEvent.properties(error, ErrorEvent.ORIGIN_HANDLED, fatal = false, appVersion = current.appVersion())
        if (!errorLimiter.allow(props["fingerprint"] as String)) null else current.track(ErrorEvent.NAME, props)
    }

    /**
     * Yakalanmamış istisnaları `fr_error` (`fatal: true`) olarak bildirir. Mevcut `UncaughtExceptionHandler` korunur ve çağrılmaya devam eder; çökme
     * davranışı değişmez. Süreç ölmeden önce olay kuyruğa yazılana kadar en çok 1 saniye beklenir; gönderim sonraki açılışta olur. İkinci çağrı yok sayılır.
     * R8/ProGuard ile karartılmış sınıf ve yöntem adları olduğu gibi gider; sürümün eşleme dosyası (`mapping.txt`) yüklendiyse panel çerçeveleri
     * okuma anında özgün ada çözer (`POST /v1/projects/{id}/android-mappings`).
     *
     * @param sampleRate 0..1 örnekleme oranı (varsayılan 1).
     */
    @JvmStatic
    @JvmOverloads
    @Synchronized
    public fun captureUncaughtExceptions(sampleRate: Double = 1.0): Unit = guarded(Unit) {
        if (uncaughtHandlerInstalled) return@guarded
        uncaughtHandlerInstalled = true
        errorLimiter = ErrorLimiter(sampleRate = sampleRate.coerceIn(0.0, 1.0))
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val current = engine
                if (current != null) {
                    val props = ErrorEvent.properties(throwable, ErrorEvent.ORIGIN_UNCAUGHT, fatal = true, appVersion = current.appVersion())
                    if (errorLimiter.allow(props["fingerprint"] as String)) current.trackAndWait(ErrorEvent.NAME, props, UNCAUGHT_WAIT_MS)
                }
            } catch (_: Throwable) {
                // Hata işleyicisi hata veremez: asıl çökme davranışı önceki işleyiciye bırakılır.
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    private const val UNCAUGHT_WAIT_MS = 1_000L

    @Volatile private var exitCaptureStarted = false

    /**
     * Önceki açılışta sistemin kaydettiği ANR'yi ve yerel (native) çökmeyi `fr_error` olarak bildirir (`origin`: `anr` / `native_crash`, `fatal: true`).
     * Android 11 (API 30) ve üstünde `ApplicationExitInfo` kayıtları okunur; daha eski sürümde bu bilgi sistemde yoktur, yöntem `false` döner ve
     * hiçbir şey yapmaz. ANR'de yalnız ana iş parçacığının çerçeveleri ve sabit bir özet gider (sistem açıklaması ve ham iz gitmez); yerel çökmede
     * yalnız sinyal adı gider, çerçeve gönderilmez (NDK sembolleştirme yok). Özellik ilk açıldığında önceki geçmiş raporlanmaz; kayıt izin kararından
     * sonra gönderilir. [initialize] sonrasında, `Application.onCreate` içinde bir kez çağrılır; ikinci çağrı yok sayılır.
     */
    @JvmStatic
    public fun captureAnrAndNativeCrashes(): Boolean = guarded(false) {
        val current = engine ?: return@guarded false
        if (!AppExitReader.isSupported()) return@guarded false
        synchronized(this) {
            if (exitCaptureStarted) return@guarded true
            exitCaptureStarted = true
        }
        val app = appContext ?: return@guarded false
        current.reportProcessExits { AppExitReader.read(app) }
        true
    }

    /**
     * Kurulum kimliği (ADR-0007, şartname §31.2 yol 5-6): hesap eşleştirme ve devam kodu bu kimlikle yapılır. Uygulama değeri kendi sunucusuna iletir;
     * sunucu gizli anahtarla `POST /v1/projects/{id}/attribution/account-links` (`surface=app`, `subject_id`) çağırır. Yalnız reklam ölçümü izniyle
     * üretilir; izin yoksa ya da SDK kapalıysa `null`. [callback] SDK iş parçacığında çağrılır. Swift, Flutter ve React Native ile aynı sözleşme.
     */
    @JvmStatic
    public fun installIdentifier(callback: (String?) -> Unit): Unit = guarded(Unit) {
        val current = engine
        if (current == null) callback(null) else current.installIdentifier(callback)
    }

    /**
     * Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı (`group_id` ve isteğe bağlı özellikler). Grup kimliği 1-128 karakter,
     * kişisel veri olmamalıdır. Sunucuda ayrı grup profili yoktur; olay olarak saklanır. Olay kimliği ya da `null` döner.
     */
    @JvmStatic
    @JvmOverloads
    public fun group(groupId: String, traits: Map<String, Any?>? = null): String? = guarded(null) { engine?.group(groupId, traits) }

    /**
     * Firebase Cloud Messaging kayıt belirtecini bildirir (kaldırma ölçümü). `FirebaseMessagingService.onNewToken` içinden ve uygulama
     * açılışında `FirebaseMessaging.getInstance().token` sonucuyla çağrılır. Belirteç olay deposuna yazılmaz. Panelde kaldırma ölçümü açık
     * değilse sunucu belirteci saklamaz. Olay kimliği ya da `null` döner.
     */
    @JvmStatic
    public fun setPushToken(token: String): String? = guarded(null) { engine?.setPushToken(token) }

    /**
     * Gelen FCM iletisi Feralin'in kaldırma ölçümü bildirimi mi? `onMessageReceived` içinde `remoteMessage.data` ile çağrılır; `true`
     * ise uygulama iletiyi yok saymalıdır (kullanıcıya gösterilecek bir şey yoktur).
     */
    @JvmStatic
    public fun isUninstallCheck(data: Map<String, String>): Boolean = data[com.feralin.android.internal.FeralinEngine.UNINSTALL_CHECK_KEY] == "1"

    /**
     * Push bildirimine dokunarak açılışı bildirir (`fr_push_open`). Bildirim verisindeki `utm_*` ve `fr_push_id` alanları taşınır, öteki
     * veri gitmez; kampanya bilgisi yoksa `utm_medium=push` yazılır. Bildirimden gelen bir Feralin linki varsa ayrıca uygulama linki
     * akışıyla işlenmelidir. Olay kimliği ya da `null` döner.
     */
    @JvmStatic
    public fun trackPushOpen(data: Map<String, String>): String? = guarded(null) { engine?.trackPushOpen(data) }

    /**
     * E-posta servis sağlayıcısının tıklama izleme adresini (SendGrid, Iterable, Braze, Klaviyo…) Feralin kısa linkine çözer ve sonucu
     * ana iş parçacığında [callback] ile verir. Uygulama App Link ile ESP alanından açıldığında çağrılır; dönen adres olağan uygulama linki
     * akışına verilir. Yönlendirmeler izlenmeden en çok dört adım okunur; çözülemezse özgün adres döner. Ağ isteği arka planda yapılır.
     */
    @JvmStatic
    public fun resolveTrackedLink(url: String, callback: (String) -> Unit) {
        Thread {
            val resolved = try {
                com.feralin.android.internal.TrackedLinkResolver().resolve(url)
            } catch (t: Throwable) {
                url
            }
            android.os.Handler(android.os.Looper.getMainLooper()).post { callback(resolved) }
        }.apply { name = "feralin-link-resolver"; isDaemon = true }.start()
    }

    /** Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Geçerli özellik yoksa olay üretilmez. E-posta, telefon gibi PII verilmemelidir. */
    @JvmStatic
    public fun setUserProperties(properties: Map<String, Any?>): String? = guarded(null) { engine?.setUserProperties(properties) }

    /**
     * Sonraki her olaya eklenecek özellikleri birleştirir: değeri `null` olan anahtar silinir, `null` harita hepsini temizler. Olayın kendi
     * özelliği önceliklidir; `fr_` sistem olaylarına eklenmez. `fr_` önekli, gelir doğrulama ve kişisel veriye benzeyen (e-posta, telefon,
     * ad soyad vb.) anahtarlar, e-posta biçimli değerler kabul edilmez; en çok 50 anahtar. Yalnız bellekte tutulur, [reset] ile silinir.
     * Kabul edilen anahtar sayısını döner.
     */
    @JvmStatic
    public fun setGlobalProperties(properties: Map<String, Any?>?): Int = guarded(0) { engine?.setGlobalProperties(properties) ?: 0 }

    /** Bütün global özellikleri siler. */
    @JvmStatic
    public fun clearGlobalProperties(): Unit = guarded(Unit) { engine?.clearGlobalProperties() }

    /** Uygulamanın kendi kullanıcı kimliği (≤128 karakter). E-posta veya telefon gibi PII verilmemelidir. */
    @JvmStatic
    public fun identify(userId: String): Unit = guarded(Unit) { engine?.identify(userId) }

    /** Çıkışta çağrılır: oturum ve anonim kimlik yenilenir, kuyruk silinir. */
    @JvmStatic
    public fun reset(): Unit = guarded(Unit) { engine?.reset() }

    /** Kuyruğu göndermeyi dener; sonuç [callback] ile SDK iş parçacığında bildirilir. */
    @JvmStatic
    @JvmOverloads
    public fun flush(callback: ((FlushResult) -> Unit)? = null): Unit = guarded(Unit) {
        val current = engine
        if (current == null) callback?.invoke(FlushResult.NONE) else current.flush(callback)
    }

    /**
     * `onNewIntent` içinde `setIntent` çağırmayan etkinlikler için App Link niyetini elle iletir.
     * Otomatik yakalama kapalıysa `onCreate` niyeti de bununla verilir. Aynı niyet iki kez sayılmaz.
     */
    @JvmStatic
    public fun handleIntent(intent: Intent?): Unit = guarded(Unit) {
        val current = engine
        if (intent != null && current != null) IntentLinks.consume(intent)?.let(current::handleLink)
    }

    /**
     * Fera Fly kısa linkiyle (ör. `https://marka.fera.fly/kod`) açılışı işler ve uygulamanın açacağı yolu verir. App Link doğrudan açıldığında
     * yönlendirici atlandığı için SDK linki çözümler: derin yol, UTM ve (reklam izni varsa) tıklama kimliği `deep_link_opened` olayına eklenir.
     * Adres kısa link değilse, çözümlenemezse ya da analitik izni yoksa [callback] adresin kendi yolunu verir. Otomatik yakalama açıkken de
     * çözümleme yapılır; bu yöntem yalnız uygulamanın gideceği yolu öğrenmek içindir. [callback] SDK iş parçacığında çağrılır.
     */
    @JvmStatic
    public fun handleShortLink(url: String?, callback: (ShortLinkOpen) -> Unit): Unit = guarded(Unit) {
        val fallback = ShortLinkOpen(destination = pathOf(url), linkCode = null, hasClickId = false)
        val current = engine
        if (current == null || url == null) {
            callback(fallback)
            return@guarded
        }
        current.handleLink(url) { resolved ->
            callback(resolved?.let { ShortLinkOpen(it.deepLinkPath ?: "/", it.code, it.clickId != null) } ?: fallback)
        }
    }

    private fun pathOf(url: String?): String = try {
        java.net.URI(url ?: "").rawPath?.takeIf { it.isNotEmpty() } ?: "/"
    } catch (_: Exception) {
        "/"
    }

    /**
     * Kurulumdan sonra ertelenmiş derin bağlantıyı bir kez verir. Referrer okunuyorsa sonucu bekler; [callback] SDK iş parçacığında
     * çağrılır. Okuma reklam ölçümü iznine bağlıdır. Yol olay özelliğine yazılmaz ve sunucuya gönderilmez.
     */
    @JvmStatic
    public fun consumeDeferredDeepLink(callback: (DeferredDeepLink) -> Unit): Unit = guarded(Unit) {
        val current = engine
        if (current == null) callback(DeferredDeepLink(DeferredDeepLinkStatus.NOT_INITIALIZED)) else current.consumeDeferredDeepLink(callback)
    }

    /** Anlık durum; SDK başlatılmadıysa `initialized=false`. */
    @JvmStatic
    public fun getStatus(): FeralinStatus = guarded(notInitialized()) { engine?.status() ?: notInitialized() }

    private fun notInitialized() = FeralinStatus(
        initialized = false,
        sdk = FeralinEngine.SDK_NAME,
        version = BuildConfig.FERALIN_VERSION,
        queued = 0,
        consent = null,
        anonymousId = null,
        sessionId = null,
        userId = null,
    )

    private inline fun <T> guarded(fallback: T, block: () -> T): T = try {
        block()
    } catch (t: Throwable) {
        Log.w(TAG, "SDK hatası yutuldu: ${t.javaClass.simpleName}")
        fallback
    }

    /** Ön plandayken ağın geri geldiğini bildirir; arka planda kayıtlı kalmaz. */
    private class NetworkMonitor(
        context: Context,
        private val onAvailable: () -> Unit,
        private val log: (String) -> Unit,
    ) {
        private val manager = context.getSystemService(ConnectivityManager::class.java)
        private var callback: ConnectivityManager.NetworkCallback? = null

        @Synchronized
        fun start() {
            if (callback != null || manager == null) return
            val created = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = onAvailable()
            }
            try {
                manager.registerDefaultNetworkCallback(created)
                callback = created
            } catch (e: RuntimeException) {
                // İzin kaldırılmış veya kayıt sınırı dolmuşsa kuyruk ön plan geçişlerinde yine boşalır.
                log("ağ dinleyicisi açılamadı: ${e.javaClass.simpleName}")
            }
        }

        @Synchronized
        fun stop() {
            val current = callback ?: return
            callback = null
            try {
                manager?.unregisterNetworkCallback(current)
            } catch (e: RuntimeException) {
                log("ağ dinleyicisi kapatılamadı: ${e.javaClass.simpleName}")
            }
        }
    }
}
