#if canImport(ObjectiveC)
import Feralin
import Foundation
import XCTest
@testable import FeralinObjC

/// Köprünün Swift çekirdeğine doğru türü geçirdiğini sınar. Çekirdek davranışı `sdks/swift` testlerindedir.
final class FRLFeralinTests: XCTestCase {
    private final class CapturingTransport: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []

        var lastEvent: [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            guard let data = bodies.last,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = object["events"] as? [[String: Any]] else { return nil }
            return events.first
        }

        private func record(_ body: Data) {
            lock.lock()
            defer { lock.unlock() }
            bodies.append(body)
        }

        func send(_ request: TransportRequest) async throws -> TransportResponse {
            record(request.body)
            return TransportResponse(status: 202, body: Data("{\"accepted\":1,\"rejected\":0,\"batch_id\":\"b1\"}".utf8))
        }
    }

    private func makeBridge(consent: Consent, transport: CapturingTransport) throws -> FRLFeralin {
        let client = try FeralinClient(
            configuration: .init(projectKey: "pk_test_objc_0001", collectURL: "https://collect.example.test", consent: consent, flushInterval: 0, sdk: FRLFeralin.sdk),
            transport: transport,
            installIDStore: InMemoryInstallIDStore(),
            trackingStatusProvider: { .authorized }
        )
        return FRLFeralin(client: client)
    }

    private func track(_ bridge: FRLFeralin, _ name: String, _ properties: [String: Any]?) async -> (String?, NSError?) {
        await withCheckedContinuation { continuation in
            bridge.track(name, properties: properties) { id, error in continuation.resume(returning: (id, error)) }
        }
    }

    private func flush(_ bridge: FRLFeralin) async -> FRLFlushResult? {
        await withCheckedContinuation { continuation in
            bridge.flush { result, _ in continuation.resume(returning: result) }
        }
    }

    func testSecretKeyBecomesNSError() {
        let configuration = FRLConfiguration(projectKey: "sk_live_abcdefgh", collectURL: "https://collect.example.test")
        XCTAssertThrowsError(try FRLFeralin(configuration: configuration)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, FRLFeralinErrorDomain)
            XCTAssertEqual(nsError.code, FRLErrorCode.configuration.rawValue)
        }
    }

    func testPropertiesConvertWithBooleansDistinct() async throws {
        let transport = CapturingTransport()
        let bridge = try makeBridge(consent: Consent(analytics: true), transport: transport)
        let properties: [String: Any] = [
            "flag": NSNumber(value: true),
            "count": NSNumber(value: 3),
            "amount": NSNumber(value: 12.5),
            "name": "kalem" as NSString,
            "none": NSNull(),
            "tags": ["a", "b"] as NSArray,
            "nested": ["x": NSNumber(value: 1)] as NSDictionary,
            "fr_click": "clk" as NSString,
        ]
        let (id, error) = await track(bridge, "order_completed", properties)
        XCTAssertNotNil(id)
        XCTAssertNil(error)
        let result = await flush(bridge)
        XCTAssertEqual(result?.ok, true)
        XCTAssertEqual(result?.accepted, 1)
        XCTAssertEqual(result?.batchID, "b1")

        let wire = try XCTUnwrap(transport.lastEvent)
        XCTAssertEqual((wire["sdk"] as? [String: Any])?["name"] as? String, "feralin-objc")
        let sent = try XCTUnwrap(wire["properties"] as? [String: Any])
        XCTAssertTrue((sent["flag"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false)
        XCTAssertEqual(sent["count"] as? Int, 3)
        XCTAssertEqual(sent["amount"] as? Double, 12.5)
        XCTAssertEqual(sent["name"] as? String, "kalem")
        XCTAssertTrue(sent["none"] is NSNull)
        XCTAssertEqual(sent["tags"] as? [String], ["a", "b"])
        XCTAssertEqual((sent["nested"] as? [String: Any])?["x"] as? Int, 1)
        XCTAssertNil(sent["fr_click"], "reklam izni yokken fr_click çıkarılmalı")
    }

    func testUnsupportedPropertyTypeIsRejectedWithoutCrash() async throws {
        let bridge = try makeBridge(consent: Consent(analytics: true), transport: CapturingTransport())
        let (id, error) = await track(bridge, "order_completed", ["obj": NSObject()])
        XCTAssertNil(id)
        XCTAssertEqual(error?.code, FRLErrorCode.invalidEvent.rawValue)
    }

    func testNoConsentReturnsNilWithoutError() async throws {
        let bridge = try makeBridge(consent: Consent(), transport: CapturingTransport())
        let (id, error) = await track(bridge, "order_completed", nil)
        XCTAssertNil(id)
        XCTAssertNil(error)
    }

    func testConsentWithdrawalIsProcessedBeforeFollowingTrack() async throws {
        for _ in 0..<50 {
            let transport = CapturingTransport()
            let bridge = try makeBridge(consent: Consent(analytics: true, advertising: true), transport: transport)
            // Araya bekleme konmaz: aynı akıştan art arda gelen çağrıların sırası korunmalı.
            bridge.setConsent(FRLConsent(analytics: true, advertising: false, personalization: false, sessionReplay: false), completion: nil)
            bridge.track("order_completed", properties: ["fr_click": "clk" as NSString], completion: nil)
            let result = await flush(bridge)
            XCTAssertEqual(result?.accepted, 1, "flush önceki track'i görmeli")
            let wire = try XCTUnwrap(transport.lastEvent)
            XCTAssertNil((wire["properties"] as? [String: Any])?["fr_click"])
            XCTAssertEqual((wire["consent"] as? [String: Any])?["advertising"] as? Bool, false)
        }
    }

    func testAnalyticsWithdrawalBeforeTrackProducesNoEvent() async throws {
        for _ in 0..<50 {
            let bridge = try makeBridge(consent: Consent(analytics: true), transport: CapturingTransport())
            bridge.setConsent(FRLConsent(), completion: nil)
            let (id, error) = await track(bridge, "order_completed", nil)
            XCTAssertNil(id)
            XCTAssertNil(error)
        }
    }

    func testCloseThenTrackGetsClosedError() async throws {
        let bridge = try makeBridge(consent: Consent(analytics: true), transport: CapturingTransport())
        bridge.close(completion: nil)
        let (_, error) = await track(bridge, "order_completed", nil)
        XCTAssertEqual(error?.code, FRLErrorCode.clientClosed.rawValue)
    }

    func testConsentConstraintMatchesSwift() {
        let consent = FRLConsent(analytics: true, advertising: true, personalization: false, sessionReplay: false)
        XCTAssertFalse(consent.constrained(byTrackingStatus: .denied).advertising)
        XCTAssertTrue(consent.constrained(byTrackingStatus: .authorized).advertising)
        XCTAssertTrue(consent.constrained(byTrackingStatus: .denied).analytics)
    }

    func testAttributionWithoutConfigurationReportsNotConfigured() async throws {
        let bridge = try makeBridge(consent: Consent(analytics: true, advertising: true), transport: CapturingTransport())
        let result: FRLAttributionResult = await withCheckedContinuation { continuation in
            bridge.submitAdServicesToken { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(result.outcome, "not_configured")
    }

    func testConversionWithoutConsentIsSkipped() async throws {
        let bridge = try makeBridge(consent: Consent(analytics: true), transport: CapturingTransport())
        let outcomes: (String, String) = await withCheckedContinuation { continuation in
            bridge.updateConversionValue(12, coarse: .medium, lock: false) { aak, skan in
                continuation.resume(returning: (aak, skan))
            }
        }
        XCTAssertEqual(outcomes.0, "skipped_no_consent")
        XCTAssertEqual(outcomes.1, "skipped_no_consent")
    }
}
#endif
