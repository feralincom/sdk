import Foundation

/// İzin anlık görüntüsü. `analytics` false ise hiçbir olay üretilmez; `advertising` false ise `fr_click` çıkarılır.
public struct Consent: Equatable, Sendable {
    public var analytics: Bool
    public var advertising: Bool
    public var personalization: Bool
    public var sessionReplay: Bool

    public init(analytics: Bool = false, advertising: Bool = false, personalization: Bool = false, sessionReplay: Bool = false) {
        self.analytics = analytics
        self.advertising = advertising
        self.personalization = personalization
        self.sessionReplay = sessionReplay
    }

    /// ATT sonucunu reklam iznine yansıtır: ATT'nin bulunduğu platformda yalnız `authorized` reklam iznini korur, `notDetermined`
    /// da kapalıdır. Uygulamanın verdiği hayır kararını evete çevirmez. ATT olmayan platformda (`unavailable`) değer değişmez.
    /// `FeralinClient` bunu her reklam kullanımında kendisi uygular.
    public func constrained(by status: TrackingAuthorizationStatus) -> Consent {
        var copy = self
        switch status {
        case .authorized, .unavailable: break
        case .notDetermined, .restricted, .denied: copy.advertising = false
        }
        return copy
    }

    var wire: FeralinValue {
        .object([
            "analytics": .bool(analytics),
            "advertising": .bool(advertising),
            "personalization": .bool(personalization),
            "session_replay": .bool(sessionReplay),
        ])
    }
}

/// Olay özelliği değeri: yalnız JSON'a birebir dönüşen türler kabul edilir.
public enum FeralinValue: Equatable, Sendable, Encodable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case array([FeralinValue])
    case object([String: FeralinValue])
    case null

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: FeralinValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, FeralinValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct Screen: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct AppInfo: Equatable, Sendable {
    public var version: String?
    public var build: String?
    public init(version: String? = nil, build: String? = nil) {
        self.version = version
        self.build = build
    }
}

/// Şemadaki `context` nesnesi; yalnız dolu alanlar gönderilir. SDK cihazdan kendiliğinden context toplamaz.
public struct Context: Equatable, Sendable {
    public var pageURL: String?
    public var pageTitle: String?
    public var referrer: String?
    public var locale: String?
    public var timezone: String?
    public var screen: Screen?
    public var app: AppInfo?

    public init(pageURL: String? = nil, pageTitle: String? = nil, referrer: String? = nil, locale: String? = nil, timezone: String? = nil, screen: Screen? = nil, app: AppInfo? = nil) {
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.referrer = referrer
        self.locale = locale
        self.timezone = timezone
        self.screen = screen
        self.app = app
    }

    var wire: [String: FeralinValue] {
        var out: [String: FeralinValue] = [:]
        if let pageURL, !pageURL.isEmpty { out["page_url"] = .string(pageURL) }
        if let pageTitle, !pageTitle.isEmpty { out["page_title"] = .string(pageTitle) }
        if let referrer, !referrer.isEmpty { out["referrer"] = .string(referrer) }
        if let locale, !locale.isEmpty { out["locale"] = .string(locale) }
        if let timezone, !timezone.isEmpty { out["timezone"] = .string(timezone) }
        if let screen { out["screen"] = .object(["width": .int(Int64(screen.width)), "height": .int(Int64(screen.height))]) }
        if let app {
            var info: [String: FeralinValue] = [:]
            if let version = app.version, !version.isEmpty { info["version"] = .string(version) }
            if let build = app.build, !build.isEmpty { info["build"] = .string(build) }
            if !info.isEmpty { out["app"] = .object(info) }
        }
        return out
    }
}

/// `track` sonucu: kuyruğa giren olayın istemci tarafı özeti.
public struct TrackedEvent: Equatable, Sendable {
    public let eventID: String
    public let eventName: String
    public let occurredAt: String
    public let userID: String?
    public let anonymousID: String?
    public let sessionID: String?
    public let properties: [String: FeralinValue]?
    public let consent: Consent
}

/// Bir `flush()` çağrısının toplu sonucu.
public struct FlushResult: Equatable, Sendable {
    public var sent = 0
    public var accepted = 0
    public var rejected = 0
    public var batchID: String?
    public var status = 0
    public var retained = 0
    public var error: DeliveryError?

    public init() {}

    public var ok: Bool { error == nil }
}

/// Anlık durum; proje anahtarı bilerek yoktur.
public struct ClientStatus: Equatable, Sendable {
    public let sdk: String
    public let version: String
    public let queued: Int
    public let dropped: Int
    public let consent: Consent
    public let userID: String?
    public let closed: Bool
    public let backoff: TimeInterval
    public let endpoint: String
}

enum Wire {
    static let maxEventNameLength = 100
    static let maxProperties = 100
    static let maxIdentifierLength = 128
    static let attributionClickProperty = "fr_click"
    /// İsteğe bağlı reklam kimliği (IDFA); yalnız açık reklam ölçümü izniyle gönderilir.
    static let advertisingIDProperty = "advertising_id"

    /// Önceki kurulum kimliği biçimi (toplayıcıdaki denetimle aynı).
    static func isValidInstallReference(_ value: String) -> Bool {
        (8...128).contains(value.count) && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains($0) }
    }
    static let installCodeProperty = "fr_install_code"

    /// Web, Node, .NET, Android ve Python SDK'larıyla aynı anahtar: sıralı tüm event_id'lerin FNV-1a 64 özeti ve sayı.
    static func idempotencyKey(for eventIDs: [String]) -> String {
        let ordered = eventIDs.sorted()
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in ordered.joined(separator: ",").utf8 {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex + "-\(ordered.count)"
    }

    static func validateEventName(_ name: String) throws -> String {
        let bytes = Array(name.utf8)
        let valid = !bytes.isEmpty && bytes.count <= maxEventNameLength && isLower(bytes[0])
            && bytes.allSatisfy { isLower($0) || isDigit($0) || $0 == underscore }
        guard valid else {
            throw FeralinError.invalidEvent("event_name snake_case olmalı (^[a-z][a-z0-9_]*$, en fazla 100 karakter)")
        }
        return name
    }

    static func validateProperties(_ properties: [String: FeralinValue]?) throws -> [String: FeralinValue]? {
        guard let properties else { return nil }
        guard properties.count <= maxProperties else {
            throw FeralinError.invalidEvent("properties en fazla 100 anahtar içerebilir (\(properties.count) verildi)")
        }
        for key in properties.keys {
            let bytes = Array(key.utf8)
            let valid = !bytes.isEmpty && bytes.count <= 64 && isLetter(bytes[0])
                && bytes.allSatisfy { isLetter($0) || isDigit($0) || $0 == underscore }
            guard valid else {
                throw FeralinError.invalidEvent("properties anahtarı ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ desenine uymalı")
            }
        }
        return properties.isEmpty ? nil : properties
    }

    static func validateIdentifier(_ value: String?, field: String) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.unicodeScalars.count <= maxIdentifierLength else {
            throw FeralinError.invalidEvent("\(field) en fazla 128 karakter olmalı")
        }
        return value
    }

    /// UTC RFC3339, milisaniye hassasiyeti; alt milisaniye kesilir.
    static func formatTime(_ moment: Date) -> String {
        let millis = epochMillis(moment)
        let seconds = Int64((Double(millis) / 1000).rounded(.down))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return pad(parts.year ?? 0, 4) + "-" + pad(parts.month ?? 0, 2) + "-" + pad(parts.day ?? 0, 2) + "T"
            + pad(parts.hour ?? 0, 2) + ":" + pad(parts.minute ?? 0, 2) + ":" + pad(parts.second ?? 0, 2) + "."
            + pad(Int(millis - seconds * 1000), 3) + "Z"
    }

    /// Double yuvarlaması bir milisaniye geriye düşürmesin diye önce mikrosaniyeye yuvarlanır.
    static func epochMillis(_ moment: Date) -> Int64 {
        let micros = (moment.timeIntervalSince1970 * 1_000_000).rounded()
        return Int64((micros / 1000).rounded(.down))
    }

    private static let underscore = UInt8(ascii: "_")
    private static func isLower(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") }
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
    private static func isLetter(_ byte: UInt8) -> Bool { isLower(byte) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) }
    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
