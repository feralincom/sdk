import Foundation
#if canImport(Feralin)
import Feralin
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Cordova ve Capacitor köprülerinin ortak iOS çekirdeği. Davranışın tamamı Feralin Swift SDK'sındadır (`FeralinClient`, sdks/swift);
/// burada yalnız JSON ↔ Swift dönüşümü, ilk açılış ve ertelenmiş bağlantının "bir kez" kaydı ve yaşam döngüsü bildirimleri vardır.
/// Bu dosya sdks/cordova ve sdks/capacitor içinde birebir aynıdır (testler karşılaştırır). Hiçbir yöntem hata fırlatmaz.
final class FeralinBridge: @unchecked Sendable {
    static let shared = FeralinBridge()

    /// Kurulum başına tek ilk açılış ve tek ertelenmiş bağlantı teslimi (Android çekirdeğiyle aynı sözleşme). Analitik izni geri
    /// çekilince ya da uygulama silinince UserDefaults ile birlikte silinir.
    static let firstOpenKey = "feralin.bridge.first_open_sent"
    static let deferredKey = "feralin.bridge.deferred_delivered"

    private let lock = NSLock()
    private var client: FeralinClient?
    private var linkHosts: [String] = FeralinLinks.defaultLinkHosts
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var current: FeralinClient? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }

    // MARK: - Başlatma

    /// `true`: SDK etkin. İkinci çağrı yok sayılır ve mevcut durumu döner.
    func initialize(_ config: [String: Any], sdkName: String, sdkVersion: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if client != nil { return true }
        guard let projectKey = config["projectKey"] as? String, let collectURL = config["collectUrl"] as? String else { return false }
        var attribution: AttributionConfiguration?
        if let raw = config["attribution"] as? [String: Any], let apiURL = raw["apiUrl"] as? String, let projectID = raw["projectId"] as? String {
            attribution = AttributionConfiguration(apiURL: apiURL, projectID: projectID)
        }
        var signingKey: SigningKey?
        if let raw = config["signingKey"] as? [String: Any] {
            guard let id = raw["id"] as? String, let secret = raw["secret"] as? String else { return false }
            signingKey = SigningKey(id: id, secret: secret)
        }
        let configuration = FeralinClient.Configuration(
            projectKey: projectKey,
            collectURL: collectURL,
            consent: Self.consent(from: config["consent"]) ?? Consent(),
            flushInterval: (Self.number(config["flushIntervalMs"]).map { $0 / 1000 }) ?? FeralinClient.defaultFlushInterval,
            batchSize: Self.integer(config["batchSize"]).map { min($0, FeralinClient.maxBatchSize) } ?? FeralinClient.defaultBatchSize,
            queueLimit: Self.integer(config["queueLimit"]) ?? FeralinClient.defaultQueueLimit,
            attribution: attribution,
            sdk: SDKIdentity(name: sdkName, version: sdkVersion),
            storageDirectory: FeralinClient.defaultStorageDirectory(),
            sessionTimeout: (Self.number(config["sessionTimeoutMs"]).map { $0 / 1000 }) ?? FeralinClient.defaultSessionTimeout,
            installCode: config["installCode"] as? String,
            signingKey: signingKey,
            childDirected: config["childDirected"] as? Bool ?? false,
            consentMaxAgeDays: Self.integer(config["consentMaxAgeDays"])
        )
        do {
            client = try FeralinClient(configuration: configuration)
        } catch {
            // Yapılandırma değeri loglanmaz; yalnız sonuç döner.
            return false
        }
        if let hosts = config["shortLinkHosts"] as? [String] { linkHosts = hosts }
        observeLifecycle()
        return true
    }

    private func observeLifecycle() {
        #if canImport(UIKit) && os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let client = self?.current else { return }
            Task { await client.didEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let client = self?.current else { return }
            Task { await client.willEnterForeground() }
        })
        #endif
    }

    // MARK: - İzin ve kimlik

    func setConsent(_ raw: Any?) async -> Bool {
        guard let client = current, let consent = Self.consent(from: raw) else { return false }
        await client.setConsent(consent)
        if !consent.analytics {
            defaults.removeObject(forKey: Self.firstOpenKey)
            defaults.removeObject(forKey: Self.deferredKey)
        }
        return true
    }

    func identify(_ userID: String) async -> Bool {
        guard let client = current else { return false }
        do {
            try await client.identify(userID)
            return true
        } catch {
            return false
        }
    }

    func reset() async -> Bool {
        guard let client = current else { return false }
        await client.reset()
        return true
    }

    // MARK: - Olaylar

    func track(_ name: String, properties: Any?) async -> String? {
        guard let client = current else { return nil }
        return try? await client.track(name, properties: Self.properties(from: properties))?.eventID
    }

    /// Android çekirdeğiyle aynı: `screen_view` olayı, ekran adı `screen_name` özelliğinde.
    func screen(_ name: String, properties: Any?) async -> String? {
        var merged = Self.properties(from: properties) ?? [:]
        merged["screen_name"] = .string(name)
        guard let client = current else { return nil }
        return try? await client.track("screen_view", properties: merged)?.eventID
    }

    func group(_ groupID: String, traits: Any?) async -> String? {
        guard let client = current else { return nil }
        return try? await client.group(groupID, traits: Self.properties(from: traits))?.eventID
    }

    func setUserProperties(_ properties: Any?) async -> String? {
        guard let client = current, let props = Self.properties(from: properties) else { return nil }
        return try? await client.setUserProperties(props)?.eventID
    }

    func setGlobalProperties(_ properties: Any?) async -> Int {
        guard let client = current, let props = Self.properties(from: properties) else { return 0 }
        return await client.setGlobalProperties(props)
    }

    func clearGlobalProperties() async -> Bool {
        guard let client = current else { return false }
        await client.clearGlobalProperties()
        return true
    }

    /// Swift çekirdeğinde ayrı gelir yöntemi yoktur: JS katmanı sözleşmeye göre kurduğu `feralin_purchase` özelliklerini verir
    /// (Web, Android ile aynı kurallar). `verified` ve türevleri JS katmanında düşürülür, toplayıcı da düşürür.
    func trackRevenue(properties: Any?) async -> String? {
        guard let client = current, let props = Self.properties(from: properties),
              props["transaction_id"] != nil, props["amount_minor"] != nil, props["currency"] != nil else { return nil }
        return try? await client.track("feralin_purchase", properties: props)?.eventID
    }

    func flush() async -> [String: Any] {
        guard let client = current, let result = try? await client.flush() else {
            return ["sent": 0, "accepted": 0, "rejected": 0, "status": 0, "batchId": NSNull()]
        }
        return ["sent": result.sent, "accepted": result.accepted, "rejected": result.rejected, "status": result.status,
                "batchId": result.batchID ?? NSNull()]
    }

    // MARK: - İlk açılış ve derin bağlantı

    /// İlk açılış olayı kurulum başına bir kez gönderilir; kurulum kaynağı iOS 17.4+ için `FeralinInstallSource.current()` değeridir.
    func trackFirstOpen(_ options: [String: Any]) async -> [String: Any] {
        guard let client = current else { return ["status": "not_initialized", "eventId": NSNull()] }
        if defaults.bool(forKey: Self.firstOpenKey) { return ["status": "already_sent", "eventId": NSNull()] }
        let store = await FeralinInstallSource.current()
        let clickID = options["clickId"] as? String
        let source = options["source"] as? String
        let advertisingID = options["advertisingId"] as? String
        guard let event = try? await client.trackFirstOpen(clickID: clickID, source: source, installStore: store, advertisingID: advertisingID) else {
            // Analitik izni yoksa olay üretilmez; izin gelince yeniden çağrılabilir.
            return ["status": "skipped", "eventId": NSNull()]
        }
        defaults.set(true, forKey: Self.firstOpenKey)
        return ["status": "sent", "eventId": event.eventID]
    }

    func installStore() async -> String? {
        await FeralinInstallSource.current()
    }

    func handleUniversalLink(_ raw: String) async -> [String: Any] {
        guard let url = URL(string: raw) else { return Self.linkOpen(destination: "/", linkCode: nil, hasClickID: false) }
        guard let client = current, let open = try? await client.handleUniversalLink(url) else {
            return Self.linkOpen(destination: FeralinLinks.destination(of: url), linkCode: nil, hasClickID: false)
        }
        return Self.linkOpen(destination: open.destination, linkCode: nil, hasClickID: open.hasClickID)
    }

    func handleShortLink(_ raw: String) async -> [String: Any] {
        guard let url = URL(string: raw) else { return Self.linkOpen(destination: "/", linkCode: nil, hasClickID: false) }
        guard let client = current else { return Self.linkOpen(destination: FeralinLinks.destination(of: url), linkCode: nil, hasClickID: false) }
        let open = await client.handleShortLink(url, linkHosts: linkHosts)
        return Self.linkOpen(destination: open.destination, linkCode: nil, hasClickID: open.hasClickID)
    }

    /// Ertelenmiş bağlantı bir kez teslim edilir (Android çekirdeğiyle aynı); ikinci çağrı `none` döner.
    func consumeDeferredDeepLink() async -> [String: Any] {
        guard let client = current else { return Self.deferred("not_initialized") }
        if defaults.bool(forKey: Self.deferredKey) { return Self.deferred("none") }
        switch await client.fetchDeferredDeepLink() {
        case .matched(let link):
            defaults.set(true, forKey: Self.deferredKey)
            guard let path = link.deepLinkPath else { return Self.deferred("none", linkCode: link.linkCode) }
            return Self.deferred("delivered", path: path, linkCode: link.linkCode)
        case .noMatch:
            defaults.set(true, forKey: Self.deferredKey)
            return Self.deferred("none")
        case .pending: return Self.deferred("pending")
        case .skippedNoConsent: return Self.deferred("consent_required")
        case .notConfigured: return Self.deferred("not_configured")
        case .rejected, .temporaryFailure: return Self.deferred("failed")
        }
    }

    // MARK: - Kaldırma ölçümü ve durum

    /// APNs belirtecinin onaltılı yazımı (JS'te `Data` yoktur). Biçim bozuksa olay üretilmez.
    func setPushToken(_ hex: String) async -> String? {
        guard let client = current, let data = Self.data(fromHex: hex) else { return nil }
        return try? await client.setPushToken(data)?.eventID
    }

    func installIdentifier() async -> String? {
        guard let client = current else { return nil }
        return await client.installIdentifier()
    }

    func status() async -> [String: Any] {
        guard let client = current else {
            return ["initialized": false, "queued": 0, "consent": NSNull(), "anonymousId": NSNull(), "sessionId": NSNull(), "userId": NSNull()]
        }
        let status = await client.status()
        let sessionID = await client.currentSessionID
        return [
            "initialized": !status.closed,
            "sdk": status.sdk,
            "version": status.version,
            "queued": status.queued,
            "consent": Self.consentMap(status.consent),
            "anonymousId": NSNull(),
            "sessionId": sessionID,
            "userId": status.userID ?? NSNull(),
        ]
    }

    // MARK: - Dönüşümler

    static func consent(from raw: Any?) -> Consent? {
        guard let map = raw as? [String: Any], let analytics = map["analytics"] as? Bool else { return nil }
        return Consent(
            analytics: analytics,
            advertising: map["advertising"] as? Bool ?? false,
            personalization: map["personalization"] as? Bool ?? false,
            sessionReplay: map["session_replay"] as? Bool ?? false
        )
    }

    static func consentMap(_ consent: Consent) -> [String: Any] {
        ["analytics": consent.analytics, "advertising": consent.advertising, "personalization": consent.personalization,
         "session_replay": consent.sessionReplay]
    }

    static func properties(from raw: Any?) -> [String: FeralinValue]? {
        guard let map = raw as? [String: Any] else { return nil }
        var out: [String: FeralinValue] = [:]
        for (key, raw) in map {
            if let converted = Self.value(from: raw, depth: 0) { out[key] = converted }
        }
        return out.isEmpty ? nil : out
    }

    /// JSON değerini `FeralinValue` türüne çevirir. NSNumber'ın Bool, tam sayı ya da kesirli olduğu Core Foundation türünden ayrılır.
    static func value(from raw: Any, depth: Int) -> FeralinValue? {
        switch raw {
        case is NSNull: return .null
        case let string as String: return .string(string)
        case let number as NSNumber:
            if isBoolean(number) { return .bool(number.boolValue) }
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            if !isFloatingPoint(number) || (double == double.rounded() && abs(double) <= 9_007_199_254_740_991) {
                return .int(number.int64Value)
            }
            return .double(double)
        case let list as [Any]:
            guard depth < 8 else { return nil }
            return .array(list.compactMap { Self.value(from: $0, depth: depth + 1) })
        case let map as [String: Any]:
            guard depth < 8 else { return nil }
            var out: [String: FeralinValue] = [:]
            for (key, child) in map {
                if let converted = Self.value(from: child, depth: depth + 1) { out[key] = converted }
            }
            return .object(out)
        default:
            return nil
        }
    }

    /// JSON çözücünün ürettiği mantıksal değer mi? iOS'ta Core Foundation türüyle, Linux'taki test koşusunda Objective-C tür koduyla ayrılır.
    static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        let code = String(cString: number.objCType)
        return code == "c" || code == "B"
        #endif
    }

    static func isFloatingPoint(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFNumberIsFloatType(number as CFNumber)
        #else
        let code = String(cString: number.objCType)
        return code == "d" || code == "f"
        #endif
    }

    static func number(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, !isBoolean(number), number.doubleValue > 0 else { return nil }
        return number.doubleValue
    }

    static func integer(_ raw: Any?) -> Int? {
        number(raw).map { Int($0) }
    }

    static func data(fromHex hex: String) -> Data? {
        let clean = hex.lowercased()
        guard (32...200).contains(clean.count), clean.count % 2 == 0, clean.allSatisfy({ $0.isHexDigit }) else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func linkOpen(destination: String, linkCode: String?, hasClickID: Bool) -> [String: Any] {
        ["destination": destination, "linkCode": linkCode ?? NSNull(), "hasClickId": hasClickID]
    }

    static func deferred(_ status: String, path: String? = nil, linkCode: String? = nil) -> [String: Any] {
        ["status": status, "path": path ?? NSNull(), "linkCode": linkCode ?? NSNull()]
    }
}
