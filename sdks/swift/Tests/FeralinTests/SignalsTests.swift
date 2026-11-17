import Foundation
import XCTest
@testable import Feralin

/// Hata, oyun ve reklam geliri sözleşmeleri (X4): Android, Flutter, React Native ve Unity ile aynı alan adları ve sınırlar.
/// BU DOSYA macOS'ta DERLENMEDİ ve KOŞULMADI (bu makinede swift yok); yazım, Android ve React Native testlerinin birebir karşılığıdır.
final class SignalsTests: XCTestCase {
    private func firstEvent(_ transport: FakeTransport) throws -> [String: Any] {
        try XCTUnwrap(try transport.events(0).first)
    }

    private func props(_ event: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(event["properties"] as? [String: Any])
    }

    func testFnvMatchesWebAndFlutterDigest() {
        // Boş dizgenin FNV-1a 64 özeti ofset tabanıdır; "a" için bilinen referans değeri.
        XCTAssertEqual(Signals.fnv1a64(""), "cbf29ce484222325")
        XCTAssertEqual(Signals.fnv1a64("a"), "af63dc4c8601ec8c")
    }

    func testScrubRemovesPersonalData() {
        let out = Signals.scrub("Hata a.b@example.com https://x.test/y?t=1 1234567890 550e8400-e29b-41d4-a716-446655440000 abcdefghijklmnopqrstuvwx1 UnsupportedOperationException")
        XCTAssertEqual(out, "Hata [email] [url] [num] [id] [token] UnsupportedOperationException")
        XCTAssertEqual(Signals.scrub(String(repeating: "a", count: 500)).count, 200)
    }

    func testFramesDropAddressOffsetAndSystemModules() {
        let symbols = [
            "0   Foundation                          0x00000001a1b2c3d4 -[NSObject foo] + 12",
            "1   MyApp                               0x000000010a3b4c8c $s5MyApp8checkoutyyF + 44",
            "2   libdispatch.dylib                    0x00000001a0000000 _dispatch_call_block_and_release + 32",
        ]
        XCTAssertEqual(Signals.normalizeFrames(symbols), ["$s5MyApp8checkoutyyF@MyApp"])
        // Yalnız sistem çerçevesi varsa hepsi kullanılır.
        XCTAssertEqual(Signals.normalizeFrames([symbols[0]]), ["-[NSObject foo]@Foundation"])
    }

    func testErrorPropertiesCarryContractFieldsOnly() {
        let symbols = ["0   MyApp   0x000000010a3b4c8c $s5MyApp8checkoutyyF + 44"]
        let props = Signals.errorProperties(typeName: "CheckoutError", message: "kullanıcı a@b.co bulunamadı", symbols: symbols, origin: "handled", fatal: false, appVersion: "1.2.3")
        XCTAssertEqual(Set(props.keys), ["error_type", "message", "fingerprint", "top_frame", "frame_count", "app_version", "handled", "fatal", "origin"])
        XCTAssertEqual(props["message"], .string("kullanıcı [email] bulunamadı"))
        XCTAssertEqual(props["top_frame"], .string("$s5MyApp8checkoutyyF@MyApp"))
        XCTAssertEqual(props["handled"], .bool(true))
        XCTAssertEqual(props["fatal"], .bool(false))
        guard case .string(let fingerprint)? = props["fingerprint"] else { return XCTFail("parmak izi yok") }
        XCTAssertNotNil(fingerprint.range(of: "^[0-9a-f]{16,64}$", options: .regularExpression))
        // Uzun sürüm eklenmez.
        let long = Signals.errorProperties(typeName: "E", message: "", symbols: [], origin: "handled", fatal: false, appVersion: String(repeating: "v", count: 33))
        XCTAssertNil(long["app_version"])
    }

    /// iOS dSYM çerçeve sözleşmesi: sunucudaki `macho-symbols.ts` (`appleModuleName`, `appleFrameOffset`) ve birim testi `macho-symbols.spec.ts` ile aynı değerler.
    func testAppleFrameContractMatchesServer() throws {
        XCTAssertEqual(AppleFrames.moduleName("My App"), "My_App")
        XCTAssertEqual(AppleFrames.moduleName("Kütüphane+Ek"), "K_t_phane_Ek")
        XCTAssertEqual(AppleFrames.moduleName(String(repeating: "x", count: 200)).count, 95)
        XCTAssertEqual(AppleFrames.moduleName("weird.so"), "weird.so_")
        XCTAssertEqual(AppleFrames.hex([0x4c, 0x00, 0xff]), "4c00ff")
        let uuid = "4c4c446c55553144a119c50b0fbdf4c0"
        // Göreli adres 0x2a3b4c5 = 44283077: satır 5, sütun 4283077 (sunucu: (5 - 1) × 10.000.000 + 4283077).
        XCTAssertEqual(AppleFrames.frame(module: "Crashy", uuid: uuid, offset: 0x2a3b4c5), .object(["file": .string("Crashy~\(uuid)"), "line": .int(5), "column": .int(4_283_077)]))
        XCTAssertEqual(AppleFrames.frame(module: "Crashy", uuid: uuid, offset: 0x4010), .object(["file": .string("Crashy~\(uuid)"), "line": .int(1), "column": .int(0x4010)]))
        XCTAssertNil(AppleFrames.frame(module: "Crashy", uuid: uuid.uppercased(), offset: 1), "UUID küçük harf olmalı")
        XCTAssertNil(AppleFrames.frame(module: "", uuid: uuid, offset: 1))
        let frame = try XCTUnwrap(AppleFrames.frame(module: "Crashy", uuid: uuid, offset: 16))
        let props = Signals.errorProperties(typeName: "E", message: "", symbols: [], origin: "handled", fatal: false, appVersion: nil, frames: Array(repeating: frame, count: 7))
        guard case .array(let frames)? = props["frames"] else { return XCTFail("frames yok") }
        XCTAssertEqual(frames.count, 5, "toplayıcı en çok 5 çerçeve kabul eder")
        XCTAssertNil(Signals.errorProperties(typeName: "E", message: "", symbols: [], origin: "handled", fatal: false, appVersion: nil)["frames"])
    }

    #if canImport(Darwin)
    /// Gerçek yığından çerçeve: test paketi sistem görüntüsü değildir, dosya `<modül>~<uuid>` kalıbında ve sistem görüntüleri atlanır.
    func testAppleFramesCaptureRealStack() {
        let frames = AppleFrames.capture(Thread.callStackReturnAddresses)
        XCTAssertFalse(frames.isEmpty)
        for case .object(let frame) in frames {
            guard case .string(let file)? = frame["file"] else { return XCTFail("file yok") }
            XCTAssertNotNil(file.range(of: "^[A-Za-z0-9._-]{1,95}~[0-9a-f]{32}$", options: .regularExpression), file)
        }
    }
    #endif

    func testCaptureErrorGoesThroughQueueAndIsLimited() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport)
        struct Boom: Error {}
        let symbols = ["0   MyApp   0x000000010a3b4c8c $s5MyApp4boomyyF + 4"]
        for _ in 0..<3 { let value = try await client.captureError(Boom(), appVersion: "9.9", symbols: symbols); XCTAssertNotNil(value) }
        do { let value = try await client.captureError(Boom(), symbols: symbols); XCTAssertNil(value, "aynı parmak izi için en çok 3") }
        _ = try await client.flush()
        let event = try firstEvent(transport)
        XCTAssertEqual(event["event_name"] as? String, "fr_error")
        let properties = try props(event)
        XCTAssertEqual(properties["origin"] as? String, "handled")
        XCTAssertEqual(properties["error_type"] as? String, "Boom")
        XCTAssertNil(properties["stack"])
    }

    func testErrorsNeedAnalyticsConsent() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, consent: Consent(analytics: false))
        struct Boom: Error {}
        // XCTAssert* argümanı eşzamanlı autoclosure'dır: actor çağrısı önce beklenir, sonra doğrulanır.
        let dropped = try await client.captureError(Boom())
        XCTAssertNil(dropped)
        let level = try await client.trackLevelStart("1")
        XCTAssertNil(level)
    }

    func testSampleRateZeroDropsErrors() async throws {
        let client = try makeClient(transport: FakeTransport())
        await client.configureErrorCapture(sampleRate: 0)
        struct Boom: Error {}
        let dropped = try await client.captureError(Boom())
        XCTAssertNil(dropped)
    }

    func testGameEventsUseSharedFieldNames() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport)
        try await client.trackLevelStart("1-3", attempt: 2)
        try await client.trackLevelComplete("1-3", attempt: 2, score: 900, durationMillis: 41000)
        try await client.trackLevelFail("1-3", durationMillis: 5, failReason: "timeout")
        try await client.trackEconomySource("gold", amount: 50, reason: "quest", itemID: "q1")
        try await client.trackEconomySink("gold", amount: 20)
        try await client.trackRewardedAdShown("daily", network: "admob")
        try await client.trackRewardedAdComplete("daily", rewardAmount: 10, rewardCurrency: "gold")
        try await client.trackIapOfferShown("pack_s", placement: "shop")
        try await client.trackIapInitiated("pack_s", transactionID: "tx1")
        _ = try await client.flush()
        let events = try transport.events(0)
        XCTAssertEqual(events.compactMap { $0["event_name"] as? String }, [
            "level_start", "level_complete", "level_fail", "economy_source", "economy_sink",
            "rewarded_ad_shown", "rewarded_ad_complete", "iap_offer_shown", "iap_initiated",
        ])
        let complete = try props(events[1])
        XCTAssertEqual(complete["level_id"] as? String, "1-3")
        XCTAssertEqual(complete["attempt"] as? Int, 2)
        XCTAssertEqual(complete["score"] as? Int, 900)
        XCTAssertEqual(complete["duration_ms"] as? Int, 41000)
        XCTAssertEqual(try props(events[2])["fail_reason"] as? String, "timeout")
        XCTAssertEqual(try props(events[3])["currency_name"] as? String, "gold")
        XCTAssertEqual(try props(events[3])["item_id"] as? String, "q1")
        XCTAssertEqual(try props(events[6])["reward_currency"] as? String, "gold")
        XCTAssertEqual(try props(events[8])["transaction_id"] as? String, "tx1")
    }

    func testGameEventContractViolationsReturnNil() async throws {
        let client = try makeClient(transport: FakeTransport())
        do { let value = try await client.trackLevelStart(""); XCTAssertNil(value) }
        do { let value = try await client.trackLevelStart(String(repeating: "x", count: 65)); XCTAssertNil(value) }
        do { let value = try await client.trackLevelStart("a", attempt: 0); XCTAssertNil(value) }
        do { let value = try await client.trackLevelComplete("a", durationMillis: 86_400_001); XCTAssertNil(value) }
        do { let value = try await client.trackLevelComplete("a", score: -1); XCTAssertNil(value) }
        do { let value = try await client.trackLevelFail("a", failReason: String(repeating: "x", count: 65)); XCTAssertNil(value) }
        do { let value = try await client.trackEconomySource("gold", amount: 0); XCTAssertNil(value) }
        do { let value = try await client.trackEconomySink("gold", amount: 1_000_000_000_001); XCTAssertNil(value) }
        do { let value = try await client.trackRewardedAdShown(""); XCTAssertNil(value) }
        do { let value = try await client.trackIapOfferShown(String(repeating: "p", count: 129)); XCTAssertNil(value) }
        do { let value = try await client.trackIapInitiated("p", transactionID: String(repeating: "t", count: 129)); XCTAssertNil(value) }
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 0)
    }

    func testAdRevenueUsesRevenueMicrosAndDropsVerified() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport)
        let input = AdRevenueInput(
            network: "admob", adFormat: .rewardedInterstitial, revenueMicros: 12500, currency: "USD", adUnit: "ca-app-pub-1/2",
            precision: .precise, placement: "level_end", impressionID: "imp-1",
            properties: ["verified": true, "receipt": "x", "bolum": 3, "receipt_provider": "google"]
        )
        do { let value = try await client.trackAdRevenue(input); XCTAssertNotNil(value) }
        _ = try await client.flush()
        let event = try firstEvent(transport)
        XCTAssertEqual(event["event_name"] as? String, "fr_ad_revenue")
        let properties = try props(event)
        XCTAssertEqual(properties["revenue_micros"] as? Int, 12500)
        XCTAssertEqual(properties["ad_format"] as? String, "rewarded_interstitial")
        XCTAssertEqual(properties["precision"] as? String, "precise")
        XCTAssertEqual(properties["impression_id"] as? String, "imp-1")
        XCTAssertEqual(properties["bolum"] as? Int, 3)
        for reserved in ["verified", "receipt", "receipt_provider"] { XCTAssertNil(properties[reserved]) }
    }

    func testAdRevenueContractViolationsReturnNil() async throws {
        let client = try makeClient(transport: FakeTransport())
        func input(network: String = "admob", micros: Int64 = 1, currency: String = "USD", adUnit: String? = nil, placement: String? = nil) -> AdRevenueInput {
            AdRevenueInput(network: network, adFormat: .banner, revenueMicros: micros, currency: currency, adUnit: adUnit, placement: placement)
        }
        do { let value = try await client.trackAdRevenue(input(network: "AdMob")); XCTAssertNil(value) }
        do { let value = try await client.trackAdRevenue(input(network: "")); XCTAssertNil(value) }
        do { let value = try await client.trackAdRevenue(input(micros: -1)); XCTAssertNil(value) }
        do { let value = try await client.trackAdRevenue(input(micros: Signals.maxNumber + 1)); XCTAssertNil(value) }
        do { let value = try await client.trackAdRevenue(input(currency: "usd")); XCTAssertNil(value) }
        do { let value = try await client.trackAdRevenue(input(adUnit: "")); XCTAssertNil(value) }
        do { let value = try await client.trackAdRevenue(input(placement: String(repeating: "p", count: 65))); XCTAssertNil(value) }
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 0)
        do { let value = try await client.trackAdRevenue(input(micros: 0)); XCTAssertNotNil(value) }
    }
}
