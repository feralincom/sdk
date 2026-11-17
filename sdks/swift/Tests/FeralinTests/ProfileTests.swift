import Foundation
import XCTest
@testable import Feralin

/// UTP §8.2 kimlik yöntemleri: group, setUserProperties, setGlobalProperties (toplayıcı profile_filter.go ile aynı kurallar).
/// DİKKAT: Mac olmadan yazıldı; DERLENMEDİ ve KOŞULMADI.
final class ProfileTests: XCTestCase {
    func testPIIKeyRuleMatchesCollector() {
        let pii = [
            "email", "userEmail", "contact_email_address", "phone_number", "phoneNumber", "userIP", "ipv4",
            "first_name", "lastName", "name", "username", "ad", "soyadi", "home_address", "tckn",
        ]
        let safe = ["plan", "plan_name", "zip", "hotel_tier", "membership", "ad_network"]
        for key in pii { XCTAssertTrue(ProfileRules.isPIILikeKey(key), key) }
        for key in safe { XCTAssertFalse(ProfileRules.isPIILikeKey(key), key) }
    }

    func testUserPropertiesDropPIIReservedAndOffContractValues() async throws {
        let client = try makeClient(transport: FakeTransport())
        let event = try await client.setUserProperties([
            "plan": .string("pro"), "tier": .int(2), "beta": .bool(true), "email": .string("a@b.co"), "verified": .bool(true),
            "note": .string(String(repeating: "x", count: 257)), "nested": .object(["a": .int(1)]), "list": .array([.int(1)]),
            "ratio": .double(.nan), "contact": .string("x@y.io"),
        ])
        XCTAssertEqual(event?.eventName, "fr_user_properties")
        XCTAssertEqual(Set(event?.properties.map { Array($0.keys) } ?? []), ["plan", "tier", "beta"])
        let none = try await client.setUserProperties(["email": .string("x"), "phone": .string("1")])
        XCTAssertNil(none)
        let empty = try await client.setUserProperties([:])
        XCTAssertNil(empty)
    }

    func testFiftyPropertiesPerCall() async throws {
        let client = try makeClient(transport: FakeTransport())
        var many: [String: FeralinValue] = [:]
        for index in 0..<70 { many["k\(index)"] = .int(Int64(index)) }
        let event = try await client.setUserProperties(many)
        XCTAssertEqual(event?.properties?.count, ProfileRules.maxProperties)
    }

    func testInvalidGroupIDProducesNoEvent() async throws {
        let client = try makeClient(transport: FakeTransport())
        for id in ["", "   ", "ekip@acme.com", "a\u{0001}b", String(repeating: "g", count: 129)] {
            let event = try await client.group(id)
            XCTAssertNil(event, id)
        }
        let event = try await client.group("acme-team", traits: ["plan": .string("team"), "group_id": .string("sahte"), "owner_email": .string("x"), "seats": .int(12)])
        XCTAssertEqual(event?.properties?["group_id"], .string("acme-team"))
        XCTAssertEqual(event?.properties?["seats"], .int(12))
        XCTAssertNil(event?.properties?["owner_email"])
    }

    func testGlobalsMergeEventWinsNullRemovesNotOnSystemEventsResetClears() async throws {
        let client = try makeClient(transport: FakeTransport())
        let dropped = await client.setGlobalProperties(["app_release": .string("1.2.0"), "region": .string("eu"), "email": .string("x")])
        XCTAssertEqual(dropped, 1)
        await client.setGlobalProperties(["region": .null, "channel": .string("app")])
        let plain = try await client.track("checkout_started", properties: ["channel": .string("promo")])
        XCTAssertEqual(plain?.properties?["app_release"], .string("1.2.0"))
        XCTAssertEqual(plain?.properties?["channel"], .string("promo"))
        XCTAssertNil(plain?.properties?["region"])
        let profile = try await client.setUserProperties(["plan": .string("pro")])
        XCTAssertEqual(profile?.properties, ["plan": .string("pro")])
        let group = try await client.group("acme")
        XCTAssertEqual(group?.properties, ["group_id": .string("acme")])
        await client.reset()
        let after = try await client.track("after_reset")
        XCTAssertNil(after?.properties?["app_release"])
    }

    func testGlobalTotalCappedAtFiftyAndClear() async throws {
        let client = try makeClient(transport: FakeTransport())
        var first: [String: FeralinValue] = [:]
        var second: [String: FeralinValue] = [:]
        for index in 0..<40 {
            first["a\(index)"] = .int(Int64(index))
            second["b\(index)"] = .int(Int64(index))
        }
        await client.setGlobalProperties(first)
        let dropped = await client.setGlobalProperties(second)
        XCTAssertEqual(dropped, 30)
        let event = try await client.track("page_view")
        XCTAssertEqual(event?.properties?.count, ProfileRules.maxProperties)
        await client.clearGlobalProperties()
        let cleared = try await client.track("page_view")
        XCTAssertNil(cleared?.properties)
    }
}
