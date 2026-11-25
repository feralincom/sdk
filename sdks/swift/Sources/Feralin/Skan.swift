import Foundation

// SKAdNetwork 4 / AdAttributionKit dönüşüm değeri modülü (F3, dalga 11). Kiracının şeması sunucudan alınır
// (`GET {api}/v1/projects/{id}/skan/conversion-schema/sdk`, proje anahtarıyla) ve izlenen olaylar Apple çağrısına çevrilir.
// Sözleşme sunucudaki `skan-schema.ts` ile aynıdır: ince değer 0-63, kaba değer low < medium < high, üç pencere (0-2, 3-7, 8-35. gün;
// ince değer yalnız ilk pencerede), seçim `highest_value` (değer hiç düşmez), `lock_window` pencerenin son güncellemesidir.
// Bu dosyadaki karar mantığı platformdan bağımsızdır ve Linux'ta test edilir; Apple çağrısı `FeralinApple.updateConversionValue` içindedir.

/// SKAN modülü ayarı. Verilmezse (varsayılan) modül kapalıdır. SKAN ve AdAttributionKit ATT izni istemez; modül uygulamanın bu
/// ayarıyla açılır ve izin durumundan bağımsız çalışır. `childDirected` açıksa modül çalışmaz. Şema için `attribution` yapılandırması gerekir.
public struct SkanConfiguration: Equatable, Sendable {
    /// Çağrılacak çerçeveler (Apple: ağınız ikisiyle de bütünleşikse ikisi de çağrılır).
    public var frameworks: ConversionFrameworks
    /// Şema en çok bu aralıkla yeniden alınır (varsayılan 24 saat); arada diskteki kopya kullanılır.
    public var schemaRefreshInterval: TimeInterval

    public init(frameworks: ConversionFrameworks = .both, schemaRefreshInterval: TimeInterval = 24 * 3600) {
        self.frameworks = frameworks
        self.schemaRefreshInterval = schemaRefreshInterval
    }
}

/// Şemadaki tek kural: olay görülünce üretilen değer.
public struct SkanRule: Equatable, Sendable, Codable {
    public let eventName: String
    /// Yalnız ilk pencerede kullanılır; nil ise bu olay ince değer üretmez.
    public let fineValue: Int?
    public let coarseValue: CoarseConversionLevel
    public let lockWindow: Bool

    public init(eventName: String, fineValue: Int?, coarseValue: CoarseConversionLevel, lockWindow: Bool = false) {
        self.eventName = eventName
        self.fineValue = fineValue
        self.coarseValue = coarseValue
        self.lockWindow = lockWindow
    }

    enum CodingKeys: String, CodingKey {
        case eventName = "event_name"
        case fineValue = "fine_value"
        case coarseValue = "coarse_value"
        case lockWindow = "lock_window"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventName = try container.decode(String.self, forKey: .eventName)
        fineValue = try container.decodeIfPresent(Int.self, forKey: .fineValue)
        let coarse = try container.decode(String.self, forKey: .coarseValue)
        guard let level = CoarseConversionLevel(rawValue: coarse) else {
            throw DecodingError.dataCorruptedError(forKey: .coarseValue, in: container, debugDescription: "kaba değer low, medium ya da high olmalı")
        }
        coarseValue = level
        lockWindow = try container.decodeIfPresent(Bool.self, forKey: .lockWindow) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventName, forKey: .eventName)
        try container.encode(fineValue, forKey: .fineValue)
        try container.encode(coarseValue.rawValue, forKey: .coarseValue)
        try container.encode(lockWindow, forKey: .lockWindow)
    }
}

/// Dönüşüm penceresi (gün aralığı, iki uç dahil). SDK günleri modülün ilk çalıştığı andan (kayıt çağrısı) sayar.
public struct SkanWindow: Equatable, Sendable, Codable {
    public let index: Int
    public let fromDay: Int
    public let toDay: Int
    /// Bu pencerede ince değer postback'e girer mi (Apple: yalnız ilk pencere).
    public let fineValue: Bool

    public init(index: Int, fromDay: Int, toDay: Int, fineValue: Bool) {
        self.index = index
        self.fromDay = fromDay
        self.toDay = toDay
        self.fineValue = fineValue
    }

    enum CodingKeys: String, CodingKey {
        case index
        case fromDay = "from_day"
        case toDay = "to_day"
        case fineValue = "fine_value"
    }

    /// Apple'ın SKAN 4 pencereleri (sunucudaki `SKAN_WINDOWS`).
    public static let appleDefaults: [SkanWindow] = [
        SkanWindow(index: 0, fromDay: 0, toDay: 2, fineValue: true),
        SkanWindow(index: 1, fromDay: 3, toDay: 7, fineValue: false),
        SkanWindow(index: 2, fromDay: 8, toDay: 35, fineValue: false),
    ]
}

/// Sunucunun SDK dağıtım yanıtı (`SkanSdkSchema`).
public struct SkanSchema: Equatable, Sendable, Codable {
    /// Şema hiç kaydedilmediyse nil; bu durumda değer gönderilmez.
    public let revision: Int?
    public let windows: [SkanWindow]
    public let selection: String
    public let rules: [SkanRule]

    public static let supportedSelection = "highest_value"

    public init(revision: Int?, windows: [SkanWindow] = SkanWindow.appleDefaults, selection: String = SkanSchema.supportedSelection, rules: [SkanRule]) {
        self.revision = revision
        self.windows = windows
        self.selection = selection
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case revision, windows, selection, rules }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision)
        let decodedWindows = try container.decodeIfPresent([SkanWindow].self, forKey: .windows) ?? []
        windows = decodedWindows.isEmpty ? SkanWindow.appleDefaults : decodedWindows
        selection = try container.decodeIfPresent(String.self, forKey: .selection) ?? Self.supportedSelection
        rules = try container.decodeIfPresent([SkanRule].self, forKey: .rules) ?? []
    }

    /// Sunucu zaten doğrular; yine de sözleşme dışı kural (aralık dışı ince değer, bozuk ad, tekrar eden olay) uygulanmaz.
    var validRules: [String: SkanRule] {
        var out: [String: SkanRule] = [:]
        for rule in rules.prefix(64) {
            guard SkanEngine.isEventName(rule.eventName), out[rule.eventName] == nil else { continue }
            if let fine = rule.fineValue, !(0...63).contains(fine) { continue }
            out[rule.eventName] = rule
        }
        return out
    }
}

/// Bir pencerenin cihazda bildirilmiş en yüksek değeri.
struct SkanWindowState: Equatable, Sendable, Codable {
    var index: Int
    var fine: Int?
    var coarse: String?
    var locked: Bool
}

/// Kalıcı modül durumu: kayıt anı, pencere değerleri ve şemanın son kopyası. Kişi verisi yoktur.
struct SkanState: Equatable, Sendable, Codable {
    static let formatVersion = 1
    var version: Int = SkanState.formatVersion
    /// İlk Apple çağrısının (kurulum kaydı) zamanı; pencereler buradan sayılır.
    var registeredAtMillis: Int64?
    var windows: [SkanWindowState] = []
    var schema: SkanSchema?
    var schemaFetchedAtMillis: Int64?

    func window(_ index: Int) -> SkanWindowState {
        windows.first { $0.index == index } ?? SkanWindowState(index: index, fine: nil, coarse: nil, locked: false)
    }

    mutating func setWindow(_ value: SkanWindowState) {
        if let position = windows.firstIndex(where: { $0.index == value.index }) {
            windows[position] = value
        } else {
            windows.append(value)
            windows.sort { $0.index < $1.index }
        }
    }
}

/// Apple'a gidecek tek güncelleme.
struct SkanUpdate: Equatable, Sendable {
    let fine: Int
    let coarse: CoarseConversionLevel
    let lock: Bool
    let window: Int
}

enum SkanEngine {
    static let dayMillis: Int64 = 86_400_000

    static func isEventName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 64, (0x61...0x7A).contains(bytes[0]) else { return false }
        return bytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
    }

    static func rank(_ level: CoarseConversionLevel) -> Int {
        switch level {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    /// Kayıttan geçen güne göre etkin pencere; kayıt yoksa ya da son pencere bittiyse nil.
    static func activeWindow(_ windows: [SkanWindow], registeredAtMillis: Int64?, nowMillis: Int64) -> SkanWindow? {
        guard let registeredAtMillis, nowMillis >= registeredAtMillis else { return nil }
        let day = (nowMillis - registeredAtMillis) / dayMillis
        return windows.first { Int64($0.fromDay) <= day && day <= Int64($0.toDay) }
    }

    /// Kurulum kaydı (Apple: "uygulama ilk açıldığında kurulumu kaydetmek için çağırın"). Durum kayıtlıysa nil. Kayıt değeri ince 0, kaba
    /// `low`'dur; ilk pencereye işlenir, böylece aynı değeri üreten kural ikinci çağrı yaptırmaz.
    static func registration(state: inout SkanState, nowMillis: Int64) -> SkanUpdate? {
        guard state.registeredAtMillis == nil else { return nil }
        state.registeredAtMillis = nowMillis
        state.setWindow(SkanWindowState(index: 0, fine: 0, coarse: CoarseConversionLevel.low.rawValue, locked: false))
        return SkanUpdate(fine: 0, coarse: .low, lock: false, window: 0)
    }

    /// Olayı şemaya göre değerlendirir. Değer artmıyorsa (en yüksek değer seçimi) ve kilit istenmiyorsa nil. Pencere kilitliyse,
    /// şema yoksa, seçim kuralı desteklenmiyorsa ya da son pencere bittiyse nil.
    static func evaluate(eventName: String, state: inout SkanState, nowMillis: Int64) -> SkanUpdate? {
        guard let schema = state.schema, schema.revision != nil, schema.selection == SkanSchema.supportedSelection else { return nil }
        guard let rule = schema.validRules[eventName] else { return nil }
        guard let window = activeWindow(schema.windows, registeredAtMillis: state.registeredAtMillis, nowMillis: nowMillis) else { return nil }
        var current = state.window(window.index)
        guard !current.locked else { return nil }

        var fine = current.fine
        if window.fineValue, let ruleFine = rule.fineValue, ruleFine > (fine ?? -1) { fine = ruleFine }
        var coarse = current.coarse.flatMap(CoarseConversionLevel.init(rawValue:))
        if coarse == nil || rank(rule.coarseValue) > rank(coarse!) { coarse = rule.coarseValue }
        let changed = fine != current.fine || coarse?.rawValue != current.coarse || rule.lockWindow
        guard changed, let level = coarse else { return nil }

        current.fine = window.fineValue ? fine : current.fine
        current.coarse = level.rawValue
        if rule.lockWindow { current.locked = true }
        state.setWindow(current)
        // İlk pencere dışında Apple ince değeri yok sayar; ilk pencerede ince değer yoksa kayıt değeri (0) gider.
        return SkanUpdate(fine: window.fineValue ? (fine ?? 0) : 0, coarse: level, lock: rule.lockWindow, window: window.index)
    }
}

/// `refreshSkanSchema()` sonucu.
public enum SkanSchemaRefresh: Equatable, Sendable {
    /// Şema alındı; `revision` nil ise kiracı henüz şema kaydetmemiş (değer gönderilmez).
    case updated(revision: Int?)
    /// SKAN modülü kapalı (`skan` verilmedi ya da `childDirected`).
    case disabled
    case rejected(status: Int, detail: String)
    case temporaryFailure(status: Int, message: String)
}

/// Kalıcı SKAN durumu deposu: `storageDirectory` varsa dosya, yoksa `UserDefaults`.
protocol SkanStateStore: Sendable {
    func load() -> SkanState?
    func save(_ state: SkanState)
}

struct UserDefaultsSkanStateStore: SkanStateStore, @unchecked Sendable {
    static let key = "com.feralin.skan.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SkanState? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return SkanStateCoding.decode(data)
    }

    func save(_ state: SkanState) {
        if let data = SkanStateCoding.encode(state) { defaults.set(data, forKey: Self.key) }
    }
}

struct DiskSkanStateStore: SkanStateStore {
    let store: FeralinDiskStore

    func load() -> SkanState? {
        store.loadBlob(FeralinDiskStore.skanFileName).flatMap(SkanStateCoding.decode)
    }

    func save(_ state: SkanState) {
        if let data = SkanStateCoding.encode(state) { store.saveBlob(data, name: FeralinDiskStore.skanFileName) }
    }
}

enum SkanStateCoding {
    static func decode(_ data: Data) -> SkanState? {
        guard let state = try? JSONDecoder().decode(SkanState.self, from: data), state.version == SkanState.formatVersion else { return nil }
        return state
    }

    static func encode(_ state: SkanState) -> Data? {
        try? JSONEncoder().encode(state)
    }
}

/// SKAN modülünün istemci içindeki çalışma durumu.
struct SkanRuntime: Sendable {
    let configuration: SkanConfiguration
    let store: any SkanStateStore
    var state: SkanState
    /// Apple çağrıları sırayla yapılır: değerler artan sırada iletilsin.
    var tail: Task<Void, Never>?
    var lastResult: ConversionUpdateResult?
    /// Kurulum görevi (kayıt ve şema yenileme) bitti mi.
    var started = false
}

// MARK: - İstemci yüzeyi

extension FeralinClient {
    /// SKAN şemasını sunucudan alır ve diske yazar. Modül açıkken istemci kurulurken kendiliğinden çağrılır (şema eskiyse); kiracı
    /// panelde şemayı değiştirdiyse hemen uygulanması için de çağrılabilir. Proje anahtarıyla erişilir; kişi verisi gönderilmez.
    @discardableResult
    public func refreshSkanSchema() async -> SkanSchemaRefresh {
        guard skanRuntime != nil, let attribution = attributionConfiguration else { return .disabled }
        let response: TransportResponse
        do {
            response = try await getAttribution(attribution, path: "skan/conversion-schema/sdk")
        } catch {
            return .temporaryFailure(status: 0, message: Self.describe(error))
        }
        switch response.status {
        case 200:
            guard let schema = try? JSONDecoder().decode(SkanSchema.self, from: response.body) else {
                return .temporaryFailure(status: 200, message: "şema çözümlenemedi")
            }
            guard var runtime = skanRuntime else { return .disabled }
            runtime.state.schema = schema
            runtime.state.schemaFetchedAtMillis = Wire.epochMillis(currentTime())
            runtime.store.save(runtime.state)
            skanRuntime = runtime
            return .updated(revision: schema.revision)
        case 429, 500...:
            return .temporaryFailure(status: response.status, message: Self.summarize(response.body))
        default:
            return .rejected(status: response.status, detail: Self.summarize(response.body))
        }
    }

    /// Kurulum kaydı ve gerekiyorsa şema yenilemesi (istemci kurulurken bir kez).
    func startSkan() async {
        guard var runtime = skanRuntime else { return }
        let nowMillis = Wire.epochMillis(currentTime())
        if let update = SkanEngine.registration(state: &runtime.state, nowMillis: nowMillis) {
            runtime.store.save(runtime.state)
            skanRuntime = runtime
            enqueueSkan(update)
        }
        let fetched = runtime.state.schemaFetchedAtMillis
        let stale = fetched == nil || Double(nowMillis - (fetched ?? 0)) >= runtime.configuration.schemaRefreshInterval * 1000
        if stale { _ = await refreshSkanSchema() }
        skanRuntime?.started = true
    }

    /// Testler: istemci kurulurken başlayan SKAN görevinin bitmesini bekler (en çok ~5 sn).
    func waitForSkanStart() async {
        for _ in 0..<5000 {
            guard let runtime = skanRuntime, !runtime.started else { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// `track` içinden çağrılır (izin denetiminden önce: SKAN izin gerektirmez). Değer artarsa Apple çağrısı sıraya girer.
    func observeSkan(_ eventName: String) {
        guard var runtime = skanRuntime else { return }
        let nowMillis = Wire.epochMillis(currentTime())
        // Kayıt henüz yapılmadıysa (kurulum görevi daha çalışmadı) önce kayıt gider; pencereler kayıttan sayılır.
        if let registration = SkanEngine.registration(state: &runtime.state, nowMillis: nowMillis) {
            runtime.store.save(runtime.state)
            skanRuntime = runtime
            enqueueSkan(registration)
        }
        guard let update = SkanEngine.evaluate(eventName: eventName, state: &runtime.state, nowMillis: nowMillis) else { return }
        runtime.store.save(runtime.state)
        skanRuntime = runtime
        enqueueSkan(update)
    }

    private func enqueueSkan(_ update: SkanUpdate) {
        guard var runtime = skanRuntime else { return }
        let previous = runtime.tail
        let updater = skanConversionUpdater
        let frameworks = runtime.configuration.frameworks
        runtime.tail = Task { [weak self] in
            _ = await previous?.value
            let result = await updater(update.fine, update.coarse, update.lock, frameworks)
            await self?.noteSkanResult(result)
        }
        skanRuntime = runtime
    }

    private func noteSkanResult(_ result: ConversionUpdateResult) {
        skanRuntime?.lastResult = result
    }

    /// Son Apple çağrısının sonucu (sağlık ve hata ayıklama). `called` atıf gerçekleşti demek değildir.
    public var lastSkanUpdate: ConversionUpdateResult? { skanRuntime?.lastResult }

    /// Testler: sıradaki Apple çağrılarının bitmesini bekler.
    func waitForSkanIdle() async {
        while let tail = skanRuntime?.tail {
            await tail.value
            if skanRuntime?.tail == nil || skanRuntime?.tail == tail { break }
        }
    }

    /// Testler ve hata ayıklama: modülün kalıcı durumu.
    var skanStateForTesting: SkanState? { skanRuntime?.state }
}
