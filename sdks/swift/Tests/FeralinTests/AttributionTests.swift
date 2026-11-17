import Foundation
import XCTest
@testable import Feralin

final class AttributionTests: XCTestCase {
    private let attribution = AttributionConfiguration(apiURL: "https://api.example.test/", projectID: "proj_1")
    private let adConsent = Consent(analytics: true, advertising: true)
    private let longToken = String(repeating: "QUJD", count: 40)

    private let receipt = """
    {"id":"rec_1","status":"exchange_blocked","exchange":{"status":"BLOCKED_EXTERNAL","reason":"Apple erişimi yok","required_access":["Apple Developer"]},"received_at":"2026-11-06T10:00:00.000Z","expires_at":"2026-11-07T10:00:00.000Z","duplicate":false}
    """

    private let confirmation = """
    {"status":"confirmed","decision":"user_confirmed","meaning":"matched_first_open_not_store_download","provenance_class":"ESTIMATED","campaign":"kasim-indirim"}
    """

    func testAdServicesSkippedWithoutConsentAndDoesNotFetchToken() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, attribution: attribution, tokenProvider: {
            XCTFail("izinsiz token alınmamalı")
            return .notSupported
        })
        let result = await client.submitAdServicesToken()
        XCTAssertEqual(result, .skippedNoConsent)
        XCTAssertEqual(transport.count, 0)
    }

    func testAdServicesNotConfigured() async throws {
        let client = try makeClient(transport: FakeTransport(), consent: adConsent)
        let result = await client.submitAdServicesToken(longToken)
        XCTAssertEqual(result, .notConfigured)
    }

    func testAdServicesPostsTokenWithBearerProjectKey() async throws {
        let transport = FakeTransport([.respond(202, receipt, [:])])
        let token = longToken
        let store = InMemoryInstallIDStore(value: "01JC0000000000000000INSTAL")
        let client = try makeClient(transport: transport, consent: adConsent, attribution: attribution, store: store, tokenProvider: { .token(token) })
        let result = await client.submitAdServicesToken()
        guard case .received(let value) = result else { return XCTFail("received bekleniyordu: \(result)") }
        XCTAssertEqual(value.status, "exchange_blocked")
        XCTAssertEqual(value.exchangeStatus, "BLOCKED_EXTERNAL")
        XCTAssertFalse(value.duplicate)

        let request = transport.request(0)
        XCTAssertEqual(request.url.absoluteString, "https://api.example.test/v1/projects/proj_1/attribution/apple-adservices/tokens")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(testKey)")
        XCTAssertNil(request.headers["X-Feralin-Project-Key"])
        let body = try transport.body(0)
        XCTAssertEqual(body["token"] as? String, token)
        XCTAssertEqual(body["install_id"] as? String, "01JC0000000000000000INSTAL")
        XCTAssertEqual(body.count, 2, "sözleşmede fazladan alan kabul edilmez")
    }

    func testAdServicesReportsUnsupportedAndFailures() async throws {
        let unsupported = try makeClient(transport: FakeTransport(), consent: adConsent, attribution: attribution, tokenProvider: { .notSupported })
        let first = await unsupported.submitAdServicesToken()
        XCTAssertEqual(first, .notSupported)

        let failed = try makeClient(transport: FakeTransport(), consent: adConsent, attribution: attribution, tokenProvider: { .failed("AdServices hatası") })
        let second = await failed.submitAdServicesToken()
        XCTAssertEqual(second, .tokenUnavailable("AdServices hatası"))

        let rejected = try makeClient(transport: FakeTransport([.respond(400, "{\"title\":\"Token geçersiz\"}", [:])]), consent: adConsent, attribution: attribution)
        let third = await rejected.submitAdServicesToken(longToken)
        XCTAssertEqual(third, .rejected(status: 400, detail: "Token geçersiz"))

        let down = try makeClient(transport: FakeTransport([.fail("ağ hatası")]), consent: adConsent, attribution: attribution)
        let fourth = await down.submitAdServicesToken(longToken)
        XCTAssertEqual(fourth, .temporaryFailure(status: 0, message: "ağ hatası"))
    }

    func testRedeemSendsContractFields() async throws {
        let transport = FakeTransport([.respond(200, confirmation, [:])])
        let store = InMemoryInstallIDStore(value: "01JC0000000000000000INSTAL")
        let client = try makeClient(transport: transport, consent: adConsent, attribution: attribution, platform: "ios", store: store)
        let result = await client.redeemContinuityCode("  ABCD-1234 \n")
        guard case .confirmed(let value) = result else { return XCTFail("confirmed bekleniyordu: \(result)") }
        XCTAssertEqual(value.decision, "user_confirmed")
        XCTAssertEqual(value.meaning, "matched_first_open_not_store_download")
        XCTAssertEqual(value.provenanceClass, "ESTIMATED")
        XCTAssertEqual(value.campaign, "kasim-indirim")

        let request = transport.request(0)
        XCTAssertEqual(request.url.absoluteString, "https://api.example.test/v1/projects/proj_1/attribution/continuity-tokens/redeem")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(testKey)")
        let body = try transport.body(0)
        XCTAssertEqual(body["code"] as? String, "ABCD-1234")
        XCTAssertEqual(body["install_id"] as? String, "01JC0000000000000000INSTAL")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["consent"] as? Bool, true)
        XCTAssertEqual(body["user_action"] as? Bool, true)
        XCTAssertEqual(body.count, 5)
    }

    func testRedeemErrorMapping() async throws {
        let cases: [(FakeTransport.Step, ContinuityRedemption)] = [
            (.respond(404, "{}", [:]), .invalidCode),
            (.respond(409, "{}", [:]), .selfRedeem),
            (.respond(429, "{}", [:]), .rateLimited),
            (.respond(403, "{\"title\":\"Yasak\"}", [:]), .rejected(status: 403, detail: "Yasak")),
            (.respond(503, "{\"title\":\"Kapalı\"}", [:]), .temporaryFailure(status: 503, message: "Kapalı")),
            (.fail("ağ hatası"), .temporaryFailure(status: 0, message: "ağ hatası")),
        ]
        for (step, expected) in cases {
            let client = try makeClient(transport: FakeTransport([step]), consent: adConsent, attribution: attribution, platform: "ios")
            let result = await client.redeemContinuityCode("ABCD")
            XCTAssertEqual(result, expected)
        }
    }

    func testRedeemGates() async throws {
        let transport = FakeTransport()
        let noConsent = try makeClient(transport: transport, attribution: attribution, platform: "ios")
        let first = await noConsent.redeemContinuityCode("ABCD")
        XCTAssertEqual(first, .skippedNoConsent)

        let macOS = try makeClient(transport: transport, consent: adConsent, attribution: attribution, platform: "other")
        let second = await macOS.redeemContinuityCode("ABCD")
        XCTAssertEqual(second, .notSupported)

        let blank = try makeClient(transport: transport, consent: adConsent, attribution: attribution, platform: "ios")
        let third = await blank.redeemContinuityCode("   ")
        XCTAssertEqual(third, .invalidCode)

        let unconfigured = try makeClient(transport: transport, consent: adConsent, platform: "ios")
        let fourth = await unconfigured.redeemContinuityCode("ABCD")
        XCTAssertEqual(fourth, .notConfigured)

        XCTAssertEqual(transport.count, 0, "bu yolların hiçbiri ağa çıkmamalı")
    }

    func testConversionUpdateNeedsAdvertisingConsent() async throws {
        let denied = try makeClient(transport: FakeTransport(), conversionUpdater: { _, _, _, _ in
            XCTFail("izinsiz Apple çağrısı yapılmamalı")
            return ConversionUpdateResult(adAttributionKit: .called, skAdNetwork: .called)
        })
        let first = await denied.updateConversionValue(fine: 12, coarse: .medium)
        XCTAssertEqual(first, ConversionUpdateResult(adAttributionKit: .skippedNoConsent, skAdNetwork: .skippedNoConsent))

        let allowed = try makeClient(transport: FakeTransport(), consent: adConsent)
        let second = await allowed.updateConversionValue(fine: 12, coarse: .medium)
        XCTAssertEqual(second, ConversionUpdateResult(adAttributionKit: .called, skAdNetwork: .called))
    }

    func testConversionValueRangeIsChecked() async {
        for fine in [-1, 64] {
            let result = await FeralinApple.updateConversionValue(fine: fine, coarse: .low)
            XCTAssertEqual(result.adAttributionKit, .failed("dönüşüm değeri 0-63 aralığında olmalı"))
            XCTAssertEqual(result.skAdNetwork, .failed("dönüşüm değeri 0-63 aralığında olmalı"))
        }
    }

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var status: TrackingAuthorizationStatus
        init(_ status: TrackingAuthorizationStatus) { self.status = status }
        var value: TrackingAuthorizationStatus {
            get { lock.lock(); defer { lock.unlock() }; return status }
            set { lock.lock(); defer { lock.unlock() }; status = newValue }
        }
    }

    func testATTRefusalClosesAdvertisingEvenIfAppSaysYes() async throws {
        for status in [TrackingAuthorizationStatus.denied, .restricted, .notDetermined] {
            let transport = FakeTransport()
            let client = try makeClient(
                transport: transport,
                consent: adConsent,
                attribution: attribution,
                platform: "ios",
                tokenProvider: {
                    XCTFail("ATT izni yokken token alınmamalı")
                    return .notSupported
                },
                conversionUpdater: { _, _, _, _ in
                    XCTFail("ATT izni yokken Apple çağrısı yapılmamalı")
                    return ConversionUpdateResult(adAttributionKit: .called, skAdNetwork: .called)
                },
                trackingStatus: { status }
            )
            let fetched = await client.submitAdServicesToken()
            XCTAssertEqual(fetched, .skippedNoConsent)
            let given = await client.submitAdServicesToken(longToken)
            XCTAssertEqual(given, .skippedNoConsent, "elle verilen token da gönderilmemeli")
            let redeemed = await client.redeemContinuityCode("ABCD")
            XCTAssertEqual(redeemed, .skippedNoConsent)
            let conversion = await client.updateConversionValue(fine: 12, coarse: .medium)
            XCTAssertEqual(conversion, ConversionUpdateResult(adAttributionKit: .skippedNoConsent, skAdNetwork: .skippedNoConsent))
            XCTAssertEqual(transport.count, 0, "\(status): attribution ağa çıkmamalı")

            let tracked = try await client.track("order_completed", properties: ["fr_click": "clk", "order_id": "ord_1"])
            XCTAssertNil(tracked?.properties?["fr_click"], "\(status): fr_click çıkarılmalı")
            XCTAssertEqual(tracked?.consent.advertising, false)
            _ = try await client.flush()
            let event = try XCTUnwrap(try transport.events(0).first)
            XCTAssertNil((event["properties"] as? [String: Any])?["fr_click"])
            XCTAssertEqual((event["consent"] as? [String: Any])?["advertising"] as? Bool, false)
            XCTAssertEqual((event["consent"] as? [String: Any])?["analytics"] as? Bool, true, "ATT analitik iznini değiştirmez")
        }
    }

    func testATTStatusIsReadOnEveryCall() async throws {
        let box = StatusBox(.notDetermined)
        let client = try makeClient(transport: FakeTransport(), consent: adConsent, trackingStatus: { box.value })
        let before = try await client.track("a", properties: ["fr_click": "clk"])
        XCTAssertEqual(before?.consent.advertising, false)

        box.value = .authorized
        let allowed = try await client.track("a", properties: ["fr_click": "clk"])
        XCTAssertEqual(allowed?.consent.advertising, true, "kullanıcı izin verince yeniden setConsent gerekmez")
        XCTAssertNotNil(allowed?.properties?["fr_click"])

        box.value = .denied
        let after = try await client.track("a", properties: ["fr_click": "clk"])
        XCTAssertEqual(after?.consent.advertising, false, "Ayarlar'dan geri çekilirse kapanır")
        let status = await client.status()
        XCTAssertFalse(status.consent.advertising)
    }

    func testATTNeverOpensAppRefusalAndUnavailableKeepsDecision() async throws {
        let refused = try makeClient(transport: FakeTransport(), consent: Consent(analytics: true), trackingStatus: { .authorized })
        let first = try await refused.track("a", properties: ["fr_click": "clk"])
        XCTAssertNil(first?.properties?["fr_click"])

        let noATT = try makeClient(transport: FakeTransport(), consent: adConsent, trackingStatus: { .unavailable })
        let second = try await noATT.track("a", properties: ["fr_click": "clk"])
        XCTAssertNotNil(second?.properties?["fr_click"], "ATT olmayan platformda uygulamanın kararı geçerli")
    }

    func testInstallIdentifierNeedsAdvertisingConsentAndIsStable() async throws {
        // İstemci bir actor'dır: çağrı önce beklenir, sonuç sonra doğrulanır (XCTAssert* argümanı eşzamanlı autoclosure'dır).
        let store = InMemoryInstallIDStore()
        let noAds = try makeClient(transport: FakeTransport(), consent: Consent(analytics: true), store: store)
        let withoutConsent = await noAds.installIdentifier()
        XCTAssertNil(withoutConsent, "reklam izni yokken kimlik üretilmez")
        XCTAssertNil(store.load(), "izinsiz kimlik diske yazılmaz")

        let client = try makeClient(transport: FakeTransport(), consent: adConsent, store: store)
        let created = await client.installIdentifier()
        let first = try XCTUnwrap(created)
        let again = await client.installIdentifier()
        XCTAssertEqual(again, first)
        XCTAssertEqual(store.load(), first)

        let denied = try makeClient(transport: FakeTransport(), consent: adConsent, trackingStatus: { .denied })
        let afterDenial = await denied.installIdentifier()
        XCTAssertNil(afterDenial, "ATT reddi reklam iznini kapatır")
    }

    func testBindInstallSendsTokenWithSameInstallIDAndReturnsIt() async throws {
        let transport = FakeTransport([.respond(202, receipt, [:])])
        let token = longToken
        let store = InMemoryInstallIDStore(value: "01JC0000000000000000INSTAL")
        let client = try makeClient(transport: transport, consent: adConsent, attribution: attribution, store: store, tokenProvider: { .token(token) })
        let result = await client.bindInstall()
        XCTAssertEqual(result.installID, "01JC0000000000000000INSTAL")
        guard case .received = result.adServices else { return XCTFail("received bekleniyordu: \(result.adServices)") }
        let body = try transport.body(0)
        XCTAssertEqual(body["install_id"] as? String, result.installID, "token ile dönen kimlik aynı olmalı")
    }

    func testBindInstallKeepsInstallIDWhenTokenUnavailable() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, consent: adConsent, attribution: attribution, tokenProvider: { .notSupported })
        let result = await client.bindInstall()
        XCTAssertEqual(result.adServices, .notSupported)
        XCTAssertNotNil(result.installID, "token yokken de hesap bağı için kimlik geçerlidir")
        XCTAssertEqual(transport.count, 0)
    }

    func testBindInstallWithoutConsentDoesNothing() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, attribution: attribution, tokenProvider: {
            XCTFail("izinsiz token alınmamalı")
            return .notSupported
        })
        let result = await client.bindInstall()
        XCTAssertEqual(result, InstallBinding(installID: nil, adServices: .skippedNoConsent))
        XCTAssertEqual(transport.count, 0)
    }

    func testConsentConstrainedByATT() {
        let consent = Consent(analytics: true, advertising: true)
        XCTAssertTrue(consent.constrained(by: .authorized).advertising)
        XCTAssertTrue(consent.constrained(by: .unavailable).advertising)
        XCTAssertFalse(consent.constrained(by: .denied).advertising)
        XCTAssertFalse(consent.constrained(by: .restricted).advertising)
        XCTAssertFalse(consent.constrained(by: .notDetermined).advertising)
        XCTAssertTrue(consent.constrained(by: .denied).analytics, "ATT analitik iznini değiştirmez")
        XCTAssertFalse(Consent(analytics: true).constrained(by: .authorized).advertising, "ATT hayır kararını evete çevirmez")
    }
}
