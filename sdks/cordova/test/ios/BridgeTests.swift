// FeralinBridge.swift (Cordova ve Capacitor ortak iOS köprüsü) için XCTest. Cordova ve Capacitor çerçevesi gerektirmez; Feralin Swift
// çekirdeğiyle birlikte Linux'ta (WSL, Swift 6.4.2) ya da macOS'ta koşar: sdks/cordova/scripts/check-ios-bridge.sh.
import Foundation
import XCTest
@testable import Feralin
@testable import FeralinBridgeCheck

final class BridgeTests: XCTestCase {
    private func makeBridge() -> (FeralinBridge, UserDefaults) {
        let suite = "feralin.bridge.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (FeralinBridge(defaults: defaults), defaults)
    }

    private func config(consent: [String: Any]? = ["analytics": true, "advertising": true]) -> [String: Any] {
        var config: [String: Any] = ["projectKey": "pk_test_123456", "collectUrl": "http://127.0.0.1:9", "flushIntervalMs": 0.0]
        if let consent { config["consent"] = consent }
        return config
    }

    func testValueConversionSeparatesBoolIntAndDouble() {
        XCTAssertEqual(FeralinBridge.value(from: NSNumber(value: true), depth: 0), .bool(true))
        XCTAssertEqual(FeralinBridge.value(from: NSNumber(value: 3), depth: 0), .int(3))
        XCTAssertEqual(FeralinBridge.value(from: NSNumber(value: 3.0), depth: 0), .int(3))
        XCTAssertEqual(FeralinBridge.value(from: NSNumber(value: 2.5), depth: 0), .double(2.5))
        XCTAssertNil(FeralinBridge.value(from: NSNumber(value: Double.infinity), depth: 0))
        XCTAssertEqual(FeralinBridge.value(from: NSNull(), depth: 0), .null)
        XCTAssertEqual(FeralinBridge.value(from: ["a": [1, "x"]] as [String: Any], depth: 0), .object(["a": .array([.int(1), .string("x")])]))
        XCTAssertNil(FeralinBridge.properties(from: "metin"))
        XCTAssertNil(FeralinBridge.properties(from: [String: Any]()))
    }

    func testHexTokenAndConsentParsing() {
        XCTAssertEqual(FeralinBridge.data(fromHex: String(repeating: "ab", count: 16))?.count, 16)
        XCTAssertNil(FeralinBridge.data(fromHex: "abc"))
        XCTAssertNil(FeralinBridge.data(fromHex: String(repeating: "zz", count: 16)))
        XCTAssertNil(FeralinBridge.consent(from: ["advertising": true]))
        let consent = FeralinBridge.consent(from: ["analytics": true, "session_replay": true])
        XCTAssertEqual(consent, Consent(analytics: true, advertising: false, personalization: false, sessionReplay: true))
    }

    func testRejectsSecretKeyAndMissingFields() {
        let (bridge, _) = makeBridge()
        XCTAssertFalse(bridge.initialize(["projectKey": "sk_live_123456", "collectUrl": "https://c.example.com"], sdkName: "t", sdkVersion: "1"))
        XCTAssertFalse(bridge.initialize(["projectKey": "pk_test_123456"], sdkName: "t", sdkVersion: "1"))
    }

    func testUninitializedBridgeReturnsSafeDefaults() async {
        let (bridge, _) = makeBridge()
        let id = await bridge.track("level_up", properties: nil)
        XCTAssertNil(id)
        let first = await bridge.trackFirstOpen([:])
        XCTAssertEqual(first["status"] as? String, "not_initialized")
        let deferred = await bridge.consumeDeferredDeepLink()
        XCTAssertEqual(deferred["status"] as? String, "not_initialized")
        let status = await bridge.status()
        XCTAssertEqual(status["initialized"] as? Bool, false)
    }

    func testTrackFirstOpenRevenueAndConsentFlow() async {
        let (bridge, defaults) = makeBridge()
        XCTAssertTrue(bridge.initialize(config(), sdkName: "cordova-plugin-feralin", sdkVersion: "0.1.0"))
        let eventID = await bridge.track("level_up", properties: ["level": NSNumber(value: 3)])
        XCTAssertNotNil(eventID)
        let screen = await bridge.screen("home", properties: nil)
        XCTAssertNotNil(screen)

        let first = await bridge.trackFirstOpen(["clickId": "not-a-click"])
        XCTAssertEqual(first["status"] as? String, "sent")
        let again = await bridge.trackFirstOpen([:])
        XCTAssertEqual(again["status"] as? String, "already_sent")

        let revenue = await bridge.trackRevenue(properties: ["transaction_id": "t1", "amount_minor": NSNumber(value: 4999), "currency": "TRY"])
        XCTAssertNotNil(revenue)
        let missing = await bridge.trackRevenue(properties: ["transaction_id": "t1"])
        XCTAssertNil(missing)

        let status = await bridge.status()
        XCTAssertEqual(status["initialized"] as? Bool, true)
        XCTAssertEqual(status["sdk"] as? String, "cordova-plugin-feralin")
        XCTAssertEqual(status["queued"] as? Int, 4)

        let deferred = await bridge.consumeDeferredDeepLink()
        XCTAssertEqual(deferred["status"] as? String, "not_configured")

        let push = await bridge.setPushToken(String(repeating: "0a", count: 32))
        XCTAssertNotNil(push)
        let badPush = await bridge.setPushToken("xyz")
        XCTAssertNil(badPush)

        let accepted = await bridge.setConsent(["analytics": false])
        XCTAssertTrue(accepted)
        XCTAssertFalse(defaults.bool(forKey: FeralinBridge.firstOpenKey))
        let afterOptOut = await bridge.track("level_up", properties: nil)
        XCTAssertNil(afterOptOut)
        let cleared = await bridge.status()
        XCTAssertEqual(cleared["queued"] as? Int, 0)
    }

    func testFirstOpenSkippedWithoutConsentIsNotRemembered() async {
        let (bridge, defaults) = makeBridge()
        XCTAssertTrue(bridge.initialize(config(consent: nil), sdkName: "t", sdkVersion: "1"))
        let first = await bridge.trackFirstOpen([:])
        XCTAssertEqual(first["status"] as? String, "skipped")
        XCTAssertFalse(defaults.bool(forKey: FeralinBridge.firstOpenKey))
    }

    func testUniversalLinkDestination() async {
        let (bridge, _) = makeBridge()
        XCTAssertTrue(bridge.initialize(config(), sdkName: "t", sdkVersion: "1"))
        let open = await bridge.handleUniversalLink("https://example.com/urun/42?renk=mavi")
        XCTAssertEqual(open["destination"] as? String, "/urun/42?renk=mavi")
        XCTAssertEqual(open["hasClickId"] as? Bool, false)
    }
}
