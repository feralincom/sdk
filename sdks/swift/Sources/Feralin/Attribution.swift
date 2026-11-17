import Foundation

/// Attribution uçlarının adresi. Proje anahtarı `Authorization: Bearer` ile taşınır; gizli API anahtarı kullanılmaz.
public struct AttributionConfiguration: Equatable, Sendable {
    public var apiURL: String
    public var projectID: String

    public init(apiURL: String, projectID: String) {
        self.apiURL = apiURL
        self.projectID = projectID
    }
}

/// `POST /v1/projects/{id}/attribution/apple-adservices/tokens` yanıtı. Sunucu bugün Apple'a sormaz:
/// `exchangeStatus` `BLOCKED_EXTERNAL` döner ve hiçbir attribution kararı üretilmez.
public struct AdServicesReceipt: Equatable, Sendable, Decodable {
    public let id: String?
    public let status: String
    public let exchangeStatus: String
    public let receivedAt: String
    public let expiresAt: String
    public let duplicate: Bool

    enum CodingKeys: String, CodingKey {
        case id, status, exchange, duplicate
        case receivedAt = "received_at"
        case expiresAt = "expires_at"
    }

    enum ExchangeKeys: String, CodingKey { case status }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        let exchange = try container.nestedContainer(keyedBy: ExchangeKeys.self, forKey: .exchange)
        exchangeStatus = try exchange.decode(String.self, forKey: .status)
        receivedAt = try container.decode(String.self, forKey: .receivedAt)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        duplicate = try container.decode(Bool.self, forKey: .duplicate)
    }
}

public enum AdServicesSubmission: Equatable, Sendable {
    case received(AdServicesReceipt)
    /// Analitik ve reklam izni birlikte yoksa token alınmaz ve gönderilmez.
    case skippedNoConsent
    case notConfigured
    case notSupported
    case tokenUnavailable(String)
    case rejected(status: Int, detail: String)
    case temporaryFailure(status: Int, message: String)
}

/// `bindInstall()` sonucu (ADR-0007). `installID` müşterinin kendi sunucusuna iletilir; sunucu gizli API anahtarıyla
/// `POST /v1/projects/{id}/attribution/account-links` (`surface=app`, `subject_id=installID`) çağırır. SDK hesap kimliği yazmaz:
/// proje anahtarı uygulamadan okunabildiğinden hesap bağı yalnız müşteri sunucusundan kurulur.
public struct InstallBinding: Equatable, Sendable {
    /// Reklam ölçümü izni yoksa `nil`; kimlik yalnız izinle üretilir ve diske yazılır.
    public let installID: String?
    /// AdServices token'ının gönderim sonucu. `notSupported` (iOS 14.3 öncesi, macOS gibi) ya da `tokenUnavailable` olsa da
    /// `installID` hesap bağı için geçerlidir; token yoksa yalnız Apple kanıtı eksik kalır.
    public let adServices: AdServicesSubmission

    public init(installID: String?, adServices: AdServicesSubmission) {
        self.installID = installID
        self.adServices = adServices
    }
}

/// `redeem` yanıtı: eşleşen ilk açılıştır, Apple indirme sayısı ya da reklam kanıtı değildir.
public struct UserConfirmation: Equatable, Sendable, Decodable {
    public let status: String
    public let decision: String
    public let meaning: String
    public let provenanceClass: String
    public let campaign: String?

    enum CodingKeys: String, CodingKey {
        case status, decision, meaning, campaign
        case provenanceClass = "provenance_class"
    }
}

public enum ContinuityRedemption: Equatable, Sendable {
    case confirmed(UserConfirmation)
    /// Kod yok, süresi dolmuş ya da kullanılmış: sunucu bunları ayırt ettirmez.
    case invalidCode
    /// Kod aynı kimlikten kullanılamaz.
    case selfRedeem
    case rateLimited
    case skippedNoConsent
    case notConfigured
    /// Sözleşmede bu Apple platformu için `platform` değeri yok (macOS, tvOS, watchOS).
    case notSupported
    case rejected(status: Int, detail: String)
    case temporaryFailure(status: Int, message: String)
}
