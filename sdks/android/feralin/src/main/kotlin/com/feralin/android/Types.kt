package com.feralin.android

/** UTP v1 `consent` nesnesi. `analytics` zorunludur; diğerleri belirtilmediyse gönderilmez. */
public data class Consent(
    val analytics: Boolean,
    val advertising: Boolean? = null,
    val personalization: Boolean? = null,
    val sessionReplay: Boolean? = null,
)

/**
 * SDK yapılandırması.
 *
 * @property projectKey Public proje anahtarı (`pk_live_…`, `pk_test_…`); yalnız `x-feralin-project-key` başlığında taşınır.
 * @property collectUrl Collector kökü, ör. `https://collect.example.com`.
 * @property consent `null` izin bekleniyor demektir: olay üretilmez, depodaki kuyruk silinmez.
 * @property flushIntervalMs Ön plandayken ilk olaydan sonra gönderim gecikmesi; kuyruk boşken zamanlayıcı yoktur.
 * @property batchSize Tek istekteki en fazla olay (1…500).
 * @property queueLimit Kalıcı kuyruk üst sınırı; aşılınca en eski olay atılır.
 * @property sessionTimeoutMs Arka planda bu süre geçerse sonraki ön plana çıkışta yeni `session_id` üretilir.
 * @property autoCaptureDeepLinks Etkinlik niyetlerindeki App Link'ler otomatik işlensin mi.
 * @property debug `true` ise Logcat'e olay adı ve durum kodu yazılır; anahtar ve özellik değeri asla yazılmaz.
 * @property wrapper Yalnız resmî Feralin sarmalayıcıları içindir (React Native); uygulama kodunda verilmez.
 */
/**
 * Kısa link açılışının sonucu (Fera Fly). [destination] uygulamanın açacağı yoldur; [linkCode] çözümlenen kısa kod (çözülemediyse `null`);
 * [hasClickId] tıklama kimliğinin yönlendiriciden alındığını söyler (reklam izni yoksa olaya eklenmez).
 */
public data class ShortLinkOpen(val destination: String, val linkCode: String?, val hasClickId: Boolean)

public data class FeralinConfig(
    val projectKey: String,
    val collectUrl: String,
    val consent: Consent? = null,
    val flushIntervalMs: Long = 15_000L,
    val batchSize: Int = 50,
    val queueLimit: Int = 1_000,
    val sessionTimeoutMs: Long = 30L * 60L * 1_000L,
    val autoCaptureDeepLinks: Boolean = true,
    val debug: Boolean = false,
    val wrapper: SdkWrapper? = null,
    /**
     * Panelin "Kurulumu doğrula" ekranında üretilen tek kullanımlık eşleştirme kodu (ör. `ABCDE-FGHJK`). Verilirse süreçte üretilen
     * ilk olaya `fr_install_code` olarak eklenir; sunucu kodu olay verisinden söker ve bu kurulumu projeye bağlar. Kişisel veri
     * değildir, 30 dakika geçerlidir; doğrulamadan sonra yapılandırmadan kaldırılabilir. Biçimi bozuk kod yok sayılır.
     */
    val installCode: String? = null,
    /**
     * Facebook uygulama kimliği (Meta App ID). Verilirse SDK, Meta reklamından gelen kurulumun kampanya verisini Facebook/Instagram
     * uygulamasından okur (Meta Install Referrer; Facebook SDK gerekmez). Çözme anahtarı panelde projeye girilir, uygulamaya konmaz.
     */
    val metaAppId: String? = null,
    /**
     * SDK imza anahtarı (panel: Atıf > Dolandırıcılık kuralları). Verilirse ilk açılış ve link açılışı olayları bu anahtarla imzalanır;
     * sunucu imzasız ya da bozuk imzalı kurulumu projenin kuralına göre işaretler ya da reddeder. Anahtar uygulamaya gömülüdür:
     * sürüm başına ayrı anahtar üretip eskisini panelden iptal edebilirsiniz.
     */
    val signingKey: SigningKey? = null,
    /**
     * Çocuklara yönelik uygulama (COPPA ve benzeri kurallar). `true` ise reklam ölçümü ve kişiselleştirme izni uygulama ne verirse versin
     * kapalı sayılır: tıklama kimliği, mağaza yönlendiricileri, Meta yönlendiricisi ve pano okunmaz, olaylar reklam izni kapalı gider.
     * Panelde projenin "Çocuklara yönelik uygulama" ayarı ayrıca açılmalıdır: sunucu o ayarla eski SDK sürümlerinin olaylarını da korur.
     */
    val childDirected: Boolean = false,
    /**
     * Reklam ölçümü izninin geçerlilik süresi (gün). Verilirse izin bu süreden eskiyse yeniden sorulana kadar verilmemiş sayılır
     * (`getStatus().advertisingConsentExpired`); kullanıcı yeniden onaylayınca `Feralin.confirmAdvertisingConsent()` çağrılır.
     */
    val consentMaxAgeDays: Int? = null,
    /**
     * Google reklam kimliğini (GAID) topla. Varsayılan `false`: SDK kimliği hiç okumaz. `true` ise kimlik yalnız kullanıcı reklam
     * ölçümü iznini verdiyse, uygulama çocuklara yönelik değilse (`childDirected = false`) ve kullanıcı cihazda reklam
     * kişiselleştirmeyi kapatmadıysa ilk açılışta bir kez okunur. Uygulamanın `play-services-ads-identifier` kütüphanesini ve
     * `com.google.android.gms.permission.AD_ID` iznini kendisi eklemesi gerekir. Sunucu kimliği yalnız panelde projenin
     * "Reklam kimliği" ayarı da açıksa saklar ve yalnız reklam ağına dönüşüm iletiminde kullanır; Play Data Safety beyanınızı güncelleyin.
     */
    val collectAdvertisingId: Boolean = false,
    /**
     * Fera Fly kısa link hostları (varsayılan `fera.fly`; alt alanları da kapsar, ör. `marka.fera.fly`). Uygulama bu hostlardaki bir App
     * Link ile açılınca SDK linki yönlendiriciden çözümler: derin yol, UTM ve (reklam izni varsa) tıklama kimliği `deep_link_opened`
     * olayına eklenir. Markalı alanınızı ekleyebilirsiniz; boş liste çözümlemeyi kapatır.
     */
    val shortLinkHosts: List<String> = listOf("fera.fly"),
) {
    /** Hata mesajı döner; geçerliyse `null`. Mesajda anahtar değeri bulunmaz. */
    internal fun validationError(): String? = when {
        projectKey.isBlank() -> "projectKey zorunlu"
        projectKey.startsWith("sk_") -> "gizli anahtar istemci uygulamasında kullanılamaz"
        !collectUrl.startsWith("https://") && !collectUrl.startsWith("http://") -> "collectUrl http(s) olmalı"
        wrapper != null && wrapper.validationError() != null -> wrapper.validationError()
        metaAppId != null && !Regex("^[0-9]{5,20}$").matches(metaAppId) -> "metaAppId 5-20 rakam olmalı"
        signingKey != null && signingKey.validationError() != null -> signingKey.validationError()
        consentMaxAgeDays != null && consentMaxAgeDays !in 1..3650 -> "consentMaxAgeDays 1-3650 olmalı"
        else -> null
    }
}

/** SDK imza anahtarı: [id] panelde görünen kimlik (`sgn_…`), [secret] üretildiği anda bir kez gösterilen değer (`fsk_…`). */
public data class SigningKey(
    val id: String,
    val secret: String,
) {
    internal fun validationError(): String? = when {
        !Regex("^sgn_[a-z0-9]{12,40}$").matches(id) -> "signingKey.id biçimi geçersiz"
        secret.length < 16 || secret.length > 200 -> "signingKey.secret 16-200 karakter olmalı"
        else -> null
    }

    /** Anahtar değeri loglara ve hata dökümlerine düşmesin. */
    override fun toString(): String = "SigningKey(id=$id)"
}

/**
 * Bu çekirdeği kullanan resmî sarmalayıcı. Olayın `platform` ve `sdk` alanları buradan gelir; böylece React Native
 * olayı sunucuda `android` olarak sayılmaz.
 */
public data class SdkWrapper(
    val name: String,
    val version: String,
    val platform: String,
) {
    internal fun validationError(): String? = when {
        platform !in ALLOWED_PLATFORMS -> "sarmalayıcı platformu UTP v1 listesinde değil"
        name.isBlank() || name.length > 64 -> "sarmalayıcı adı 1-64 karakter olmalı"
        version.isBlank() || version.length > 32 -> "sarmalayıcı sürümü 1-32 karakter olmalı"
        else -> null
    }

    private companion object {
        val ALLOWED_PLATFORMS = setOf("react_native")
    }
}

/** Gönderim sonucu. `status` 0 ise istek yapılmadı veya ağ hatası oluştu. */
public data class FlushResult(
    val sent: Int,
    val accepted: Int,
    val rejected: Int,
    val status: Int,
    val batchId: String? = null,
) {
    internal companion object {
        val NONE: FlushResult = FlushResult(0, 0, 0, 0)
    }
}

/** Ertelenmiş derin bağlantı sonucu. */
public enum class DeferredDeepLinkStatus {
    /** Yol bu çağrıda teslim edildi; ikinci çağrı [NONE] döner. */
    DELIVERED,

    /** Kurulum referrer'ı okundu, teslim edilecek yol yok ya da daha önce teslim edildi. */
    NONE,

    /** Reklam ölçümü izni yok: referrer okunmaz. İzin gelince yeniden çağrılabilir. */
    CONSENT_REQUIRED,

    /** SDK başlatılmadı. */
    NOT_INITIALIZED,
}

/**
 * Kurulumdan sonra uygulamaya verilen uygulama içi yol. [path] dışarıdan gelen veridir: Play bağlantısını başkası da üretebilir.
 * Uygulama yolu kendi yönlendirme tablosuyla eşleştirmeli, doğrudan yetkili bir eylem çalıştırmamalıdır.
 */
public data class DeferredDeepLink(
    val status: DeferredDeepLinkStatus,
    val path: String? = null,
)

/** Uygulamanın kendi tanısı için anlık durum. */
public data class FeralinStatus(
    val initialized: Boolean,
    val sdk: String,
    val version: String,
    val queued: Int,
    val consent: Consent?,
    /** Reklam ölçümü izninin süresi doldu; uygulama kullanıcıya yeniden sormalı. */
    val advertisingConsentExpired: Boolean = false,
    val anonymousId: String?,
    val sessionId: String?,
    val userId: String?,
)

/** Satın alma türü (`purchase_type`). */
public enum class PurchaseType {
    PURCHASE,
    SUBSCRIPTION_START,
    SUBSCRIPTION_RENEW,
    SUBSCRIPTION_CANCEL,
}

/** İsteğe bağlı ham makbuz; toplayıcı yalnız sağlayıcı adını ve belirtecin SHA-256 özetini saklar. */
public data class Receipt(
    val provider: Provider,
    /** Makbuz ya da satın alma belirteci (en çok 8192 karakter). */
    val token: String,
) {
    public enum class Provider { APPLE, GOOGLE, STRIPE }
}

/**
 * `trackRevenue` girdisi (F5-E04-T01). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar,
 * aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez.
 */
public data class RevenueInput(
    /** Mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz; sunucu aynı işlemi ikinci kez saymaz. */
    val transactionId: String,
    /** Küçük birimde satır toplamı: 49,99 TL için 4999. Ondalık yoktur; `quantity` ile çarpılmaz. Abonelik iptalinde 0. */
    val amountMinor: Long,
    /** ISO 4217, üç büyük harf. */
    val currency: String,
    val productId: String? = null,
    val quantity: Int = 1,
    val purchaseType: PurchaseType = PurchaseType.PURCHASE,
    val receipt: Receipt? = null,
    /** Ek özellikler; `verified` ve türevleri düşürülür. */
    val properties: Map<String, Any?>? = null,
)
