// Herkese açık tipler. Saf Dart: Flutter içe aktarılmaz.

/// UTP v1 `consent` nesnesi. [analytics] zorunludur; diğerleri belirtilmediyse gönderilmez.
class Consent {
  const Consent({
    required this.analytics,
    this.advertising,
    this.personalization,
    this.sessionReplay,
  });

  final bool analytics;
  final bool? advertising;
  final bool? personalization;
  final bool? sessionReplay;

  /// UTP v1 alan adlarıyla JSON gösterimi.
  Map<String, Object> toJson() => {
    'analytics': analytics,
    'advertising': ?advertising,
    'personalization': ?personalization,
    'session_replay': ?sessionReplay,
  };
}

/// Attribution uçlarının adresi (ADR-0007). Proje anahtarı `Authorization: Bearer` ile taşınır; gizli API anahtarı kullanılmaz.
class AttributionConfig {
  const AttributionConfig({required this.apiUrl, required this.projectId});

  /// SaaS API kökü, ör. `https://api.example.com`.
  final String apiUrl;

  /// Proje kimliği (`/v1/projects/{id}/...`).
  final String projectId;
}

/// SDK yapılandırması.
class FeralinConfig {
  const FeralinConfig({
    required this.projectKey,
    required this.collectUrl,
    this.consent,
    this.flushInterval = const Duration(seconds: 15),
    this.batchSize = 50,
    this.queueLimit = 1000,
    this.sessionTimeout = const Duration(minutes: 30),
    this.autoCaptureDeepLinks = true,
    this.shortLinkHosts = const ['fera.fly'],
    this.appVersion,
    this.appBuild,
    this.attribution,
    this.debug = false,
    this.installCode,
    this.metaAppId,
    this.signingKey,
  });

  /// Public proje anahtarı; yalnız `x-feralin-project-key` başlığında taşınır.
  final String projectKey;

  /// Collector kökü, ör. `https://collect.example.com`.
  final String collectUrl;

  /// `null`: izin bekleniyor; olay üretilmez, depodaki kuyruk silinmez.
  final Consent? consent;

  /// Ön plandayken ilk olaydan sonra gönderim gecikmesi; kuyruk boşken zamanlayıcı yoktur.
  final Duration flushInterval;

  /// Tek istekteki en fazla olay (1…500).
  final int batchSize;

  /// Kalıcı kuyruk üst sınırı; aşılınca en eski olay atılır.
  final int queueLimit;

  /// Arka planda bu süre geçerse sonraki ön plana çıkışta yeni `session_id` üretilir.
  final Duration sessionTimeout;

  /// Android'de App Link niyetleri otomatik işlensin mi. iOS'ta yerel kod olmadığından etkisizdir.
  final bool autoCaptureDeepLinks;

  /// Fera Fly kısa link hostları. Bu hostlardan birine (ya da alt alanına, `marka.fera.fly`) ait adresle açılışta SDK linki yönlendiriciden
  /// çözümler. Markalı alanınız varsa listeye ekleyin.
  final List<String> shortLinkHosts;

  /// Uygulama sürümü. Android'de verilmezse kanaldan okunur; iOS'ta yalnız buradan gelir.
  final String? appVersion;

  /// Uygulama yapı numarası. Android'de verilmezse kanaldan okunur; iOS'ta yalnız buradan gelir.
  final String? appBuild;

  /// Kurulum kimliği bağlama (`bindInstall`) için SaaS API adresi; yoksa `AdServicesStatus.notConfigured` döner.
  final AttributionConfig? attribution;

  /// `true` ise olay adı ve durum kodu yazılır; anahtar ve özellik değeri asla yazılmaz.
  final bool debug;

  /// Panelin "Kurulumu doğrula" ekranında üretilen tek kullanımlık eşleştirme kodu (ör. `ABCDE-FGHJK`). Verilirse süreçte
  /// üretilen ilk olaya `fr_install_code` olarak eklenir; sunucu kodu olay verisinden söker ve bu kurulumu projeye bağlar.
  /// Kişisel veri değildir, 30 dakika geçerlidir; doğrulamadan sonra kaldırılabilir. Biçimi bozuk kod yok sayılır.
  final String? installCode;

  /// Facebook uygulama kimliği (Meta App ID). Verilirse Android'de Meta reklamından gelen kurulumun kampanya verisi Facebook/Instagram
  /// uygulamasından okunur (Meta Install Referrer; Facebook SDK gerekmez). Çözme anahtarı panelde projeye girilir, uygulamaya konmaz.
  final String? metaAppId;

  /// SDK imza anahtarı (panelde Atıf > Dolandırıcılık koruması). Verilirse ilk açılış ve link açılışı olayları imzalanır (`fr_sig`);
  /// sunucu imzasız ya da bozuk imzalı kurulumu projenin kuralına göre işaretler ya da reddeder. Anahtar uygulamaya gömülüdür:
  /// sürüm başına ayrı anahtar üretip eskisini panelden iptal edebilirsiniz.
  final SigningKey? signingKey;

  /// Hata mesajı döner; geçerliyse `null`. Mesajda anahtar değeri bulunmaz.
  String? validationError() {
    if (projectKey.trim().isEmpty) return 'projectKey zorunlu';
    if (projectKey.startsWith('sk_')) {
      return 'gizli anahtar istemci uygulamasında kullanılamaz';
    }
    if (!collectUrl.startsWith('https://') &&
        !collectUrl.startsWith('http://')) {
      return 'collectUrl http(s) olmalı';
    }
    final attribution = this.attribution;
    if (attribution != null &&
        ((!attribution.apiUrl.startsWith('https://') &&
                !attribution.apiUrl.startsWith('http://')) ||
            attribution.projectId.trim().isEmpty)) {
      return 'attribution.apiUrl http(s) ve projectId dolu olmalı';
    }
    return signingKey?.validationError();
  }
}

/// SDK imza anahtarı: [id] panelde görünen kimlik (`sgn_…`), [secret] üretildiği anda bir kez gösterilen değer (`fsk_…`).
class SigningKey {
  const SigningKey({required this.id, required this.secret});

  static final RegExp _idPattern = RegExp(r'^sgn_[a-z0-9]{12,40}$');

  final String id;
  final String secret;

  /// Hata mesajı döner; geçerliyse `null`. Mesajda anahtar değeri bulunmaz.
  String? validationError() {
    if (!_idPattern.hasMatch(id)) return 'signingKey.id biçimi geçersiz';
    if (secret.length < 16 || secret.length > 200) {
      return 'signingKey.secret 16-200 karakter olmalı';
    }
    return null;
  }

  /// Anahtar değeri loglara ve hata dökümlerine düşmesin.
  @override
  String toString() => 'SigningKey(id=$id)';
}

/// Gönderim sonucu. [status] 0 ise istek yapılmadı veya ağ hatası oluştu.
class FlushResult {
  const FlushResult({
    required this.sent,
    required this.accepted,
    required this.rejected,
    required this.status,
    this.batchId,
  });

  static const FlushResult none = FlushResult(
    sent: 0,
    accepted: 0,
    rejected: 0,
    status: 0,
  );

  final int sent;
  final int accepted;
  final int rejected;
  final int status;
  final String? batchId;
}

/// Uygulamanın kendi tanısı için anlık durum.
class FeralinStatus {
  const FeralinStatus({
    required this.initialized,
    required this.sdk,
    required this.version,
    required this.queued,
    this.consent,
    this.anonymousId,
    this.sessionId,
    this.userId,
  });

  final bool initialized;
  final String sdk;
  final String version;
  final int queued;
  final Consent? consent;
  final String? anonymousId;
  final String? sessionId;
  final String? userId;
}

/// Ertelenmiş derin bağlantı sonucu.
enum DeferredDeepLinkStatus {
  /// Yol bu çağrıda teslim edildi; ikinci çağrı [none] döner.
  delivered,

  /// Referrer okundu, teslim edilecek yol yok ya da daha önce teslim edildi.
  none,

  /// Reklam ölçümü izni yok: referrer okunmaz. İzin gelince yeniden çağrılabilir.
  consentRequired,

  /// iOS: App Store parametreyi kuruluma taşımaz, parmak iziyle eşleştirme yasaktır.
  notSupported,

  /// SDK başlatılmadı.
  notInitialized,
}

/// Kısa linkle açılışın sonucu ([Feralin.handleShortLink]). [destination] dışarıdan gelen veridir: uygulama yolu kendi yönlendirme
/// tablosuyla eşleştirmeli, doğrudan yetkili bir eylem çalıştırmamalıdır.
class ShortLinkOpen {
  const ShortLinkOpen({
    required this.destination,
    this.linkCode,
    this.hasClickId = false,
  });

  /// Uygulamanın açacağı yol: çözümlenen linkin derin yolu (yoksa `/`), çözümlenemediyse adresin kendi yolu.
  final String destination;

  /// Kısa kod; çözümleme yapılmadıysa `null`.
  final String? linkCode;

  /// Tıklama kimliği alındı mı (reklam ölçümü izni yoksa olaya eklenmez).
  final bool hasClickId;
}

/// Kurulumdan sonra uygulamaya verilen uygulama içi yol. [path] dışarıdan gelen veridir: Play bağlantısını başkası da
/// üretebilir. Uygulama yolu kendi yönlendirme tablosuyla eşleştirmeli, doğrudan yetkili bir eylem çalıştırmamalıdır.
class DeferredDeepLink {
  const DeferredDeepLink(this.status, [this.path]);

  final DeferredDeepLinkStatus status;
  final String? path;
}

/// Satın alma türü (`purchase_type`).
enum PurchaseType {
  /// Tek seferlik satın alma.
  purchase,

  /// Abonelik başlangıcı.
  subscriptionStart,

  /// Abonelik yenileme.
  subscriptionRenew,

  /// Abonelik iptali; tutar 0 olabilir.
  subscriptionCancel,
}

/// Makbuz sağlayıcısı.
enum ReceiptProvider { apple, google, stripe }

/// İsteğe bağlı ham makbuz; toplayıcı yalnız sağlayıcı adını ve belirtecin SHA-256 özetini saklar.
class Receipt {
  const Receipt(this.provider, this.token);

  final ReceiptProvider provider;

  /// Makbuz ya da satın alma belirteci (en çok 8192 karakter).
  final String token;
}

/// `trackRevenue` girdisi (F5-E04-T01). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED
/// sayar, aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez.
class RevenueInput {
  const RevenueInput({
    required this.transactionId,
    required this.amountMinor,
    required this.currency,
    this.productId,
    this.quantity = 1,
    this.purchaseType = PurchaseType.purchase,
    this.receipt,
    this.properties,
  });

  /// Mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz; sunucu aynı işlemi ikinci kez saymaz.
  final String transactionId;

  /// Küçük birimde satır toplamı: 49,99 TL için 4999. Ondalık yoktur; `quantity` ile çarpılmaz. Abonelik iptalinde 0.
  final int amountMinor;

  /// ISO 4217, üç büyük harf.
  final String currency;
  final String? productId;
  final int quantity;
  final PurchaseType purchaseType;
  final Receipt? receipt;

  /// Ek özellikler; `verified` ve türevleri düşürülür.
  final Map<String, Object?>? properties;
}

/// AdServices token'ının gönderim durumu (F3-E02-T02, ADR-0007).
enum AdServicesStatus {
  /// Sunucu token'ı kabul etti (202). Sunucu bugün Apple'a sormaz: bu bir atıf kararı değildir.
  received,

  /// Reklam ölçümü izni (analitik + reklam) yok: token alınmaz, kimlik üretilmez.
  skippedNoConsent,

  /// `FeralinConfig.attribution` verilmedi.
  notConfigured,

  /// iOS dışı platform (Android Play Install Referrer yolunu kullanır) ya da iOS yerel köprüsü yok: dürüst no-op.
  unsupported,

  /// Yerel taraf token veremedi (iOS 14.3 öncesi, simülatör, Apple hatası).
  tokenUnavailable,

  /// Sunucu isteği reddetti (4xx); [AdServicesSubmission.httpStatus] ve [AdServicesSubmission.detail] bakınız.
  rejected,

  /// Ağ hatası, 429 ya da 5xx: sonra yeniden denenebilir.
  temporaryFailure,
}

class AdServicesSubmission {
  const AdServicesSubmission(this.status, {this.httpStatus = 0, this.detail});

  final AdServicesStatus status;

  /// 0: istek yapılmadı ya da ağ hatası.
  final int httpStatus;
  final String? detail;
}

/// `bindInstall` sonucu. [installId] müşterinin kendi sunucusuna iletilir; sunucu gizli API anahtarıyla
/// `POST /v1/projects/{id}/attribution/account-links` (`surface=app`, `subject_id=installId`) çağırır. SDK hesap kimliği yazmaz.
class InstallBinding {
  const InstallBinding(this.installId, this.adServices);

  /// Reklam ölçümü izni yoksa ya da iOS dışında `null`.
  final String? installId;
  final AdServicesSubmission adServices;
}
