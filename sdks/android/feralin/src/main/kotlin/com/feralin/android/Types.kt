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
) {
    /** Hata mesajı döner; geçerliyse `null`. Mesajda anahtar değeri bulunmaz. */
    internal fun validationError(): String? = when {
        projectKey.isBlank() -> "projectKey zorunlu"
        projectKey.startsWith("sk_") -> "gizli anahtar istemci uygulamasında kullanılamaz"
        !collectUrl.startsWith("https://") && !collectUrl.startsWith("http://") -> "collectUrl http(s) olmalı"
        wrapper != null && wrapper.validationError() != null -> wrapper.validationError()
        else -> null
    }
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
