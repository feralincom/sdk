import Foundation

// Hata (`fr_error`), oyun ve reklam geliri (`fr_ad_revenue`) olay sözleşmeleri (X4). Kurallar Android (`ErrorEvent.kt`,
// `GameAndAdEvents.kt`), Flutter, React Native ve Unity SDK'larıyla birebir aynıdır; kaynak `packages/schemas/utp/v1/event.schema.json`
// ve `game-events.md`. Sözleşme dışı girdide olay üretilmez ve `nil` döner. Doğrulama burada yapılır, kuyruk ve izin `track` içindedir.

/// Reklam biçimi (`ad_format`).
public enum AdFormat: String, Sendable {
    case banner
    case interstitial
    case rewarded
    case rewardedInterstitial = "rewarded_interstitial"
    case native
    case appOpen = "app_open"
    case other
}

/// Reklam ağının bildirdiği gelir kesinliği (`precision`); istemci beyanıdır, doğrulama sınıfı değildir.
public enum AdPrecision: String, Sendable {
    case estimated
    case publisherProvided = "publisher_provided"
    case precise
    case unknown
}

/// `trackAdRevenue` girdisi (X4): tek reklam gösteriminin geliri (ör. AdMob `paidEventHandler`, AppLovin MAX `onAdRevenuePaid`).
/// Satın alma gelirinden ve reklam harcamasından ayrı bir gelir sınıfıdır; istemci beyanıdır ve sunucuda ESTIMATED kalır.
public struct AdRevenueInput: Sendable {
    /// Reklam ağı, küçük harf ve alt çizgi: `admob`, `applovin_max`, `ironsource`, `unity_ads`.
    public var network: String
    public var adFormat: AdFormat
    /// Tek gösterim geliri, para biriminin milyonda biri: 0,0125 USD için 12500. Tam sayı, ondalık yok.
    public var revenueMicros: Int64
    /// ISO 4217, üç büyük harf.
    public var currency: String
    /// Reklam birimi kimliği (en fazla 128).
    public var adUnit: String?
    public var precision: AdPrecision
    /// Yerleşim adı (en fazla 64).
    public var placement: String?
    /// Ağın gösterim kimliği (en fazla 128); verilirse aynı gösterim ikinci kez sayılmaz.
    public var impressionID: String?
    /// Ek özellikler; `verified` ve türevleri düşürülür.
    public var properties: [String: FeralinValue]?

    public init(
        network: String,
        adFormat: AdFormat,
        revenueMicros: Int64,
        currency: String,
        adUnit: String? = nil,
        precision: AdPrecision = .unknown,
        placement: String? = nil,
        impressionID: String? = nil,
        properties: [String: FeralinValue]? = nil
    ) {
        self.network = network
        self.adFormat = adFormat
        self.revenueMicros = revenueMicros
        self.currency = currency
        self.adUnit = adUnit
        self.precision = precision
        self.placement = placement
        self.impressionID = impressionID
        self.properties = properties
    }
}

/// Olay gövdesi kurucuları; saf işlevlerdir ve testlerde doğrudan sınanır.
enum Signals {
    static let errorEvent = "fr_error"
    static let adRevenueEvent = "fr_ad_revenue"
    static let levelStart = "level_start"
    static let levelComplete = "level_complete"
    static let levelFail = "level_fail"
    static let economySource = "economy_source"
    static let economySink = "economy_sink"
    static let rewardedShown = "rewarded_ad_shown"
    static let rewardedComplete = "rewarded_ad_complete"
    static let iapOfferShown = "iap_offer_shown"
    static let iapInitiated = "iap_initiated"

    static let originUncaught = "uncaught_exception"
    static let originHandled = "handled"

    static let maxEconomyAmount: Int64 = 1_000_000_000_000
    static let maxDurationMillis: Int64 = 86_400_000
    static let maxNumber: Int64 = 9_007_199_254_740_991
    static let errorMaxMessage = 200
    private static let maxType = 64
    private static let maxFrame = 160
    private static let fingerprintFrames = 5
    private static let maxStackLines = 50
    private static let reservedKeys = ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"]

    // MARK: Doğrulama yardımcıları

    private static func validText(_ value: String?, _ max: Int) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value.unicodeScalars.count <= max
    }

    /// İsteğe bağlı metin: verilmediyse geçer; verildiyse sınırda olmalı.
    private static func putText(_ out: inout [String: FeralinValue], _ key: String, _ value: String?, _ max: Int) -> Bool {
        guard let value else { return true }
        guard validText(value, max) else { return false }
        out[key] = .string(value)
        return true
    }

    private static func putNumber(_ out: inout [String: FeralinValue], _ key: String, _ value: Int64?, _ min: Int64, _ max: Int64) -> Bool {
        guard let value else { return true }
        guard value >= min, value <= max else { return false }
        out[key] = .int(value)
        return true
    }

    // MARK: Oyun olayları

    static func level(_ levelID: String, attempt: Int64?, score: Int64?, durationMillis: Int64?, failReason: String?, withResult: Bool, withFailReason: Bool) -> [String: FeralinValue]? {
        guard validText(levelID, 64) else { return nil }
        var out: [String: FeralinValue] = ["level_id": .string(levelID)]
        guard putNumber(&out, "attempt", attempt, 1, maxNumber) else { return nil }
        if withResult {
            guard putNumber(&out, "score", score, 0, maxNumber) else { return nil }
            guard putNumber(&out, "duration_ms", durationMillis, 0, maxDurationMillis) else { return nil }
        }
        if withFailReason, !putText(&out, "fail_reason", failReason, 64) { return nil }
        return out
    }

    /// `economy_source` ve `economy_sink`: oyun içi para birimi adı ve 1..10^12 miktar (sanal para, gerçek gelir değil).
    static func economy(_ currencyName: String, amount: Int64, reason: String?, itemID: String?) -> [String: FeralinValue]? {
        guard validText(currencyName, 64), amount >= 1, amount <= maxEconomyAmount else { return nil }
        var out: [String: FeralinValue] = ["currency_name": .string(currencyName), "amount": .int(amount)]
        guard putText(&out, "reason", reason, 64), putText(&out, "item_id", itemID, 64) else { return nil }
        return out
    }

    static func rewardedShown(_ placement: String, network: String?) -> [String: FeralinValue]? {
        guard validText(placement, 64) else { return nil }
        var out: [String: FeralinValue] = ["placement": .string(placement)]
        guard putText(&out, "network", network, 64) else { return nil }
        return out
    }

    static func rewardedComplete(_ placement: String, network: String?, rewardAmount: Int64?, rewardCurrency: String?) -> [String: FeralinValue]? {
        guard var out = rewardedShown(placement, network: network) else { return nil }
        guard putNumber(&out, "reward_amount", rewardAmount, 0, maxNumber), putText(&out, "reward_currency", rewardCurrency, 64) else { return nil }
        return out
    }

    static func iapOfferShown(_ productID: String, placement: String?) -> [String: FeralinValue]? {
        guard validText(productID, 128) else { return nil }
        var out: [String: FeralinValue] = ["product_id": .string(productID)]
        guard putText(&out, "placement", placement, 64) else { return nil }
        return out
    }

    static func iapInitiated(_ productID: String, placement: String?, transactionID: String?) -> [String: FeralinValue]? {
        guard var out = iapOfferShown(productID, placement: placement) else { return nil }
        guard putText(&out, "transaction_id", transactionID, 128) else { return nil }
        return out
    }

    // MARK: Reklam geliri

    static func adRevenue(_ input: AdRevenueInput) -> [String: FeralinValue]? {
        guard matches(input.network, "^[a-z][a-z0-9_]{0,63}$"), matches(input.currency, "^[A-Z]{3}$") else { return nil }
        guard input.revenueMicros >= 0, input.revenueMicros <= maxNumber else { return nil }
        guard input.adUnit == nil || validText(input.adUnit, 128),
              input.placement == nil || validText(input.placement, 64),
              input.impressionID == nil || validText(input.impressionID, 128) else { return nil }
        var out = input.properties ?? [:]
        for key in reservedKeys { out.removeValue(forKey: key) }
        out["network"] = .string(input.network)
        out["ad_format"] = .string(input.adFormat.rawValue)
        out["revenue_micros"] = .int(input.revenueMicros)
        out["currency"] = .string(input.currency)
        out["precision"] = .string(input.precision.rawValue)
        if let adUnit = input.adUnit { out["ad_unit"] = .string(adUnit) }
        if let placement = input.placement { out["placement"] = .string(placement) }
        if let impressionID = input.impressionID { out["impression_id"] = .string(impressionID) }
        return out
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Hata

    /// Mesajdan e-posta, URL, UUID, uzun sayı ve belirteçleri çıkarır; 200 karaktere kırpar (toplayıcı aynı temizliği tekrarlar).
    static func scrub(_ message: String) -> String {
        var text = message
        text = replace(text, #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>]+"#, "[url]")
        text = replace(text, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]")
        text = replace(text, #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "[id]")
        text = replace(text, #"\b[A-Za-z0-9_\-+/=]{24,}\b"#, "[token]") { $0.contains(where: \.isNumber) }
        text = replace(text, #"\+?\d[\d\s\-().]{5,}\d"#, "[num]") { $0.filter(\.isNumber).count >= 7 }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(text.prefix(errorMaxMessage))
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String, when: ((String) -> Bool)? = nil) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let piece = source.substring(with: match.range)
            out += (when?(piece) ?? true) ? template : piece
            cursor = match.range.location + match.range.length
        }
        out += source.substring(from: cursor)
        return out
    }

    /// FNV-1a 64 bit (Web ve Flutter SDK'larıyla aynı özet): 16 küçük harf onaltılı. Karakter birimi olarak UTF-16 kullanılır.
    static func fnv1a64(_ text: String) -> String {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for unit in text.utf16 {
            value = (value ^ UInt64(unit)) &* 0x0000_0100_0000_01B3
        }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    private static let systemModulePrefixes = ["libsystem", "libswift", "libdispatch", "libobjc", "libc++", "dyld"]
    private static let systemModules: Set<String> = [
        "Foundation", "CoreFoundation", "UIKit", "UIKitCore", "AppKit", "SwiftUI", "QuartzCore", "CFNetwork", "GraphicsServices", "Combine",
    ]

    /// `Thread.callStackSymbols` satırlarını normalize çerçevelere çevirir (`sembol@modül`). Adres, kaydırma ve yol atılır; sistem
    /// modülleri, uygulama çerçevesi varsa parmak izine girmez. Bu çerçeveler yalnız parmak izi içindir; sembolleştirme `AppleFrames`
    /// konumları ve yüklenen dSYM ile sunucuda yapılır.
    static func normalizeFrames(_ symbols: [String]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.*?)(?:\s+\+\s+\d+)?\s*$"#) else { return [] }
        var all: [(module: String, frame: String)] = []
        for line in symbols.prefix(maxStackLines) {
            let source = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: source.length)), match.numberOfRanges == 3 else { continue }
            let module = source.substring(with: match.range(at: 1))
            var symbol = source.substring(with: match.range(at: 2))
            if symbol.isEmpty { symbol = "<anonymous>" }
            all.append((module, "\(symbol.prefix(60))@\(module)"))
        }
        let app = all.filter { entry in
            !systemModules.contains(entry.module) && !systemModulePrefixes.contains(where: { entry.module.hasPrefix($0) })
        }
        return (app.isEmpty ? all : app).map(\.frame)
    }

    /// Hata gövdesi: sözleşme alanlarının tamamı. Ham yığın izi, ham adres, yol ve kullanıcı verisi GİTMEZ. `frames` dSYM ile sunucuda
    /// çözülecek en çok beş uygulama çerçevesidir (`AppleFrames`: modül + UUID + göreli adres); boşsa alan yazılmaz.
    static func errorProperties(typeName: String, message: String, symbols: [String], origin: String, fatal: Bool, appVersion: String?, frames appleFrames: [FeralinValue] = []) -> [String: FeralinValue] {
        let type = String((typeName.isEmpty ? "Error" : typeName).prefix(maxType))
        let scrubbed = scrub(message)
        let frames = normalizeFrames(symbols)
        let basis: String
        if frames.isEmpty {
            basis = replace(scrubbed, #"\d+"#, "#")
        } else {
            basis = frames.prefix(fingerprintFrames).joined(separator: "|")
        }
        var out: [String: FeralinValue] = [
            "error_type": .string(type),
            "fingerprint": .string(fnv1a64("\(type)|\(basis)")),
            "frame_count": .int(Int64(min(frames.count, 1000))),
            "handled": .bool(origin == originHandled),
            "fatal": .bool(fatal),
            "origin": .string(origin),
        ]
        if !scrubbed.isEmpty { out["message"] = .string(scrubbed) }
        if let top = frames.first { out["top_frame"] = .string(String(top.prefix(maxFrame))) }
        if let appVersion, !appVersion.isEmpty, appVersion.count <= 32 { out["app_version"] = .string(appVersion) }
        if !appleFrames.isEmpty { out["frames"] = .array(Array(appleFrames.prefix(AppleFrames.maxFrames))) }
        return out
    }
}

/// Hata fırtınası sınırı: istemci başına en çok `maxEvents` olay, aynı parmak izi için en çok `maxPerFingerprint`. Örnekleme `sampleRate`
/// ile (0...1); rastgele kaynak test için verilebilir.
struct ErrorLimiter: Sendable {
    var sampleRate: Double = 1
    var maxEvents = 20
    var maxPerFingerprint = 3
    var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
    private var total = 0
    private var perFingerprint: [String: Int] = [:]

    mutating func allow(_ fingerprint: String) -> Bool {
        if total >= maxEvents { return false }
        if sampleRate < 1, random() >= sampleRate { return false }
        let seen = perFingerprint[fingerprint] ?? 0
        if seen >= maxPerFingerprint { return false }
        perFingerprint[fingerprint] = seen + 1
        total += 1
        return true
    }
}

// MARK: - Genel yüzey

extension FeralinClient {
    private func signal(_ name: String, _ properties: [String: FeralinValue]?) throws -> TrackedEvent? {
        guard let properties else { return nil }
        return try track(name, properties: properties)
    }

    /// Bölüm başladı (`level_start`). `levelID` 1-64 karakter. Sözleşme dışı girdide `nil`; istemci kapalıysa `FeralinError.clientClosed`.
    @discardableResult
    public func trackLevelStart(_ levelID: String, attempt: Int64? = nil) throws -> TrackedEvent? {
        try signal(Signals.levelStart, Signals.level(levelID, attempt: attempt, score: nil, durationMillis: nil, failReason: nil, withResult: false, withFailReason: false))
    }

    /// Bölüm tamamlandı (`level_complete`). Süre milisaniyedir (0-86 400 000).
    @discardableResult
    public func trackLevelComplete(_ levelID: String, attempt: Int64? = nil, score: Int64? = nil, durationMillis: Int64? = nil) throws -> TrackedEvent? {
        try signal(Signals.levelComplete, Signals.level(levelID, attempt: attempt, score: score, durationMillis: durationMillis, failReason: nil, withResult: true, withFailReason: false))
    }

    /// Bölüm başarısız (`level_fail`).
    @discardableResult
    public func trackLevelFail(_ levelID: String, attempt: Int64? = nil, score: Int64? = nil, durationMillis: Int64? = nil, failReason: String? = nil) throws -> TrackedEvent? {
        try signal(Signals.levelFail, Signals.level(levelID, attempt: attempt, score: score, durationMillis: durationMillis, failReason: failReason, withResult: true, withFailReason: true))
    }

    /// Oyun içi para birimi kazanıldı (`economy_source`). Sanal para birimidir; gerçek gelir değildir. Miktar 1...10^12.
    @discardableResult
    public func trackEconomySource(_ currencyName: String, amount: Int64, reason: String? = nil, itemID: String? = nil) throws -> TrackedEvent? {
        try signal(Signals.economySource, Signals.economy(currencyName, amount: amount, reason: reason, itemID: itemID))
    }

    /// Oyun içi para birimi harcandı (`economy_sink`).
    @discardableResult
    public func trackEconomySink(_ currencyName: String, amount: Int64, reason: String? = nil, itemID: String? = nil) throws -> TrackedEvent? {
        try signal(Signals.economySink, Signals.economy(currencyName, amount: amount, reason: reason, itemID: itemID))
    }

    /// Ödüllü reklam gösterildi (`rewarded_ad_shown`). Gelir taşımaz; reklam geliri `trackAdRevenue` ile bildirilir.
    @discardableResult
    public func trackRewardedAdShown(_ placement: String, network: String? = nil) throws -> TrackedEvent? {
        try signal(Signals.rewardedShown, Signals.rewardedShown(placement, network: network))
    }

    /// Ödüllü reklam tamamlandı (`rewarded_ad_complete`).
    @discardableResult
    public func trackRewardedAdComplete(_ placement: String, network: String? = nil, rewardAmount: Int64? = nil, rewardCurrency: String? = nil) throws -> TrackedEvent? {
        try signal(Signals.rewardedComplete, Signals.rewardedComplete(placement, network: network, rewardAmount: rewardAmount, rewardCurrency: rewardCurrency))
    }

    /// Uygulama içi satın alma teklifi gösterildi (`iap_offer_shown`). Gelir değildir.
    @discardableResult
    public func trackIapOfferShown(_ productID: String, placement: String? = nil) throws -> TrackedEvent? {
        try signal(Signals.iapOfferShown, Signals.iapOfferShown(productID, placement: placement))
    }

    /// Satın alma başlatıldı (`iap_initiated`).
    @discardableResult
    public func trackIapInitiated(_ productID: String, placement: String? = nil, transactionID: String? = nil) throws -> TrackedEvent? {
        try signal(Signals.iapInitiated, Signals.iapInitiated(productID, placement: placement, transactionID: transactionID))
    }

    /// Reklam gösterimi geliri (`fr_ad_revenue`). Satın alma gelirinden ve reklam harcamasından ayrı bir gelir sınıfıdır; istemci beyanıdır,
    /// sunucuda ESTIMATED kalır, reklam ağı mutabakatı BLOCKED_EXTERNAL. Sözleşme dışı girdide `nil`.
    @discardableResult
    public func trackAdRevenue(_ input: AdRevenueInput) throws -> TrackedEvent? {
        try signal(Signals.adRevenueEvent, Signals.adRevenue(input))
    }

    /// Hız sınırı ve örnekleme ayarı: istemci başına en çok 20 hata olayı, aynı parmak izi için 3. `sampleRate` 0...1.
    public func configureErrorCapture(sampleRate: Double) {
        errorLimiter.sampleRate = min(1, max(0, sampleRate))
    }

    /// Yakalanan bir hatayı `fr_error` olarak bildirir. Yığın izi gitmez: hata türü adı, temizlenmiş mesaj ve normalize çerçeve özeti olan
    /// parmak izi gider. Sınır dolduysa, izin yoksa ya da girdi geçersizse `nil`. `symbols` verilmezse çağrı anındaki yığın kullanılır.
    /// `returnAddresses` dSYM sembolleştirmesi için en çok beş uygulama çerçevesinin konumuna (modül + UUID + göreli adres) çevrilir.
    @discardableResult
    public func captureError(_ error: Error, appVersion: String? = nil, symbols: [String] = Thread.callStackSymbols, returnAddresses: [NSNumber] = Thread.callStackReturnAddresses) throws -> TrackedEvent? {
        try report(typeName: String(describing: type(of: error)), message: String(describing: error), symbols: symbols, origin: Signals.originHandled, fatal: false, appVersion: appVersion, returnAddresses: returnAddresses)
    }

    func report(typeName: String, message: String, symbols: [String], origin: String, fatal: Bool, appVersion: String?, returnAddresses: [NSNumber] = []) throws -> TrackedEvent? {
        let props = Signals.errorProperties(typeName: typeName, message: message, symbols: symbols, origin: origin, fatal: fatal, appVersion: appVersion, frames: AppleFrames.capture(returnAddresses))
        guard case .string(let fingerprint)? = props["fingerprint"], errorLimiter.allow(fingerprint) else { return nil }
        return try track(Signals.errorEvent, properties: props)
    }
}

// MARK: - Yakalanmamış NSException

/// `NSSetUncaughtExceptionHandler` tek C işlevi alır ve bağlam taşımaz; bu yüzden tek bir etkin istemci tutulur. Yalnız Objective-C
/// `NSException` yakalanır: Swift çalışma zamanı hatası (zorla açma, dizi taşması) ve sinyal çökmeleri yakalanmaz.
/// `NSException` yalnız Objective-C çalışma zamanında vardır (Apple platformları); Linux'ta bu tür yoktur ve kanca kurulmaz.
#if canImport(ObjectiveC)
enum UncaughtExceptionHook {
    /// Durum kilitle korunur; Swift 5.9 araç zinciriyle uyumlu kalmak için `nonisolated(unsafe)` yerine kilitli sınıf kullanılır.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var client: FeralinClient?
        var appVersion: String?
        var previous: NSUncaughtExceptionHandler?
    }

    private static let state = State()

    static func install(client: FeralinClient, appVersion: String?) {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard state.client == nil else { return }
        state.client = client
        state.appVersion = appVersion
        state.previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            UncaughtExceptionHook.handle(exception)
        }
    }

    private static func handle(_ exception: NSException) {
        state.lock.lock()
        let target = state.client
        let version = state.appVersion
        let chained = state.previous
        state.lock.unlock()
        if let target {
            // Süreç kapanmak üzere: kuyruğa yazmayı en çok bir saniye beklenir, sonra önceki işleyici çalışır.
            let done = DispatchSemaphore(value: 0)
            let symbols = exception.callStackSymbols
            let addresses = exception.callStackReturnAddresses
            let name = exception.name.rawValue
            let reason = exception.reason ?? ""
            Task {
                _ = try? await target.report(typeName: name, message: reason, symbols: symbols, origin: Signals.originUncaught, fatal: true, appVersion: version, returnAddresses: addresses)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 1)
        }
        chained?(exception)
    }
}
#endif

extension FeralinClient {
    /// Yakalanmamış Objective-C `NSException`'ları `fr_error` (ölümcül) olarak bildirir; mevcut işleyici korunur ve çağrılmaya devam eder.
    /// Swift çalışma zamanı hataları ve sinyal çökmeleri yakalanmaz. Çerçeveler yüklenen dSYM ile sunucuda çözülür. Süreçte bir kez, ilk istemci için etkindir.
    /// Objective-C çalışma zamanı olmayan platformlarda (Linux) etkisizdir.
    public func captureUncaughtExceptions(appVersion: String? = nil) {
        #if canImport(ObjectiveC)
        UncaughtExceptionHook.install(client: self, appVersion: appVersion)
        #endif
    }
}
