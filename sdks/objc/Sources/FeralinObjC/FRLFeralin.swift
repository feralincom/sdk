#if canImport(ObjectiveC)
import Feralin
import Foundation

/// Hata alanı. `FRLErrorCode` değerlerini taşır.
public let FRLFeralinErrorDomain = "com.feralin.sdk.objc"

@objc public enum FRLErrorCode: Int {
    case configuration = 1
    case invalidEvent = 2
    case clientClosed = 3
    case rejected = 4
    case temporary = 5
}

@objc public enum FRLTrackingAuthorizationStatus: Int {
    case notDetermined
    case restricted
    case denied
    case authorized
    case unavailable
}

@objc public enum FRLCoarseConversionValue: Int {
    case low
    case medium
    case high
}

/// İzin anlık görüntüsü; değiştirilemez.
@objc(FRLConsent)
public final class FRLConsent: NSObject {
    @objc public let analytics: Bool
    @objc public let advertising: Bool
    @objc public let personalization: Bool
    @objc public let sessionReplay: Bool

    @objc public init(analytics: Bool, advertising: Bool, personalization: Bool, sessionReplay: Bool) {
        self.analytics = analytics
        self.advertising = advertising
        self.personalization = personalization
        self.sessionReplay = sessionReplay
    }

    /// Hepsi kapalı: izin verilene kadar olay üretilmez.
    @objc public override convenience init() {
        self.init(analytics: false, advertising: false, personalization: false, sessionReplay: false)
    }

    /// ATT sonucunu reklam iznine yansıtır; yalnız `authorized` reklam iznini korur, hayır kararını evete çevirmez.
    @objc public func constrained(byTrackingStatus status: FRLTrackingAuthorizationStatus) -> FRLConsent {
        let result = swiftValue.constrained(by: status.swiftValue)
        return FRLConsent(analytics: result.analytics, advertising: result.advertising, personalization: result.personalization, sessionReplay: result.sessionReplay)
    }

    var swiftValue: Consent {
        Consent(analytics: analytics, advertising: advertising, personalization: personalization, sessionReplay: sessionReplay)
    }
}

/// `FRLFeralin` ayarları.
@objc(FRLConfiguration)
public final class FRLConfiguration: NSObject {
    @objc public let projectKey: String
    @objc public let collectURL: String
    @objc public var consent = FRLConsent()
    /// 0 ise arka plan gönderici kapalıdır.
    @objc public var flushInterval: TimeInterval = FeralinClient.defaultFlushInterval
    @objc public var batchSize: Int = FeralinClient.defaultBatchSize
    @objc public var queueLimit: Int = FeralinClient.defaultQueueLimit
    @objc public var timeout: TimeInterval = FeralinClient.defaultTimeout
    /// Attribution çağrıları için; ikisi de verilmezse bu yöntemler `not_configured` döner.
    @objc public var apiURL: String?
    @objc public var projectID: String?

    @objc public init(projectKey: String, collectURL: String) {
        self.projectKey = projectKey
        self.collectURL = collectURL
    }
}

/// Bir flush çağrısının sonucu. `error` nil değilse teslim hatasıdır.
@objc(FRLFlushResult)
public final class FRLFlushResult: NSObject {
    @objc public let sent: Int
    @objc public let accepted: Int
    @objc public let rejected: Int
    @objc public let batchID: String?
    @objc public let status: Int
    @objc public let retained: Int
    @objc public let error: NSError?

    init(_ result: FlushResult) {
        sent = result.sent
        accepted = result.accepted
        rejected = result.rejected
        batchID = result.batchID
        status = result.status
        retained = result.retained
        error = result.error.map { FRLFeralin.nsError(for: $0) }
    }

    @objc public var ok: Bool { error == nil }
}

/// Attribution çağrısı sonucu. `outcome` makinece okunur kısa dizgedir; `detail` varsa insan için açıklamadır.
/// Hiçbir `outcome` kesin atıf anlamına gelmez.
@objc(FRLAttributionResult)
public final class FRLAttributionResult: NSObject {
    @objc public let outcome: String
    @objc public let status: Int
    @objc public let detail: String?

    init(outcome: String, status: Int = 0, detail: String? = nil) {
        self.outcome = outcome
        self.status = status
        self.detail = detail
    }

    convenience init(_ submission: AdServicesSubmission) {
        switch submission {
        case .received(let receipt): self.init(outcome: receipt.status, status: 202, detail: receipt.exchangeStatus)
        case .skippedNoConsent: self.init(outcome: "skipped_no_consent")
        case .notConfigured: self.init(outcome: "not_configured")
        case .notSupported: self.init(outcome: "not_supported")
        case .tokenUnavailable(let message): self.init(outcome: "token_unavailable", detail: message)
        case .rejected(let status, let detail): self.init(outcome: "rejected", status: status, detail: detail)
        case .temporaryFailure(let status, let message): self.init(outcome: "temporary_failure", status: status, detail: message)
        }
    }

    convenience init(_ redemption: ContinuityRedemption) {
        switch redemption {
        case .confirmed(let value): self.init(outcome: value.status, status: 200, detail: value.meaning)
        case .invalidCode: self.init(outcome: "invalid_code", status: 404)
        case .selfRedeem: self.init(outcome: "self_redeem", status: 409)
        case .rateLimited: self.init(outcome: "rate_limited", status: 429)
        case .skippedNoConsent: self.init(outcome: "skipped_no_consent")
        case .notConfigured: self.init(outcome: "not_configured")
        case .notSupported: self.init(outcome: "not_supported")
        case .rejected(let status, let detail): self.init(outcome: "rejected", status: status, detail: detail)
        case .temporaryFailure(let status, let message): self.init(outcome: "temporary_failure", status: status, detail: message)
        }
    }
}

/// Swift `FeralinClient` üzerine Objective-C köprüsü. Bütün iş Swift aktöründe yapılır; burada yalnız tür çevrilir.
/// Tamamlama blokları ana iş parçacığında çağrılmaz; arayüz güncellemesi için ana kuyruğa geçilmelidir.
@objc(FRLFeralin)
public final class FRLFeralin: NSObject {
    public static let sdk = SDKIdentity(name: "feralin-objc", version: "0.1.0")
    /// `NSError.domain` değeri; kodlar `FRLErrorCode`.
    @objc public static let errorDomain = FRLFeralinErrorDomain

    private typealias Operation = @Sendable () async -> Void

    private let client: FeralinClient
    private let operations: AsyncStream<Operation>.Continuation

    @objc public init(configuration: FRLConfiguration) throws {
        var attribution: AttributionConfiguration?
        if let apiURL = configuration.apiURL, let projectID = configuration.projectID {
            attribution = AttributionConfiguration(apiURL: apiURL, projectID: projectID)
        }
        do {
            client = try FeralinClient(configuration: .init(
                projectKey: configuration.projectKey,
                collectURL: configuration.collectURL,
                consent: configuration.consent.swiftValue,
                flushInterval: configuration.flushInterval,
                batchSize: configuration.batchSize,
                queueLimit: configuration.queueLimit,
                timeout: configuration.timeout,
                attribution: attribution,
                sdk: Self.sdk
            ))
        } catch {
            throw Self.nsError(for: error)
        }
        operations = Self.startOperationQueue()
        super.init()
    }

    /// Yalnız Swift: hazır istemciyi sarar (özel taşıma ile uçtan uca test için).
    public init(client: FeralinClient) {
        self.client = client
        operations = Self.startOperationQueue()
        super.init()
    }

    deinit {
        operations.finish()
    }

    /// Her çağrı ayrı `Task` olsaydı aktöre giriş sırası garanti olmazdı: reklam izni geri çekme ile ardından gelen `track` ters
    /// işlenebilirdi. Çağrılar tek tüketicili kuyruktan sırayla geçer. Tüketici `self` tutmaz, kuyruktaki iş bitince sonlanır.
    private static func startOperationQueue() -> AsyncStream<Operation>.Continuation {
        var continuation: AsyncStream<Operation>.Continuation!
        let stream = AsyncStream<Operation>(bufferingPolicy: .unbounded) { continuation = $0 }
        Task {
            for await operation in stream {
                await operation()
            }
        }
        return continuation
    }

    // Tamamlama blokları ayrı görevde çağrılır: uygulama kodu bloklanırsa sıradaki çağrılar beklemez.

    @objc public func setConsent(_ consent: FRLConsent, completion: (() -> Void)?) {
        let value = consent.swiftValue
        operations.yield { [client] in
            await client.setConsent(value)
            Task { completion?() }
        }
    }

    /// `userID` nil ise varsayılan kimliği kaldırır. Yalnız uygulamanın opak kimliği verilir, e-posta verilmez.
    @objc public func identify(_ userID: String?, completion: ((NSError?) -> Void)?) {
        operations.yield { [client] in
            do {
                try await client.identify(userID)
                Task { completion?(nil) }
            } catch {
                let failure = Self.nsError(for: error)
                Task { completion?(failure) }
            }
        }
    }

    @objc public func reset(completion: (() -> Void)?) {
        operations.yield { [client] in
            await client.reset()
            Task { completion?() }
        }
    }

    /// Olayı kuyruğa ekler; ağ çağrısı yapmaz. İzin yoksa `eventID` ve `error` birlikte nil döner.
    /// `properties` değerleri NSString, NSNumber, NSNull, NSArray ya da NSDictionary olmalıdır.
    @objc public func track(_ eventName: String, properties: [String: Any]?, completion: ((String?, NSError?) -> Void)?) {
        let converted: [String: FeralinValue]?
        do {
            converted = try properties.map(Self.convert(properties:))
        } catch {
            completion?(nil, Self.nsError(for: error))
            return
        }
        operations.yield { [client] in
            do {
                let eventID = try await client.track(eventName, properties: converted)?.eventID
                Task { completion?(eventID, nil) }
            } catch {
                let failure = Self.nsError(for: error)
                Task { completion?(nil, failure) }
            }
        }
    }

    /// Teslim hatası sonucun `error` alanındadır; blok `NSError` yalnız kapalı istemcide alır.
    /// Önceki çağrılar bitince başlar ama ağı beklerken sıradakileri tutmaz: izin geri çekme yavaş gönderimin arkasında kalmaz.
    @objc public func flush(completion: @escaping (FRLFlushResult?, NSError?) -> Void) {
        operations.yield { [client] in
            Task {
                do {
                    let result = try await client.flush()
                    completion(FRLFlushResult(result), nil)
                } catch {
                    completion(nil, Self.nsError(for: error))
                }
            }
        }
    }

    /// Sıradakiler kapanışı bekler; kapanıştan sonra gelen `track` kapalı istemci hatası alır. Bekleme `close` süresiyle sınırlıdır.
    @objc public func close(completion: ((FRLFlushResult) -> Void)?) {
        operations.yield { [client] in
            let result = await client.close()
            Task { completion?(FRLFlushResult(result)) }
        }
    }

    // MARK: - Apple

    /// Geçerli ATT durumunu okur, izin penceresi açmaz.
    @objc public static func trackingAuthorizationStatus() -> FRLTrackingAuthorizationStatus {
        FRLTrackingAuthorizationStatus(FeralinApple.trackingAuthorizationStatus())
    }

    /// AdServices token'ını alır ve gönderir. Sonuç atıf kararı değildir.
    @objc public func submitAdServicesToken(completion: @escaping (FRLAttributionResult) -> Void) {
        operations.yield { [client] in
            Task {
                let result = await client.submitAdServicesToken()
                completion(FRLAttributionResult(result))
            }
        }
    }

    /// Kullanıcının kendisinin girdiği devam kodunu kullanır. Yalnız kullanıcı eylemiyle çağrılır; pano okunmaz.
    @objc public func redeemContinuityCode(_ code: String, completion: @escaping (FRLAttributionResult) -> Void) {
        operations.yield { [client] in
            Task {
                let result = await client.redeemContinuityCode(code)
                completion(FRLAttributionResult(result))
            }
        }
    }

    /// SKAdNetwork ve AdAttributionKit'e dönüşüm değeri bildirir. Blok iki çerçevenin sonucunu dizge olarak alır.
    @objc public func updateConversionValue(
        _ fine: Int,
        coarse: FRLCoarseConversionValue,
        lock: Bool,
        completion: @escaping (_ adAttributionKit: String, _ skAdNetwork: String) -> Void
    ) {
        let level = coarse.swiftValue
        operations.yield { [client] in
            Task {
                let result = await client.updateConversionValue(fine: fine, coarse: level, lock: lock)
                completion(Self.describe(result.adAttributionKit), Self.describe(result.skAdNetwork))
            }
        }
    }

    // MARK: - Çeviri

    static func describe(_ outcome: ConversionCallOutcome) -> String {
        switch outcome {
        case .called: return "called"
        case .notSupported: return "not_supported"
        case .notRequested: return "not_requested"
        case .skippedNoConsent: return "skipped_no_consent"
        case .failed: return "failed"
        }
    }

    static func nsError(for error: Error) -> NSError {
        let code: FRLErrorCode
        let message: String
        switch error {
        case let error as FeralinError:
            message = error.description
            switch error {
            case .configuration: code = .configuration
            case .invalidEvent: code = .invalidEvent
            case .clientClosed: code = .clientClosed
            }
        case let error as DeliveryError:
            message = error.description
            switch error {
            case .rejected: code = .rejected
            case .temporary: code = .temporary
            }
        default:
            message = "bilinmeyen hata"
            code = .temporary
        }
        return NSError(domain: FRLFeralinErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func convert(properties: [String: Any]) throws -> [String: FeralinValue] {
        try properties.mapValues(convert(value:))
    }

    /// Foundation nesnesini JSON değerine çevirir. NSNumber içindeki Bool ayrıca ayrılır; yoksa 0 ve 1 olarak giderdi.
    static func convert(value: Any) throws -> FeralinValue {
        switch value {
        case let text as String:
            return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number as CFNumber) { return .double(number.doubleValue) }
            return .int(number.int64Value)
        case is NSNull:
            return .null
        case let array as [Any]:
            return .array(try array.map(convert(value:)))
        case let dictionary as [String: Any]:
            return .object(try convert(properties: dictionary))
        default:
            throw FeralinError.invalidEvent("desteklenmeyen özellik türü: \(type(of: value))")
        }
    }
}

extension FRLTrackingAuthorizationStatus {
    init(_ status: TrackingAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .unavailable: self = .unavailable
        }
    }

    var swiftValue: TrackingAuthorizationStatus {
        switch self {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .unavailable: return .unavailable
        }
    }
}

extension FRLCoarseConversionValue {
    var swiftValue: CoarseConversionLevel {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}
#endif
