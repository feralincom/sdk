import Foundation
import XCTest
@testable import Feralin

/// Apple çağrılarını kaydeden sahte güncelleyici.
final class ConversionRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let fine: Int
        let coarse: CoarseConversionLevel
        let lock: Bool
        let frameworks: Int
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: Call) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
    }

    var updater: @Sendable (Int, CoarseConversionLevel, Bool, ConversionFrameworks) async -> ConversionUpdateResult {
        { [self] fine, coarse, lock, frameworks in
            self.record(Call(fine: fine, coarse: coarse, lock: lock, frameworks: frameworks.rawValue))
            return ConversionUpdateResult(adAttributionKit: .called, skAdNetwork: .called)
        }
    }
}

/// SKAN 4 dönüşüm değeri modülü: sunucu sözleşmesi (`skan-schema.ts`, `skan-schemas.service.ts`) ile şema çözümü, pencere,
/// en yüksek değer seçimi, kilit, kalıcılık ve izinden bağımsızlık. Apple çağrısı sahtedir; gerçek SKAdNetwork Linux'ta yoktur.
final class SkanTests: XCTestCase {
    static let schemaJSON = """
    {"revision":3,"windows":[{"index":0,"from_day":0,"to_day":2,"fine_value":true},{"index":1,"from_day":3,"to_day":7,"fine_value":false},{"index":2,"from_day":8,"to_day":35,"fine_value":false}],"selection":"highest_value","rules":[{"event_name":"sign_up","fine_value":5,"coarse_value":"low","lock_window":false},{"event_name":"feralin_purchase","fine_value":40,"coarse_value":"high","lock_window":false},{"event_name":"tutorial_done","fine_value":null,"coarse_value":"medium","lock_window":false},{"event_name":"subscribe","fine_value":63,"coarse_value":"high","lock_window":true}]}
    """

    private let dayMillis: Int64 = 86_400_000

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feralin-skan-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func schema() throws -> SkanSchema {
        try JSONDecoder().decode(SkanSchema.self, from: Data(Self.schemaJSON.utf8))
    }

    private func registeredState(_ schema: SkanSchema, at millis: Int64 = 1_000_000) -> SkanState {
        var state = SkanState()
        _ = SkanEngine.registration(state: &state, nowMillis: millis)
        state.schema = schema
        return state
    }

    private func skanClient(
        transport: FakeTransport,
        recorder: ConversionRecorder,
        directory: URL,
        clock: TestClock = TestClock(),
        consent: Consent = Consent(analytics: true),
        tracking: TrackingAuthorizationStatus = .authorized,
        childDirected: Bool = false,
        frameworks: ConversionFrameworks = .both
    ) throws -> FeralinClient {
        try FeralinClient(
            configuration: .init(
                projectKey: testKey,
                collectURL: testCollect,
                consent: consent,
                flushInterval: 0,
                attribution: AttributionConfiguration(apiURL: "https://api.example.test/", projectID: "proj_1"),
                storageDirectory: directory,
                childDirected: childDirected,
                skan: SkanConfiguration(frameworks: frameworks)
            ),
            transport: transport,
            installIDStore: InMemoryInstallIDStore(),
            installVault: InMemoryInstallIDStore(),
            now: { clock.now() },
            conversionUpdater: recorder.updater,
            trackingStatusProvider: { tracking }
        )
    }

    // MARK: Şema

    func testDecodesServerSdkSchema() throws {
        let decoded = try schema()
        XCTAssertEqual(decoded.revision, 3)
        XCTAssertEqual(decoded.windows, SkanWindow.appleDefaults)
        XCTAssertEqual(decoded.selection, "highest_value")
        XCTAssertEqual(decoded.rules.count, 4)
        XCTAssertEqual(decoded.rules[2], SkanRule(eventName: "tutorial_done", fineValue: nil, coarseValue: .medium))
        XCTAssertEqual(decoded.rules[3].lockWindow, true)

        // Kaydedilmemiş şema: revision null, kural yok.
        let empty = try JSONDecoder().decode(SkanSchema.self, from: Data(#"{"revision":null,"windows":[],"selection":"highest_value","rules":[]}"#.utf8))
        XCTAssertNil(empty.revision)
        XCTAssertEqual(empty.windows, SkanWindow.appleDefaults)
        XCTAssertThrowsError(try JSONDecoder().decode(SkanSchema.self, from: Data(#"{"revision":1,"rules":[{"event_name":"a","fine_value":1,"coarse_value":"huge"}]}"#.utf8)))
    }

    func testInvalidRulesAreIgnored() {
        let rules = [
            SkanRule(eventName: "ok", fineValue: 1, coarseValue: .low),
            SkanRule(eventName: "ok", fineValue: 9, coarseValue: .high),
            SkanRule(eventName: "too_big", fineValue: 64, coarseValue: .low),
            SkanRule(eventName: "Bad-Name", fineValue: 1, coarseValue: .low),
        ]
        let valid = SkanSchema(revision: 1, rules: rules).validRules
        XCTAssertEqual(Array(valid.keys), ["ok"])
        XCTAssertEqual(valid["ok"]?.fineValue, 1)
    }

    // MARK: Karar mantığı

    func testRegistrationHappensOnce() {
        var state = SkanState()
        XCTAssertEqual(SkanEngine.registration(state: &state, nowMillis: 5), SkanUpdate(fine: 0, coarse: .low, lock: false, window: 0))
        XCTAssertEqual(state.registeredAtMillis, 5)
        XCTAssertNil(SkanEngine.registration(state: &state, nowMillis: 9))
        XCTAssertEqual(state.registeredAtMillis, 5)
    }

    func testHighestValueSelectionNeverDecreases() throws {
        var state = registeredState(try schema())
        let start: Int64 = 1_000_000
        XCTAssertEqual(SkanEngine.evaluate(eventName: "sign_up", state: &state, nowMillis: start + 10), SkanUpdate(fine: 5, coarse: .low, lock: false, window: 0))
        // Aynı olay yeniden: değer değişmez, çağrı yok.
        XCTAssertNil(SkanEngine.evaluate(eventName: "sign_up", state: &state, nowMillis: start + 20))
        XCTAssertEqual(SkanEngine.evaluate(eventName: "feralin_purchase", state: &state, nowMillis: start + 30), SkanUpdate(fine: 40, coarse: .high, lock: false, window: 0))
        // Daha düşük değerli olay ince ve kaba değeri düşürmez.
        XCTAssertNil(SkanEngine.evaluate(eventName: "sign_up", state: &state, nowMillis: start + 40))
        XCTAssertNil(SkanEngine.evaluate(eventName: "tutorial_done", state: &state, nowMillis: start + 50))
        XCTAssertNil(SkanEngine.evaluate(eventName: "unknown_event", state: &state, nowMillis: start + 60))
        XCTAssertEqual(state.window(0).fine, 40)
        XCTAssertEqual(state.window(0).coarse, "high")
    }

    func testCoarseOnlyRuleKeepsFineFromEarlierEvent() throws {
        var state = registeredState(try schema())
        _ = SkanEngine.evaluate(eventName: "sign_up", state: &state, nowMillis: 1_000_100)
        XCTAssertEqual(SkanEngine.evaluate(eventName: "tutorial_done", state: &state, nowMillis: 1_000_200), SkanUpdate(fine: 5, coarse: .medium, lock: false, window: 0))
    }

    func testLaterWindowsSendCoarseOnlyAndCountFromRegistration() throws {
        let start: Int64 = 1_000_000
        var state = registeredState(try schema(), at: start)
        // 3. gün: ikinci pencere; ince değer yok sayılır (0 gider), kaba değer pencereye ayrı yazılır.
        let day3 = start + 3 * dayMillis
        XCTAssertEqual(SkanEngine.evaluate(eventName: "feralin_purchase", state: &state, nowMillis: day3), SkanUpdate(fine: 0, coarse: .high, lock: false, window: 1))
        XCTAssertNil(state.window(1).fine)
        // 8. gün: üçüncü pencere yeniden başlar.
        XCTAssertEqual(SkanEngine.evaluate(eventName: "sign_up", state: &state, nowMillis: start + 8 * dayMillis), SkanUpdate(fine: 0, coarse: .low, lock: false, window: 2))
        // 36. gün: pencere yok.
        XCTAssertNil(SkanEngine.evaluate(eventName: "subscribe", state: &state, nowMillis: start + 36 * dayMillis))
        // Kayıttan önce gelen saat (saat geri alındı) değer üretmez.
        XCTAssertNil(SkanEngine.evaluate(eventName: "subscribe", state: &state, nowMillis: start - 1))
    }

    func testLockWindowStopsUpdatesUntilNextWindow() throws {
        let start: Int64 = 1_000_000
        var state = registeredState(try schema(), at: start)
        XCTAssertEqual(SkanEngine.evaluate(eventName: "subscribe", state: &state, nowMillis: start + 1), SkanUpdate(fine: 63, coarse: .high, lock: true, window: 0))
        XCTAssertTrue(state.window(0).locked)
        XCTAssertNil(SkanEngine.evaluate(eventName: "subscribe", state: &state, nowMillis: start + 2))
        XCTAssertNil(SkanEngine.evaluate(eventName: "feralin_purchase", state: &state, nowMillis: start + 3))
        // Sonraki pencere kilitli değildir.
        XCTAssertEqual(SkanEngine.evaluate(eventName: "subscribe", state: &state, nowMillis: start + 4 * dayMillis), SkanUpdate(fine: 0, coarse: .high, lock: true, window: 1))
    }

    func testNoSchemaOrUnsupportedSelectionSendsNothing() throws {
        var state = SkanState()
        _ = SkanEngine.registration(state: &state, nowMillis: 0)
        XCTAssertNil(SkanEngine.evaluate(eventName: "sign_up", state: &state, nowMillis: 1))
        state.schema = SkanSchema(revision: nil, rules: [SkanRule(eventName: "sign_up", fineValue: 1, coarseValue: .low)])
        XCTAssertNil(SkanEngine.evaluate(eventName: "sign_up", state: &state, nowMillis: 1))
        state.schema = SkanSchema(revision: 1, selection: "latest_value", rules: [SkanRule(eventName: "sign_up", fineValue: 1, coarseValue: .low)])
        XCTAssertNil(SkanEngine.evaluate(eventName: "sign_up", state: &state, nowMillis: 1))
    }

    /// Sunucudaki `selectSkanValue` ile aynı sonuç: ilk penceredeki olay kümesi için en yüksek ince ve kaba değer, herhangi biri kilitliyse kilit.
    func testFinalValueMatchesServerSelection() throws {
        let decoded = try schema()
        for observed in [["sign_up", "tutorial_done"], ["tutorial_done", "sign_up", "feralin_purchase"], ["tutorial_done"]] {
            var state = registeredState(decoded)
            var last: SkanUpdate?
            for (offset, name) in observed.enumerated() {
                if let update = SkanEngine.evaluate(eventName: name, state: &state, nowMillis: 1_000_000 + Int64(offset)) { last = update }
            }
            let matched = decoded.rules.filter { observed.contains($0.eventName) }
            let fine = matched.compactMap(\.fineValue).max()
            let coarse = matched.map(\.coarseValue).max { SkanEngine.rank($0) < SkanEngine.rank($1) }
            XCTAssertEqual(last?.coarse, coarse, "\(observed)")
            // Kayıt değeri (0) ince değer üretmeyen olay kümesinde kalır.
            XCTAssertEqual(last?.fine, fine ?? 0, "\(observed)")
        }
    }

    // MARK: İstemci

    func testClientRegistersFetchesSchemaAndUpdatesIndependentOfConsent() async throws {
        let directory = makeDirectory()
        let transport = FakeTransport([.respond(200, Self.schemaJSON, [:])])
        let recorder = ConversionRecorder()
        // Analitik izni yok ve ATT reddedildi: olay üretilmez ama SKAN (izin gerektirmez) çalışır.
        let client = try skanClient(transport: transport, recorder: recorder, directory: directory, consent: Consent(analytics: false), tracking: .denied, frameworks: .skAdNetwork)
        await client.waitForSkanStart()

        XCTAssertEqual(transport.count, 1)
        let request = transport.request(0)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.test/v1/projects/proj_1/skan/conversion-schema/sdk")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(testKey)")
        XCTAssertNil(request.headers["Content-Type"])
        XCTAssertNil(request.headers["X-Feralin-Project-Key"])

        let none = try await client.track("feralin_purchase")
        XCTAssertNil(none)
        _ = try await client.track("sign_up")
        await client.waitForSkanIdle()
        XCTAssertEqual(recorder.calls, [
            .init(fine: 0, coarse: .low, lock: false, frameworks: ConversionFrameworks.skAdNetwork.rawValue),
            .init(fine: 40, coarse: .high, lock: false, frameworks: ConversionFrameworks.skAdNetwork.rawValue),
        ])
        let last = await client.lastSkanUpdate
        XCTAssertEqual(last, ConversionUpdateResult(adAttributionKit: .called, skAdNetwork: .called))
        // Olay kuyruğa girmedi (analitik izni yok).
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(FeralinDiskStore.skanFileName).path))
    }

    func testStatePersistsAcrossRestartWithoutSecondRegistration() async throws {
        let directory = makeDirectory()
        let clock = TestClock()
        let recorder = ConversionRecorder()
        let first = try skanClient(transport: FakeTransport([.respond(200, Self.schemaJSON, [:])]), recorder: recorder, directory: directory, clock: clock)
        await first.waitForSkanStart()
        _ = try await first.track("sign_up")
        await first.waitForSkanIdle()
        await first.close(timeout: 0)

        // Yeniden açılış: şema taze (24 saat dolmadı), ağ isteği yok; kayıt yinelenmez, değer kaldığı yerden sürer.
        clock.advance(3600)
        let secondTransport = FakeTransport()
        let second = try skanClient(transport: secondTransport, recorder: recorder, directory: directory, clock: clock)
        await second.waitForSkanStart()
        XCTAssertEqual(secondTransport.count, 0)
        _ = try await second.track("sign_up")
        _ = try await second.track("feralin_purchase")
        await second.waitForSkanIdle()
        XCTAssertEqual(recorder.calls.map(\.fine), [0, 5, 40])
        XCTAssertEqual(recorder.calls.filter { $0.fine == 0 }.count, 1)

        // 25 saat sonra şema yenilenir.
        clock.advance(25 * 3600)
        let thirdTransport = FakeTransport([.respond(200, Self.schemaJSON, [:])])
        let third = try skanClient(transport: thirdTransport, recorder: recorder, directory: directory, clock: clock)
        await third.waitForSkanStart()
        XCTAssertEqual(thirdTransport.count, 1)
    }

    func testRefreshErrorMapping() async throws {
        let recorder = ConversionRecorder()
        let transport = FakeTransport([
            .respond(503, "{}", [:]),
            .respond(404, #"{"title":"Proje bulunamadı"}"#, [:]),
            .respond(200, "not json", [:]),
            .fail("bağlantı yok"),
        ])
        let client = try skanClient(transport: transport, recorder: recorder, directory: makeDirectory())
        await client.waitForSkanStart()
        // Kurulum görevi ilk yanıtı (503) tüketti.
        let rejected = await client.refreshSkanSchema()
        XCTAssertEqual(rejected, .rejected(status: 404, detail: "Proje bulunamadı"))
        let broken = await client.refreshSkanSchema()
        XCTAssertEqual(broken, .temporaryFailure(status: 200, message: "şema çözümlenemedi"))
        let offline = await client.refreshSkanSchema()
        XCTAssertEqual(offline, .temporaryFailure(status: 0, message: "bağlantı yok"))
        // Şema yokken olay değer üretmez; yalnız kayıt çağrısı vardır.
        _ = try await client.track("feralin_purchase")
        await client.waitForSkanIdle()
        XCTAssertEqual(recorder.calls.map(\.fine), [0])
    }

    func testDisabledForChildDirectedAndRequiresAttribution() async throws {
        let recorder = ConversionRecorder()
        let transport = FakeTransport()
        let child = try skanClient(transport: transport, recorder: recorder, directory: makeDirectory(), childDirected: true)
        let refresh = await child.refreshSkanSchema()
        XCTAssertEqual(refresh, .disabled)
        _ = try await child.track("sign_up")
        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(transport.count, 0)

        XCTAssertThrowsError(try FeralinClient(configuration: .init(projectKey: testKey, collectURL: testCollect, skan: SkanConfiguration()))) { error in
            guard let feralin = error as? FeralinError, case .configuration = feralin else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try FeralinClient(configuration: .init(
            projectKey: testKey, collectURL: testCollect,
            attribution: AttributionConfiguration(apiURL: "https://api.example.test", projectID: "p"),
            skan: SkanConfiguration(schemaRefreshInterval: 0)
        )))

        // Modül verilmezse hiçbir şey yapmaz.
        let plain = try makeClient(transport: FakeTransport(), conversionUpdater: recorder.updater)
        let plainRefresh = await plain.refreshSkanSchema()
        XCTAssertEqual(plainRefresh, .disabled)
        _ = try await plain.track("sign_up")
        XCTAssertTrue(recorder.calls.isEmpty)
    }
}
