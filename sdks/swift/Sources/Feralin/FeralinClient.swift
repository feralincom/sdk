import Foundation

/// Tel üzerindeki `sdk` alanı. Üstüne kurulan köprüler (Objective-C) kendi adını verir.
public struct SDKIdentity: Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    public static let swift = SDKIdentity(name: "feralin-swift", version: "0.4.0")
}

/// UTP v1 toplayıcısına (`POST /v1/batch`) olay gönderen istemci. Kuyruk aktör içinde yaşar; aynı anda tek gönderici çalışır.
/// `storageDirectory` verilirse kuyruk ve oturum diskte de tutulur: uygulama kapanınca ya da çökünce gönderilmemiş olaylar
/// bir sonraki açılışta geri yüklenir. Verilmezse kuyruk yalnız bellektedir (eski davranış).
///
/// İzin yoksa olay üretilmez, reklam izni yoksa `fr_click` çıkarılır. 202 → onay; 4xx (429 hariç) → olaylar atılır;
/// 5xx, 429 ve ağ hatası → kuyrukta kalır ve aynı içerik aynı `Idempotency-Key` ile 1 sn → 30 sn geri çekilmeyle yeniden denenir.
public actor FeralinClient {
    public struct Configuration: Sendable {
        public var projectKey: String
        public var collectURL: String
        public var consent: Consent
        /// 0 ise arka plan gönderici kapalıdır.
        public var flushInterval: TimeInterval
        public var batchSize: Int
        public var queueLimit: Int
        public var timeout: TimeInterval
        public var attribution: AttributionConfiguration?
        public var sdk: SDKIdentity
        /// Kalıcı kuyruk ve oturum dosyalarının dizini. nil ise kalıcılık kapalıdır. Varsayılan konum için `FeralinClient.defaultStorageDirectory()`.
        /// Dizin tek bir istemciye aittir. Açılışta `consent.analytics` kapalıysa diskteki kuyruk ve oturum silinir.
        public var storageDirectory: URL?
        /// Son etkinlikten bu kadar saniye sonra yeni `session_id` üretilir (Android ve Flutter ile aynı: 30 dk).
        public var sessionTimeout: TimeInterval
        /// Panelin "Kurulumu doğrula" ekranında üretilen tek kullanımlık eşleştirme kodu (ör. `ABCDE-FGHJK`). Verilirse süreçte üretilen
        /// ilk olaya `fr_install_code` olarak eklenir; sunucu kodu olay verisinden söker ve bu kurulumu projeye bağlar. Kişisel veri
        /// değildir, 30 dakika geçerlidir; doğrulamadan sonra yapılandırmadan kaldırılabilir. Biçimi bozuk kod yok sayılır.
        public var installCode: String?
        /// SDK imza anahtarı; verilirse ilk açılış ve link açılışı olayları imzalanır (`SigningKey`).
        public var signingKey: SigningKey?
        /// Çocuklara yönelik uygulama (COPPA ve benzeri kurallar). true ise reklam ölçümü ve kişiselleştirme izni uygulama ne verirse versin
        /// kapalı sayılır: tıklama kimliği, pano ve AdServices kullanılmaz, olaylar reklam izni kapalı gider. Panelde projenin
        /// "Çocuklara yönelik uygulama" ayarı ayrıca açılmalıdır.
        public var childDirected: Bool
        /// Reklam ölçümü izninin geçerlilik süresi (gün) ve iznin verildiği an. İkisi de verilirse izin bu süreden eskiyse yeniden sorulana
        /// kadar verilmemiş sayılır (`advertisingConsentExpired`). İzin anını uygulama saklar (bu SDK kalıcı izin durumu tutmaz) ve
        /// kullanıcı yeniden onaylayınca `setConsent(_:grantedAt:)` ile yeniler.
        public var consentMaxAgeDays: Int?
        public var advertisingConsentGrantedAt: Date?
        /// SKAdNetwork / AdAttributionKit dönüşüm değeri modülü (`Skan.swift`). nil (varsayılan) ise kapalıdır. Açıkken kiracının şeması
        /// `attribution` adresinden alınır ve izlenen olaylar Apple çağrısına çevrilir; SKAN ATT izni istemediğinden izin durumundan bağımsızdır.
        /// `childDirected` açıksa çalışmaz. `attribution` verilmeden açılırsa kurulum `FeralinError.configuration` fırlatır.
        public var skan: SkanConfiguration?
        /// StoreKit 2 `Transaction.updates` dinleyicisi (varsayılan kapalı, Android'de otomatik yakalama olmadığı gibi). Açıksa doğrulanmış
        /// işlemler `feralin_purchase` olarak gönderilir. Uygulama içinde `purchase()` dönen işlem bu akışa düşmez: onu `trackStoreKitPurchase` ile verin.
        /// StoreKit 2 olmayan platformda (Linux, iOS 15 öncesi) etkisizdir.
        public var captureStoreKitTransactions: Bool
        /// Yalnız testler: macOS üzerinde koşan testin iOS yolunu sınaması için.
        var platformOverride: String?

        public init(
            projectKey: String,
            collectURL: String,
            consent: Consent = Consent(),
            flushInterval: TimeInterval = FeralinClient.defaultFlushInterval,
            batchSize: Int = FeralinClient.defaultBatchSize,
            queueLimit: Int = FeralinClient.defaultQueueLimit,
            timeout: TimeInterval = FeralinClient.defaultTimeout,
            attribution: AttributionConfiguration? = nil,
            sdk: SDKIdentity = .swift,
            storageDirectory: URL? = nil,
            sessionTimeout: TimeInterval = FeralinClient.defaultSessionTimeout,
            installCode: String? = nil,
            signingKey: SigningKey? = nil,
            childDirected: Bool = false,
            consentMaxAgeDays: Int? = nil,
            advertisingConsentGrantedAt: Date? = nil,
            skan: SkanConfiguration? = nil,
            captureStoreKitTransactions: Bool = false
        ) {
            self.projectKey = projectKey
            self.collectURL = collectURL
            self.consent = consent
            self.flushInterval = flushInterval
            self.batchSize = batchSize
            self.queueLimit = queueLimit
            self.timeout = timeout
            self.attribution = attribution
            self.sdk = sdk
            self.storageDirectory = storageDirectory
            self.sessionTimeout = sessionTimeout
            self.installCode = installCode
            self.signingKey = signingKey
            self.childDirected = childDirected
            self.consentMaxAgeDays = consentMaxAgeDays
            self.advertisingConsentGrantedAt = advertisingConsentGrantedAt
            self.skan = skan
            self.captureStoreKitTransactions = captureStoreKitTransactions
        }
    }

    public static let maxBatchSize = 500
    public static let defaultBatchSize = 100
    public static let defaultQueueLimit = 1000
    public static let defaultFlushInterval: TimeInterval = 2
    public static let defaultTimeout: TimeInterval = 10
    public static let defaultCloseTimeout: TimeInterval = 5
    public static let defaultSessionTimeout: TimeInterval = 30 * 60
    public static let schemaVersion = 1

    /// Uygulama Destek dizininde SDK'ya ayrılmış klasör; `Configuration.storageDirectory` için hazır değer. Bulunamazsa nil.
    public static func defaultStorageDirectory() -> URL? {
        FeralinDiskStore.defaultDirectory()
    }

    private static let minBackoff: TimeInterval = 1
    private static let maxBackoff: TimeInterval = 30
    /// Oturum dosyası her olayda değil, en az bu kadar ms aralıkla (ya da oturum değişince) yazılır.
    private static let sessionPersistIntervalMillis: Int64 = 10_000
    /// Oturum zaman aşımının üst sınırı; Int64 taşmasını önler.
    private static let maxSessionTimeout: TimeInterval = 365 * 24 * 3600

    /// `platform` ve `redeem` için değer. Şemada macOS, tvOS, watchOS karşılığı yok; bunlar `other` gider.
    static var platformName: String {
        #if os(iOS) || os(visionOS)
        return "ios"
        #else
        return "other"
        #endif
    }

    private struct QueuedEvent: Sendable {
        let id: String
        let raw: Data
    }

    private let projectKey: String
    private let endpoint: URL
    private let endpointText: String
    private let flushInterval: TimeInterval
    private let batchSize: Int
    private let queueLimit: Int
    private let timeout: TimeInterval
    private let attribution: AttributionConfiguration?
    private let sdk: SDKIdentity
    /// Hata olayı sınırı ve örneklemesi (`Signals.swift`); aynı dosyadaki uzantı erişsin diye `private` değildir.
    var errorLimiter = ErrorLimiter()
    private let platform: String
    private let transport: any Transport
    private let now: @Sendable () -> Date
    private let installIDStore: any InstallIDStore
    /// Kaldırmadan sağ kalan kasa (iOS anahtar zinciri); yeniden kurulum kanıtı için. Apple dışı platformlarda yoktur.
    private let installVault: (any InstallIDStore)?
    private let adServicesTokenProvider: @Sendable () -> AdServicesTokenResult
    private let conversionUpdater: @Sendable (Int, CoarseConversionLevel, Bool, ConversionFrameworks) async -> ConversionUpdateResult
    private let trackingStatusProvider: @Sendable () -> TrackingAuthorizationStatus
    private let diskStore: FeralinDiskStore?
    private let sessionTimeoutMillis: Int64

    private var ulid: ULIDGenerator
    private var consent: Consent
    private var queue: [QueuedEvent]
    // Otomatik oturum: son etkinlikten sessionTimeout sonra yenilenir; diskteki kayıt süreç yeniden başlayınca da kuralı işletir.
    private var sessionID: String
    private var lastActivityMillis: Int64
    private var persistedActivityMillis: Int64?
    // Sonucu bilinmeyen batch aynı içerik ve aynı anahtarla yeniden denenir; sunucu yanıtı yolda kaybolduysa
    // araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
    private var pinned: [QueuedEvent]?
    private var userID: String?
    // Global özellikler (UTP §8.2): `fr_` ile başlamayan her olaya eklenir; olayın kendi özelliği aynı anahtarda kazanır.
    private var globalProperties: [String: FeralinValue] = [:]
    private var installID: String?
    private var lastPushToken: String?
    private var closed = false
    /// Yapılandırmadaki eşleştirme kodu; kuyruğa giren ilk olayla tüketilir.
    private var pendingInstallCode: String?
    private let signingKey: SigningKey?
    private let childDirected: Bool
    private let consentMaxAgeDays: Int?
    private var adConsentGrantedAt: Date?
    private var dropped = 0
    private var backoff: TimeInterval = 0
    private var backoffUntil: TimeInterval = 0
    private var sendTail: Task<FlushResult, Never>?
    private var loop: Task<Void, Never>?
    /// Gönderilmiş gelir işlemleri (`Revenue.swift`); aynı işlem ikinci kez kuyruğa girmez.
    private var purchaseLedger: PurchaseLedger
    /// SKAN modülü (`Skan.swift`); kapalıysa nil. Ayrı dosyadaki uzantı erişsin diye `private` değildir.
    var skanRuntime: SkanRuntime?
    /// SKAN modülünün Apple çağrısı (testlerde sahte); izin denetimi yapmaz, SKAN izin gerektirmez.
    let skanConversionUpdater: @Sendable (Int, CoarseConversionLevel, Bool, ConversionFrameworks) async -> ConversionUpdateResult
    /// StoreKit 2 `Transaction.updates` dinleyicisi (`StoreKitCapture.swift`).
    var storeKitListener: Task<Void, Never>?

    /// - Parameters:
    ///   - transport: Yoksa `URLSessionTransport`.
    ///   - installIDStore: Yoksa `UserDefaults`. Kimlik yalnız analitik izni varken yazılır.
    ///   - adServicesTokenProvider, conversionUpdater, trackingStatusProvider: Testler için; varsayılanları Apple çerçevelerini çağırır.
    public init(
        configuration: Configuration,
        transport: (any Transport)? = nil,
        installIDStore: (any InstallIDStore)? = nil,
        installVault: (any InstallIDStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        adServicesTokenProvider: @escaping @Sendable () -> AdServicesTokenResult = { FeralinApple.adServicesToken() },
        conversionUpdater: @escaping @Sendable (Int, CoarseConversionLevel, Bool, ConversionFrameworks) async -> ConversionUpdateResult = { fine, coarse, lock, frameworks in
            await FeralinApple.updateConversionValue(fine: fine, coarse: coarse, lock: lock, frameworks: frameworks)
        },
        trackingStatusProvider: @escaping @Sendable () -> TrackingAuthorizationStatus = { FeralinApple.trackingAuthorizationStatus() }
    ) throws {
        let key = configuration.projectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("sk_") {
            throw FeralinError.configuration("gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin")
        }
        guard key.hasPrefix("pk_"), key.count >= 8 else {
            throw FeralinError.configuration("proje anahtarı pk_ ile başlamalı")
        }
        let root = try Self.normalizedRoot(configuration.collectURL, field: "collectURL")
        guard configuration.timeout > 0 else {
            throw FeralinError.configuration("timeout pozitif olmalı")
        }
        guard configuration.sessionTimeout > 0 else {
            throw FeralinError.configuration("sessionTimeout pozitif olmalı")
        }
        if let days = configuration.consentMaxAgeDays, !(1...3650).contains(days) {
            throw FeralinError.configuration("consentMaxAgeDays 1-3650 olmalı")
        }
        if let key = configuration.signingKey, !key.isValid {
            throw FeralinError.configuration("signingKey biçimi geçersiz (id sgn_ ile başlamalı, secret 16-200 karakter)")
        }
        if let attribution = configuration.attribution {
            _ = try Self.normalizedRoot(attribution.apiURL, field: "apiURL")
            guard !attribution.projectID.isEmpty else {
                throw FeralinError.configuration("projectID boş olamaz")
            }
        }
        if let skan = configuration.skan {
            guard configuration.attribution != nil else {
                throw FeralinError.configuration("skan modülü şemayı almak için attribution (apiURL, projectID) ister")
            }
            guard skan.schemaRefreshInterval > 0 else {
                throw FeralinError.configuration("schemaRefreshInterval pozitif olmalı")
            }
        }
        let endpointText = root + "/v1/batch"
        guard let endpoint = URL(string: endpointText) else {
            throw FeralinError.configuration("collectURL http veya https şemalı mutlak adres olmalı")
        }

        let limit = max(1, configuration.queueLimit)
        let timeoutMillis = Int64(min(configuration.sessionTimeout, Self.maxSessionTimeout) * 1000)
        let store = configuration.storageDirectory.map { FeralinDiskStore(directory: $0) }
        let startMillis = Wire.epochMillis(now())
        var generator = ULIDGenerator()
        var restored: [QueuedEvent] = []
        if let store, configuration.consent.analytics {
            restored = store.loadQueue(limit: limit).map { QueuedEvent(id: $0.id, raw: Data($0.raw.utf8)) }
        } else {
            // Analitik izni yoksa önceki oturumdan kalan hiçbir şey tutulmaz ve gönderilmez.
            store?.clearQueue()
            store?.clearSession()
        }
        var startSession: String?
        if let store, configuration.consent.analytics, let saved = store.loadSession(), startMillis - saved.lastActivityMillis < timeoutMillis {
            startSession = saved.sessionID
        }
        let openedSession = startSession ?? generator.next(millis: startMillis)
        var persistedMillis: Int64?
        if let store, configuration.consent.analytics, store.saveSession(sessionID: openedSession, lastActivityMillis: startMillis) {
            persistedMillis = startMillis
        }

        self.diskStore = store
        self.sessionTimeoutMillis = timeoutMillis
        self.ulid = generator
        self.queue = restored
        self.sessionID = openedSession
        self.lastActivityMillis = startMillis
        self.persistedActivityMillis = persistedMillis
        self.projectKey = key
        self.endpoint = endpoint
        self.endpointText = endpointText
        self.consent = configuration.consent
        self.flushInterval = configuration.flushInterval
        self.batchSize = max(1, min(configuration.batchSize, Self.maxBatchSize))
        self.queueLimit = limit
        self.timeout = configuration.timeout
        self.attribution = configuration.attribution
        self.sdk = configuration.sdk
        self.platform = configuration.platformOverride ?? Self.platformName
        self.pendingInstallCode = Self.validInstallCode(configuration.installCode)
        self.signingKey = configuration.signingKey
        self.childDirected = configuration.childDirected
        self.consentMaxAgeDays = configuration.consentMaxAgeDays
        self.adConsentGrantedAt = configuration.advertisingConsentGrantedAt
        self.transport = transport ?? URLSessionTransport()
        self.now = now
        self.installIDStore = installIDStore ?? UserDefaultsInstallIDStore()
        #if canImport(Security)
        self.installVault = installVault ?? KeychainInstallIDStore()
        #else
        self.installVault = installVault
        #endif
        self.adServicesTokenProvider = adServicesTokenProvider
        self.conversionUpdater = conversionUpdater
        self.skanConversionUpdater = conversionUpdater
        self.trackingStatusProvider = trackingStatusProvider
        // Gelir kaydı yalnız kalıcı kuyrukla birlikte diske yazılır: kuyruk bellekteyse ve süreç ölürse kayıt "gönderildi" deyip olayı
        // kaybettirmesin (StoreKit bitmemiş işlemi yeniden bildirir, sunucu `transaction_id` ile tekilleştirir).
        if let store, configuration.consent.analytics {
            self.purchaseLedger = PurchaseLedger(keys: store.loadPurchaseKeys())
        } else {
            store?.clearPurchaseKeys()
            self.purchaseLedger = PurchaseLedger()
        }
        // SKAN çocuklara yönelik uygulamada çalışmaz (reklam ölçümü kapalı); öteki durumlarda izin değil uygulama ayarı açar.
        let skanEnabled: Bool
        if let skan = configuration.skan, !configuration.childDirected {
            let skanStore: any SkanStateStore = store.map { DiskSkanStateStore(store: $0) } ?? UserDefaultsSkanStateStore()
            self.skanRuntime = SkanRuntime(configuration: skan, store: skanStore, state: skanStore.load() ?? SkanState(), tail: nil, lastResult: nil)
            skanEnabled = true
        } else {
            self.skanRuntime = nil
            skanEnabled = false
        }

        // Geri yüklenen olaylar yeni bir track beklemeden arka plan göndericiyle gönderilsin.
        if !restored.isEmpty {
            Task { [weak self] in await self?.startLoopIfNeeded() }
        }
        if skanEnabled {
            Task { [weak self] in await self?.startSkan() }
        }
        #if canImport(StoreKit)
        if configuration.captureStoreKitTransactions, #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) {
            Task { [weak self] in await self?.startStoreKitTransactionCapture() }
        }
        #endif
    }

    private static func normalizedRoot(_ value: String, field: String) throws -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            throw FeralinError.configuration("\(field) http veya https şemalı mutlak adres olmalı")
        }
        return text
    }

    // MARK: - Genel API

    /// İzin durumunu günceller. `analytics` false ise bekleyen olaylar atılır, yeni olay üretilmez ve saklı kurulum kimliği silinir.
    /// `advertising` uygulamanın kararıdır; ATT izin vermiyorsa her kullanımda kapalı sayılır (`Consent.constrained(by:)`).
    public func setConsent(_ newConsent: Consent) {
        consent = newConsent
        if !newConsent.analytics {
            queue.removeAll()
            pinned = nil
            installID = nil
            installIDStore.clear()
            diskStore?.clearQueue()
            diskStore?.clearSession()
            persistedActivityMillis = nil
            purchaseLedger.removeAll()
            diskStore?.clearPurchaseKeys()
        }
    }

    /// Sonraki olaylar için varsayılan `user_id`; nil varsayılanı kaldırır. Yalnız uygulamanın kendi opak kimliği verilir, e-posta verilmez.
    public func identify(_ id: String?) throws {
        userID = try Wire.validateIdentifier(id, field: "user_id")
    }

    /// Kullanıcı kimliğini kaldırır, global özellikleri siler ve kurulum kimliğini yeniler (çıkış senaryosu).
    public func reset() {
        userID = nil
        globalProperties.removeAll()
        installID = nil
        installIDStore.clear()
        startNewSession()
    }

    /// Geçerli otomatik oturum kimliği. Olaylara `sessionID` verilmedikçe bu değer `session_id` olarak yazılır.
    public var currentSessionID: String { sessionID }

    /// Uygulama arka plana geçerken çağrılır (örn. `UIApplication.didEnterBackgroundNotification`). Son etkinlik zamanını diske yazar;
    /// kuyruk zaten her değişimde yazıldığından ayrıca bir şey kaybolmaz. Gönderim için `flush()` hâlâ uygulamanındır.
    public func didEnterBackground() {
        guard !closed else { return }
        advanceSession(force: true)
    }

    /// Uygulama ön plana dönerken çağrılır. Son etkinlikten `sessionTimeout` geçmişse yeni `session_id` üretilir.
    public func willEnterForeground() {
        guard !closed else { return }
        advanceSession(force: false)
    }

    /// Eşleştirme kodu biçimi (sunucu ve öteki SDK'larla aynı): Crockford Base32 harf ve rakamları, boşluk, `_` ve `-`; 10-16 karakter.
    static func validInstallCode(_ raw: String?) -> String? {
        guard let code = raw?.trimmingCharacters(in: .whitespacesAndNewlines), (10...16).contains(code.utf8.count) else { return nil }
        let allowed = "0123456789ABCDEFGHJKMNPQRSTVWXYZabcdefghjkmnpqrstvwxyz _-"
        return code.allSatisfy({ allowed.contains($0) }) ? code : nil
    }

    /// Olayı doğrular, UTP v1 biçimine çevirir ve kuyruğa ekler; ağ çağrısı yapmaz.
    /// `analytics` izni yoksa olay üretilmez ve nil döner. Doğrulama hatasında `FeralinError.invalidEvent` fırlatır.
    @discardableResult
    public func track(
        _ eventName: String,
        properties: [String: FeralinValue]? = nil,
        userID eventUserID: String? = nil,
        anonymousID: String? = nil,
        sessionID: String? = nil,
        occurredAt: Date? = nil,
        context: Context? = nil
    ) throws -> TrackedEvent? {
        if closed { throw FeralinError.clientClosed }
        // SKAN dönüşüm değeri izin gerektirmez (Apple: ATT'den bağımsız, kişi tanımlamaz); modül açıksa olay izin denetiminden önce görülür.
        if skanRuntime != nil { observeSkan(eventName) }
        let effective = effectiveConsent
        guard effective.analytics else { return nil }

        let name = try Wire.validateEventName(eventName)
        var props = try Wire.validateProperties(properties)
        if !globalProperties.isEmpty, !ProfileRules.isSystemEvent(name) {
            var merged = props ?? [:]
            for key in globalProperties.keys.sorted() where merged[key] == nil && merged.count < Wire.maxProperties {
                merged[key] = globalProperties[key]
            }
            props = merged.isEmpty ? nil : merged
        }
        // fr_click ve isteğe bağlı reklam kimliği yalnız açık reklam ölçümü izniyle gönderilir (çocuk kipinde ve ATT reddinde izin kapalıdır).
        if !effective.advertising, props != nil {
            props?.removeValue(forKey: Wire.attributionClickProperty)
            props?.removeValue(forKey: Wire.advertisingIDProperty)
            if props?.isEmpty == true { props = nil }
        }
        // Yapılandırmadaki eşleştirme kodu ilk olaya eklenir (Android, Flutter ve Web SDK'larıyla aynı sözleşme).
        let installCode = pendingInstallCode
        if let installCode {
            var withCode = props ?? [:]
            withCode[Wire.installCodeProperty] = .string(installCode)
            props = withCode
        }
        let uid = try Wire.validateIdentifier(eventUserID, field: "user_id") ?? userID
        let aid = try Wire.validateIdentifier(anonymousID, field: "anonymous_id") ?? ensureInstallID()
        let explicitSession = try Wire.validateIdentifier(sessionID, field: "session_id")
        // Olay üretilecek: etkinlik sayılır ve gerekirse oturum yenilenir (açıkça verilen session_id otomatik oturumu değiştirmez).
        advanceSession(force: false)
        let sid: String = explicitSession ?? self.sessionID

        let eventID = ulid.next(millis: Wire.epochMillis(now()))
        // Atıf olayı reklam izninin verildiği anı taşır: sunucu projenin izin süresi kuralını bu değerle uygular.
        if effective.advertising, let grantedAt = adConsentGrantedAt, EventSigner.signedEvents.contains(name) {
            var stamped = props ?? [:]
            stamped["consent_at"] = .string(Wire.formatTime(grantedAt))
            props = stamped
        }
        // Atıf olayları imzalanır (anahtar verildiyse): imza olayın kimliğine ve kurulum kimliğine bağlıdır.
        if let signingKey, EventSigner.signedEvents.contains(name) {
            var signed = props ?? [:]
            signed[EventSigner.property] = .string(EventSigner.sign(key: signingKey, atSeconds: Wire.epochMillis(now()) / 1000, eventID: eventID, eventName: name, anonymousID: aid))
            props = signed
        }
        let occurred = Wire.formatTime(occurredAt ?? now())
        var wire: [String: FeralinValue] = [
            "event_id": .string(eventID),
            "event_name": .string(name),
            "occurred_at": .string(occurred),
            "platform": .string(platform),
            "schema_version": .int(Int64(Self.schemaVersion)),
            "sdk": .object(["name": .string(sdk.name), "version": .string(sdk.version)]),
            "consent": effective.wire,
        ]
        wire["anonymous_id"] = .string(aid)
        if let uid { wire["user_id"] = .string(uid) }
        wire["session_id"] = .string(sid)
        if let props { wire["properties"] = .object(props) }
        if let contextWire = context?.wire, !contextWire.isEmpty { wire["context"] = .object(contextWire) }

        // Serileştirme kuyruğa eklemeden önce yapılır; bozuk bir olay batch'i zehirleyemez.
        let raw: Data
        do {
            raw = try Self.encoder().encode(FeralinValue.object(wire))
        } catch {
            throw FeralinError.invalidEvent("olay JSON'a dönüştürülemedi")
        }

        queue.append(QueuedEvent(id: eventID, raw: raw))
        // Kod yalnız kuyruğa gerçekten giren olayla tüketilir: doğrulamada düşen olay kodu harcamaz.
        if installCode != nil { pendingInstallCode = nil }
        let over = queue.count - queueLimit
        if over > 0 {
            queue.removeFirst(over)
            dropped += over
        }
        persistQueue()
        startLoopIfNeeded()
        if queue.count >= batchSize, flushInterval > 0 {
            Task { [weak self] in await self?.tick() }
        }
        return TrackedEvent(eventID: eventID, eventName: name, occurredAt: occurred, userID: uid, anonymousID: aid, sessionID: sid, properties: props, consent: effective)
    }

    /// Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve temizlenmiş özellikler. Grup kimliği 1-128
    /// karakter olmalı, `@` ve kontrol karakteri içermemelidir; uymazsa olay üretilmez ve nil döner. Kişisel veriye benzeyen, doğrulama
    /// alanı olan ve sözleşme dışı değerli özellik düşer. Toplayıcı yalnız projenin izin listesindeki özellikleri saklar.
    @discardableResult
    public func group(_ groupID: String, traits: [String: FeralinValue]? = nil) throws -> TrackedEvent? {
        guard ProfileRules.isValidGroupID(groupID) else { return nil }
        var props = ProfileRules.sanitize(traits).properties
        props["group_id"] = .string(groupID)
        return try track(ProfileRules.groupEventName, properties: props)
    }

    /// Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad vb.),
    /// doğrulama alanı ve sözleşme dışı değer düşer; geçerli özellik kalmazsa olay üretilmez ve nil döner. Toplayıcı yalnız projenin izin
    /// listesindeki anahtarları saklar (liste boşsa hiçbirini).
    @discardableResult
    public func setUserProperties(_ properties: [String: FeralinValue]) throws -> TrackedEvent? {
        let clean = ProfileRules.sanitize(properties).properties
        guard !clean.isEmpty else { return nil }
        return try track(ProfileRules.userPropertiesEventName, properties: clean)
    }

    /// Global özellikleri birleştirir: `fr_` ile başlamayan her olaya eklenir, olayın kendi özelliği aynı anahtarda kazanır. `.null` değer
    /// anahtarı siler. Kurallar `setUserProperties` ile aynıdır; toplam en çok 50 anahtar. `reset()` globalleri de siler. Düşen anahtar sayısını döner.
    @discardableResult
    public func setGlobalProperties(_ properties: [String: FeralinValue]) -> Int {
        let result = ProfileRules.sanitize(properties, allowNull: true)
        var dropped = result.dropped
        for key in result.properties.keys.sorted() {
            guard let value = result.properties[key] else { continue }
            if value == .null {
                globalProperties.removeValue(forKey: key)
            } else if globalProperties[key] != nil || globalProperties.count < ProfileRules.maxProperties {
                globalProperties[key] = value
            } else {
                dropped += 1
            }
        }
        return dropped
    }

    /// Bütün global özellikleri siler.
    public func clearGlobalProperties() {
        globalProperties.removeAll()
    }

    /// Kuyruktaki tüm olayları batch'ler hâlinde gönderir; geri çekilme beklemez, çünkü açık çağrı niyet sayılır.
    /// Teslim hatası fırlatmaz, sonuç `FlushResult.error` içinde döner.
    public func flush() async throws -> FlushResult {
        if closed { throw FeralinError.clientClosed }
        return await serializedFlush(deadline: nil)
    }

    /// Arka plan göndericiyi durdurur ve kalan olayları en fazla `timeout` saniyede göndermeyi dener. Birden çok çağrı güvenlidir.
    @discardableResult
    public func close(timeout closeTimeout: TimeInterval = FeralinClient.defaultCloseTimeout) async -> FlushResult {
        if closed { return FlushResult() }
        closed = true
        loop?.cancel()
        loop = nil
        storeKitListener?.cancel()
        storeKitListener = nil
        return await serializedFlush(deadline: Self.monotonicNow() + max(0, closeTimeout))
    }

    /// Öteki SDK'larla aynı deterministik anahtar: sıralı `event_id` değerlerinin FNV-1a 64 özeti ve sayı.
    public static func idempotencyKey(for eventIDs: [String]) -> String {
        Wire.idempotencyKey(for: eventIDs)
    }

    public var queuedCount: Int { queue.count }

    /// Anlık durum (debug ve sağlık amaçlı). Anahtar döndürülmez.
    public func status() -> ClientStatus {
        ClientStatus(sdk: sdk.name, version: sdk.version, queued: queue.count, dropped: dropped, consent: effectiveConsent, userID: userID, closed: closed, backoff: backoff, endpoint: endpointText)
    }

    // MARK: - Attribution

    /// AdServices token'ını alır ve gönderir. `token` verilirse o gönderilir. Sunucu token'ı saklar ama Apple'a sormaz; sonuç atıf kararı değildir.
    /// Analitik ve reklam izni birlikte yoksa veya ATT izin vermiyorsa token alınmaz, verilen token da gönderilmez.
    public func submitAdServicesToken(_ token: String? = nil) async -> AdServicesSubmission {
        guard let attribution else { return .notConfigured }
        guard advertisingAllowed else { return .skippedNoConsent }

        let value: String
        if let token {
            value = token
        } else {
            let provider = adServicesTokenProvider
            // attributionToken() eşzamanlıdır; aktörü bloke etmesin.
            let result = await Task.detached(priority: .utility) { provider() }.value
            switch result {
            case .token(let fetched): value = fetched
            case .notSupported: return .notSupported
            case .failed(let message): return .tokenUnavailable(message)
            }
        }
        // İstek sürerken izin geri çekildiyse göndermeyiz.
        guard advertisingAllowed else { return .skippedNoConsent }
        let install = ensureInstallID()
        let body: FeralinValue = .object(["token": .string(value), "install_id": .string(install)])
        let response: TransportResponse
        do {
            response = try await post(attribution: attribution, path: "attribution/apple-adservices/tokens", body: body)
        } catch {
            return .temporaryFailure(status: 0, message: Self.message(of: error))
        }
        switch response.status {
        case 202:
            guard let receipt = try? JSONDecoder().decode(AdServicesReceipt.self, from: response.body) else {
                return .temporaryFailure(status: 202, message: "yanıt çözümlenemedi")
            }
            return .received(receipt)
        case 429, 500...:
            return .temporaryFailure(status: response.status, message: Self.problemSummary(response.body))
        default:
            return .rejected(status: response.status, detail: Self.problemSummary(response.body))
        }
    }

    /// Kurulum kimliği (ADR-0007): AdServices token'ı, kullanıcı onayı kararı ve hesap bağı aynı kimliğe bağlanır. Reklam ölçümü izni
    /// (analitik + reklam, ATT dâhil) yoksa `nil` döner ve kimlik üretilmez. Müşteri bu değeri kendi sunucusuna iletir.
    public func installIdentifier() -> String? {
        guard advertisingAllowed else { return nil }
        return ensureInstallID()
    }

    /// Kurulumu bağlar: AdServices token'ını (varsa) bu kurulum kimliğiyle gönderir ve kimliği döndürür. Sunucu bugün Apple'a sormaz,
    /// token saklanır; kesin atıf iddia edilmez. Hesap bağı için `installID`'yi sunucunuza iletin (`InstallBinding`).
    public func bindInstall() async -> InstallBinding {
        let submission = await submitAdServicesToken()
        // İzin gönderim sırasında geri çekildiyse kimlik de verilmez.
        return InstallBinding(installID: installIdentifier(), adServices: submission)
    }

    /// Kullanıcının kendisinin girdiği ya da tarattığı devam kodunu kullanır. Pano okunmaz: bu yöntem yalnız kullanıcı eylemiyle çağrılmalıdır.
    /// Sonuç eşleşen ilk açılıştır (`user_confirmed`), Apple indirme sayısı ya da reklam kanıtı değildir.
    public func redeemContinuityCode(_ code: String) async -> ContinuityRedemption {
        guard let attribution else { return .notConfigured }
        guard platform == "ios" else { return .notSupported }
        guard advertisingAllowed else { return .skippedNoConsent }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidCode }

        let body: FeralinValue = .object([
            "code": .string(trimmed),
            "install_id": .string(ensureInstallID()),
            "platform": .string(platform),
            "consent": .bool(true),
            "user_action": .bool(true),
        ])
        let response: TransportResponse
        do {
            response = try await post(attribution: attribution, path: "attribution/continuity-tokens/redeem", body: body)
        } catch {
            return .temporaryFailure(status: 0, message: Self.message(of: error))
        }
        switch response.status {
        case 200:
            guard let confirmation = try? JSONDecoder().decode(UserConfirmation.self, from: response.body) else {
                return .temporaryFailure(status: 200, message: "yanıt çözümlenemedi")
            }
            return .confirmed(confirmation)
        case 404: return .invalidCode
        case 409: return .selfRedeem
        case 429: return .rateLimited
        case 500...: return .temporaryFailure(status: response.status, message: Self.problemSummary(response.body))
        default: return .rejected(status: response.status, detail: Self.problemSummary(response.body))
        }
    }

    /// Dönüşüm değerini Apple çerçevelerine bildirir. Reklam izni yoksa veya ATT izin vermiyorsa hiçbiri çağrılmaz.
    public func updateConversionValue(
        fine: Int,
        coarse: CoarseConversionLevel,
        lock: Bool = false,
        frameworks: ConversionFrameworks = .both
    ) async -> ConversionUpdateResult {
        guard advertisingAllowed else {
            return ConversionUpdateResult(adAttributionKit: .skippedNoConsent, skAdNetwork: .skippedNoConsent)
        }
        return await conversionUpdater(fine, coarse, lock, frameworks)
    }

    // MARK: - İç işleyiş

    /// Uygulamanın kararı ATT ile daraltılır. Durum her kullanımda okunur: kullanıcı Ayarlar'dan değiştirebilir, uygulama
    /// `constrained(by:)` çağırmayı unutsa da `denied` iken reklam verisi çıkmaz. Uygulamanın kararı saklı kaldığından
    /// ATT sonradan `authorized` olursa reklam izni yeniden `setConsent` gerekmeden açılır.
    private var effectiveConsent: Consent {
        var effective = consent.constrained(by: trackingStatusProvider())
        // Çocuklara yönelik uygulamada reklam ölçümü ve kişiselleştirme her zaman kapalıdır; süresi dolan izin verilmemiş sayılır.
        if childDirected {
            effective.advertising = false
            effective.personalization = false
        }
        if advertisingConsentExpired { effective.advertising = false }
        return effective
    }

    /// Reklam ölçümü izninin süresi doldu mu? `consentMaxAgeDays` ve izin anı verilmişse hesaplanır; uygulama kullanıcıya yeniden sormalıdır.
    public var advertisingConsentExpired: Bool {
        guard let days = consentMaxAgeDays, let grantedAt = adConsentGrantedAt, consent.advertising else { return false }
        return now().timeIntervalSince(grantedAt) > TimeInterval(days) * 86_400
    }

    /// İzin durumunu ve reklam ölçümü izninin verildiği anı birlikte günceller (izin süresi kuralı için).
    public func setConsent(_ newConsent: Consent, grantedAt: Date?) {
        adConsentGrantedAt = newConsent.advertising ? grantedAt : nil
        setConsent(newConsent)
    }

    private var advertisingAllowed: Bool {
        let effective = effectiveConsent
        return effective.analytics && effective.advertising
    }

    // Links.swift uzantısının kullandığı iç erişimler (ayrı dosyadaki uzantı `private` üyelere erişemez).
    var attributionConfiguration: AttributionConfiguration? { attribution }

    /// Kısa link çözümlemesi (Fera Fly) için ham istek; proje anahtarı ve olay gövdesi taşımaz.
    func sendLinkRequest(_ request: TransportRequest) async throws -> TransportResponse {
        try await transport.send(request)
    }

    /// Reklam ölçümü izni (kısa link çözümlemesinde tıklama kanıtı yazılıp yazılmayacağını belirler).
    var linkAttributionAllowed: Bool { advertisingAllowed }

    func postAttribution(_ attribution: AttributionConfiguration, path: String, body: FeralinValue) async throws -> TransportResponse {
        try await post(attribution: attribution, path: path, body: body)
    }

    /// Atıf API'sine `GET` (SKAN şeması); proje anahtarı `Authorization: Bearer` ile gider.
    func getAttribution(_ attribution: AttributionConfiguration, path: String) async throws -> TransportResponse {
        let base = try attributionRequest(attribution: attribution, path: path, body: Data())
        // GET gövde taşımaz; Content-Type gönderilmez.
        var request = TransportRequest(url: base.url, body: Data(), headers: base.headers.filter { $0.key != "Content-Type" }, timeout: base.timeout)
        request.method = "GET"
        return try await transport.send(request)
    }

    /// Saat (testlerde sahte).
    func currentTime() -> Date { now() }

    var isClosed: Bool { closed }

    // Gelir kaydı (`Revenue.swift`).
    func purchaseAlreadyTracked(_ key: String) -> Bool { purchaseLedger.contains(key) }

    func notePurchaseTracked(_ key: String) {
        guard purchaseLedger.insert(key) else { return }
        diskStore?.savePurchaseKeys(purchaseLedger.keys)
    }

    static func describe(_ error: Error) -> String { message(of: error) }

    static func summarize(_ raw: Data) -> String { problemSummary(raw) }

    /// Yeniden kurulum kanıtı: kasadaki kimlik bu kurulumunkinden farklıysa önceki kurulum kimliğidir. Kasa bu kurulumun kimliğiyle
    /// güncellenir. Yalnız analitik izni varken çağrılır (kimlik izin olmadan üretilmez ve yazılmaz).
    func previousInstallIDForFirstOpen() -> String? {
        guard let installVault, consent.analytics else { return nil }
        let current = ensureInstallID()
        let previous = installVault.load()
        installVault.save(current)
        guard let previous, previous != current, Wire.isValidInstallReference(previous) else { return nil }
        return previous
    }

    /// APNs cihaz belirtecini bildirir (kaldırma ölçümü, saas-api 0180): `fr_push_token` olayı. `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// içinden çağrılır. Belirteç olay deposuna yazılmaz; panelde kaldırma ölçümü açık değilse sunucu belirteci saklamaz. Aynı belirteç
    /// bu süreçte ikinci kez gönderilmez.
    @discardableResult
    public func setPushToken(_ deviceToken: Data) throws -> TrackedEvent? {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard (32...200).contains(hex.count), hex != lastPushToken else { return nil }
        let event = try track("fr_push_token", properties: ["push_token": .string(hex)])
        if event != nil { lastPushToken = hex }
        return event
    }

    /// Gelen uzak bildirim Feralin'in kaldırma ölçümü bildirimi mi? `true` ise uygulama hiçbir şey yapmamalıdır (içeriksiz, sessiz bildirimdir).
    public static func isUninstallCheck(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["fr_uninstall_check"] as? String) == "1"
    }

    private func ensureInstallID() -> String {
        if let installID { return installID }
        let value = installIDStore.load() ?? ulid.next(millis: Wire.epochMillis(now()))
        installID = value
        // Kimlik yalnız analitik izni varken diske yazılır; bu yöntem izin denetiminden sonra çağrılır.
        installIDStore.save(value)
        return value
    }

    private func post(attribution: AttributionConfiguration, path: String, body: FeralinValue) async throws -> TransportResponse {
        let data = try Self.encoder().encode(body)
        return try await transport.send(try attributionRequest(attribution: attribution, path: path, body: data))
    }

    private func attributionRequest(attribution: AttributionConfiguration, path: String, body data: Data) throws -> TransportRequest {
        var root = attribution.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let project = attribution.projectID.addingPercentEncoding(withAllowedCharacters: allowed) ?? attribution.projectID
        guard let url = URL(string: "\(root)/v1/projects/\(project)/\(path)") else {
            throw TransportError(message: "geçersiz API adresi")
        }
        let headers = [
            "Content-Type": "application/json",
            "Accept": "application/json, application/problem+json",
            "Authorization": "Bearer \(projectKey)",
            "User-Agent": "\(sdk.name)/\(sdk.version)",
        ]
        return TransportRequest(url: url, body: data, headers: headers, timeout: timeout)
    }

    private func startLoopIfNeeded() {
        guard flushInterval > 0, loop == nil, !closed else { return }
        let nanoseconds = UInt64(flushInterval * 1_000_000_000)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard let self else { return }
                await self.tick()
            }
        }
    }

    /// Arka plan göndericinin bir adımı: geri çekilmeye uyar, kapalıyken ya da kuyruk boşken bir şey yapmaz.
    private func tick() async {
        guard !closed, pinned != nil || !queue.isEmpty, Self.monotonicNow() >= backoffUntil else { return }
        _ = await serializedFlush(deadline: nil)
    }

    /// Aktör askıya alınınca başka bir flush araya girebilir; sabit Idempotency-Key için gönderimler sıraya dizilir.
    private func serializedFlush(deadline: TimeInterval?) async -> FlushResult {
        let previous = sendTail
        let task = Task<FlushResult, Never> { [self] in
            _ = await previous?.value
            return await self.drain(deadline: deadline)
        }
        sendTail = task
        return await task.value
    }

    private func drain(deadline: TimeInterval?) async -> FlushResult {
        var total = FlushResult()
        // Üretici sürekli ekliyorsa döngü sonsuz olmasın: kuyruk sınırı kadar olay + bir tur.
        let maxRounds = queueLimit / batchSize + 2
        for _ in 0..<maxRounds {
            let batch = pinned ?? Array(queue.prefix(batchSize))
            if batch.isEmpty { break }
            var requestTimeout = timeout
            if let deadline {
                let remaining = deadline - Self.monotonicNow()
                if remaining <= 0 {
                    total.error = .temporary(status: 0, message: "kapanış zaman aşımı; olaylar gönderilemedi")
                    break
                }
                requestTimeout = min(requestTimeout, remaining)
            }
            let result = await send(batch, timeout: requestTimeout)
            total.sent += result.sent
            total.accepted += result.accepted
            total.rejected += result.rejected
            total.status = result.status
            if let batchID = result.batchID { total.batchID = batchID }
            if let error = result.error {
                total.error = error
                break
            }
        }
        total.retained = queue.count
        return total
    }

    private func send(_ batch: [QueuedEvent], timeout requestTimeout: TimeInterval) async -> FlushResult {
        let ids = Set(batch.map(\.id))
        var body = Data("{\"sent_at\":\"\(Wire.formatTime(now()))\",\"events\":[".utf8)
        for (index, item) in batch.enumerated() {
            if index > 0 { body.append(UInt8(ascii: ",")) }
            body.append(item.raw)
        }
        body.append(contentsOf: Array("]}".utf8))

        let headers = [
            "Content-Type": "application/json",
            "Accept": "application/json, application/problem+json",
            "X-Feralin-Project-Key": projectKey,
            "Idempotency-Key": Wire.idempotencyKey(for: batch.map(\.id)),
            "User-Agent": "\(sdk.name)/\(sdk.version)",
        ]

        var result = FlushResult()
        result.sent = batch.count

        let response: TransportResponse
        do {
            response = try await transport.send(TransportRequest(url: endpoint, body: body, headers: headers, timeout: requestTimeout))
        } catch {
            pin(batch)
            noteFailure(retryAfter: nil)
            result.retained = batch.count
            result.error = .temporary(status: 0, message: Self.message(of: error))
            return result
        }

        result.status = response.status
        if response.status == 202 {
            let ack = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            acknowledge(ids)
            noteSuccess()
            result.accepted = ack?["accepted"] as? Int ?? batch.count
            result.rejected = ack?["rejected"] as? Int ?? 0
            result.batchID = ack?["batch_id"] as? String
            return result
        }
        if response.status >= 400, response.status < 500, response.status != 429 {
            acknowledge(ids)
            result.rejected = batch.count
            result.error = .rejected(status: response.status, detail: Self.problemSummary(response.body))
            return result
        }
        pin(batch)
        noteFailure(retryAfter: response.header("Retry-After"))
        result.retained = batch.count
        result.error = .temporary(status: response.status, message: "olaylar kuyrukta tutuldu")
        return result
    }

    private func acknowledge(_ ids: Set<String>) {
        pinned = nil
        queue.removeAll { ids.contains($0.id) }
        persistQueue()
    }

    /// Kuyruğu diske yazar; boşsa dosyayı siler. Yazım hatası SDK'yı düşürmez, bellekteki kuyruk geçerli kalır.
    private func persistQueue() {
        guard let diskStore else { return }
        if queue.isEmpty {
            diskStore.clearQueue()
        } else {
            diskStore.saveQueue(queue.map { PersistedEvent(id: $0.id, raw: String(decoding: $0.raw, as: UTF8.self)) })
        }
    }

    /// Etkinliği işler: son etkinlikten `sessionTimeout` geçmişse yeni oturum başlar, sonra etkinlik zamanı güncellenir.
    private func advanceSession(force: Bool) {
        let nowMillis = Wire.epochMillis(now())
        var rotated = false
        if nowMillis - lastActivityMillis >= sessionTimeoutMillis {
            sessionID = ulid.next(millis: nowMillis)
            rotated = true
        }
        lastActivityMillis = nowMillis
        persistSession(force: force || rotated)
    }

    private func startNewSession() {
        let nowMillis = Wire.epochMillis(now())
        sessionID = ulid.next(millis: nowMillis)
        lastActivityMillis = nowMillis
        persistSession(force: true)
    }

    /// Oturum dosyası yalnız analitik izni varken yazılır; sık yazımı önlemek için aralıklıdır.
    private func persistSession(force: Bool) {
        guard let diskStore, consent.analytics else { return }
        if !force, let last = persistedActivityMillis, lastActivityMillis - last < Self.sessionPersistIntervalMillis { return }
        if diskStore.saveSession(sessionID: sessionID, lastActivityMillis: lastActivityMillis) {
            persistedActivityMillis = lastActivityMillis
        }
    }

    /// İstek sürerken izin geri çekildiyse olaylar çoktan silinmiştir, sabitlenmez.
    private func pin(_ batch: [QueuedEvent]) {
        if consent.analytics { pinned = batch }
    }

    /// Üstel geri çekilme 1 sn → 30 sn; `Retry-After` verilmişse en az o kadar beklenir. Yarım jitter süreçleri ayrıştırır.
    private func noteFailure(retryAfter: String?) {
        var next = max(backoff * 2, Self.minBackoff)
        var floor: TimeInterval = 0
        if let retryAfter, let seconds = Int(retryAfter.trimmingCharacters(in: .whitespaces)), seconds > 0 {
            floor = min(TimeInterval(seconds), Self.maxBackoff)
            next = max(next, TimeInterval(seconds))
        }
        next = min(next, Self.maxBackoff)
        backoff = next
        backoffUntil = Self.monotonicNow() + max(floor, next * (0.5 + Double.random(in: 0...1) * 0.5))
    }

    private func noteSuccess() {
        backoff = 0
        backoffUntil = 0
    }

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    private static func message(of error: Error) -> String {
        (error as? TransportError)?.message ?? "ağ hatası"
    }

    /// RFC 7807 gövdesinden kısa, loglanabilir özet; ham gövde sızdırılmaz.
    private static func problemSummary(_ raw: Data) -> String {
        guard let problem = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            return "problem+json yok"
        }
        let text = ["title", "detail"]
            .compactMap { problem[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text.isEmpty ? "problem+json yok" : String(text.prefix(200))
    }
}
