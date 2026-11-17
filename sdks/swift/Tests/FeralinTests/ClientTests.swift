import Foundation
import XCTest
@testable import Feralin

final class ClientTests: XCTestCase {
    private func assertConfigurationError(key: String, collect: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try FeralinClient(configuration: .init(projectKey: key, collectURL: collect), transport: FakeTransport()), file: file, line: line) { error in
            guard let feralin = error as? FeralinError, case .configuration = feralin else {
                XCTFail("yapılandırma hatası bekleniyordu: \(error)", file: file, line: line)
                return
            }
        }
    }

    func testRejectsSecretAndNonPublicKeys() {
        assertConfigurationError(key: "sk_live_abcdefgh", collect: testCollect)
        assertConfigurationError(key: "dev_key_change_me_0001", collect: testCollect)
        assertConfigurationError(key: "", collect: testCollect)
    }

    func testRejectsBadCollectURL() {
        assertConfigurationError(key: testKey, collect: "collect.example.test")
        assertConfigurationError(key: testKey, collect: "ftp://collect.example.test")
    }

    func testEndpointBuiltFromRootAndStatusHasNoKey() async throws {
        let client = try FeralinClient(
            configuration: .init(projectKey: testKey, collectURL: "https://collect.example.test/", flushInterval: 0),
            transport: FakeTransport(),
            installIDStore: InMemoryInstallIDStore()
        )
        let status = await client.status()
        XCTAssertEqual(status.endpoint, "https://collect.example.test/v1/batch")
        XCTAssertFalse(String(describing: status).contains("pk_"))
    }

    func testTrackFlushAccepted() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport)
        try await client.identify("user_42")
        let tracked = try await client.track(
            "order_completed",
            properties: ["order_id": "ord_1", "amount": 12.5, "items": 2],
            anonymousID: "anon_1",
            sessionID: "ses_1",
            context: Context(locale: "tr-TR", timezone: "Europe/Istanbul", app: AppInfo(version: "1.2.3"))
        )
        let event = try XCTUnwrap(tracked)
        XCTAssertEqual(event.userID, "user_42")
        let queuedBefore = await client.queuedCount
        XCTAssertEqual(queuedBefore, 1)

        let result = try await client.flush()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.status, 202)
        XCTAssertEqual(result.sent, 1)
        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(result.rejected, 0)
        XCTAssertEqual(result.batchID, "01TESTBATCH0000000000000000")
        let queuedAfter = await client.queuedCount
        XCTAssertEqual(queuedAfter, 0)
        XCTAssertEqual(transport.count, 1)

        let request = transport.request(0)
        XCTAssertEqual(request.url.absoluteString, "https://collect.example.test/v1/batch")
        XCTAssertEqual(request.headers["X-Feralin-Project-Key"], testKey)
        XCTAssertEqual(request.headers["Idempotency-Key"], Wire.idempotencyKey(for: [event.eventID]))
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertNil(request.headers["Authorization"])

        let body = try transport.body(0)
        XCTAssertNotNil(body["sent_at"] as? String)
        let wire = try XCTUnwrap(transport.events(0).first)
        XCTAssertEqual(wire["event_id"] as? String, event.eventID)
        XCTAssertTrue(isULID(try XCTUnwrap(wire["event_id"] as? String)))
        XCTAssertEqual(wire["event_name"] as? String, "order_completed")
        XCTAssertEqual(wire["schema_version"] as? Int, 1)
        XCTAssertEqual(wire["user_id"] as? String, "user_42")
        XCTAssertEqual(wire["anonymous_id"] as? String, "anon_1")
        XCTAssertEqual(wire["session_id"] as? String, "ses_1")
        for forbidden in ["tenant_id", "project_id", "verified", "source_ip", "ip", "idfa", "idfv"] {
            XCTAssertNil(wire[forbidden], "istemciden gönderilmemeli: \(forbidden)")
        }
        let properties = try XCTUnwrap(wire["properties"] as? [String: Any])
        XCTAssertEqual(properties["order_id"] as? String, "ord_1")
        XCTAssertEqual(properties["amount"] as? Double, 12.5)
        XCTAssertEqual(properties["items"] as? Int, 2)
        let context = try XCTUnwrap(wire["context"] as? [String: Any])
        XCTAssertEqual(context["locale"] as? String, "tr-TR")
        XCTAssertEqual((context["app"] as? [String: Any])?["version"] as? String, "1.2.3")
        let sdk = try XCTUnwrap(wire["sdk"] as? [String: Any])
        XCTAssertEqual(sdk["name"] as? String, "feralin-swift")
        let consent = try XCTUnwrap(wire["consent"] as? [String: Any])
        XCTAssertEqual(consent["analytics"] as? Bool, true)
        XCTAssertEqual(consent["advertising"] as? Bool, false)
    }

    func testIdempotencyKeyMatchesOtherSDKs() {
        XCTAssertEqual(Wire.idempotencyKey(for: ["01JC0000000000000000000002", "01JC0000000000000000000001"]), "8f95d6b736d56c98-2")
    }

    func testTemporaryFailureKeepsQueueAndIdempotencyKey() async throws {
        let transport = FakeTransport([
            .respond(503, "{\"title\":\"Outbox yazılamadı\"}", ["Retry-After": "5"]),
            .respond(429, "{\"title\":\"Çok fazla istek\"}", ["retry-after": "1"]),
        ])
        let client = try makeClient(transport: transport)
        let tracked = try await client.track("signup")
        let event = try XCTUnwrap(tracked)

        var result = try await client.flush()
        guard case .temporary(503, _)? = result.error else { return XCTFail("503 bekleniyordu") }
        XCTAssertEqual(result.retained, 1)
        var status = await client.status()
        XCTAssertEqual(status.backoff, 5)

        result = try await client.flush()
        guard case .temporary(429, _)? = result.error else { return XCTFail("429 bekleniyordu") }
        status = await client.status()
        XCTAssertEqual(status.backoff, 10)
        XCTAssertEqual(status.queued, 1)

        result = try await client.flush()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.status, 202)
        status = await client.status()
        XCTAssertEqual(status.backoff, 0)
        XCTAssertEqual(status.queued, 0)

        XCTAssertEqual(transport.count, 3)
        let expected = Wire.idempotencyKey(for: [event.eventID])
        for index in 0..<3 {
            XCTAssertEqual(transport.request(index).headers["Idempotency-Key"], expected)
        }
    }

    func testBackoffCapsAtThirtySeconds() async throws {
        let transport = FakeTransport(Array(repeating: .respond(503, "{}", [:]), count: 7))
        let client = try makeClient(transport: transport)
        try await client.track("signup")
        var seen: [TimeInterval] = []
        for _ in 0..<7 {
            _ = try await client.flush()
            seen.append(await client.status().backoff)
        }
        XCTAssertEqual(seen, [1, 2, 4, 8, 16, 30, 30])
    }

    func testFrClickRequiresAdvertisingConsent() async throws {
        let client = try makeClient(transport: FakeTransport())
        var event = try await client.track("order_completed", properties: ["fr_click": "clk", "order_id": "o1"])
        XCTAssertEqual(event?.properties, ["order_id": "o1"])
        event = try await client.track("order_completed", properties: ["fr_click": "clk"])
        XCTAssertNil(event?.properties, "tek özellik çıkarılınca properties gönderilmez")
        await client.setConsent(Consent(analytics: true, advertising: true))
        event = try await client.track("order_completed", properties: ["fr_click": "clk"])
        XCTAssertEqual(event?.properties?["fr_click"], .string("clk"))
    }

    func testPinnedBatchKeepsContentAcrossRetries() async throws {
        let transport = FakeTransport([.fail("yanıt yolda kayboldu")])
        let client = try makeClient(transport: transport)
        let firstEvent = try await client.track("first_event")
        let first = try XCTUnwrap(firstEvent)
        let lost = try await client.flush()
        XCTAssertFalse(lost.ok)
        let secondEvent = try await client.track("second_event")
        let second = try XCTUnwrap(secondEvent)
        let result = try await client.flush()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(transport.count, 3)
        let key = Wire.idempotencyKey(for: [first.eventID])
        XCTAssertEqual(transport.request(0).headers["Idempotency-Key"], key)
        XCTAssertEqual(transport.request(1).headers["Idempotency-Key"], key)
        XCTAssertEqual(transport.request(2).headers["Idempotency-Key"], Wire.idempotencyKey(for: [second.eventID]))
    }

    func testNetworkErrorKeepsQueue() async throws {
        let transport = FakeTransport([.fail("ağ hatası: bağlantı yok")])
        let client = try makeClient(transport: transport)
        try await client.track("ping")
        let result = try await client.flush()
        XCTAssertEqual(result.error, .temporary(status: 0, message: "ağ hatası: bağlantı yok"))
        let status = await client.status()
        XCTAssertEqual(status.queued, 1)
        XCTAssertEqual(status.backoff, 1)
    }

    func testPermanentRejectionDropsEvents() async throws {
        let transport = FakeTransport([.respond(401, "{\"title\":\"Geçersiz anahtar\",\"detail\":\"x\"}", [:])])
        let client = try makeClient(transport: transport)
        try await client.track("order_completed")
        let result = try await client.flush()
        XCTAssertEqual(result.error, .rejected(status: 401, detail: "Geçersiz anahtar x"))
        XCTAssertEqual(result.rejected, 1)
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 0)
        let again = try await client.flush()
        XCTAssertTrue(again.ok)
        XCTAssertEqual(transport.count, 1, "atılan olay yeniden gönderilmemeli")
    }

    func testConsentGate() async throws {
        let transport = FakeTransport()
        let store = InMemoryInstallIDStore()
        let client = try makeClient(transport: transport, consent: Consent(), store: store)
        let denied = try await client.track("page_view")
        XCTAssertNil(denied)
        XCTAssertNil(store.load(), "izinsiz kimlik diske yazılmamalı")

        await client.setConsent(Consent(analytics: true))
        let allowed = try await client.track("page_view")
        XCTAssertEqual(allowed?.consent, Consent(analytics: true))
        XCTAssertNotNil(store.load())
        XCTAssertEqual(allowed?.anonymousID, store.load())

        await client.setConsent(Consent())
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 0, "izin geri çekilince kuyruk temizlenmeli")
        XCTAssertNil(store.load(), "izin geri çekilince kurulum kimliği silinmeli")
        let result = try await client.flush()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(transport.count, 0, "izin yokken sunucuya istek gitmemeli")
    }

    func testConsentWithdrawnDuringRequestDoesNotPin() async throws {
        let transport = FakeTransport([.respond(503, "{}", [:])])
        let client = try makeClient(transport: transport)
        transport.beforeResponse = { await client.setConsent(Consent()) }
        try await client.track("e")
        let result = try await client.flush()
        XCTAssertFalse(result.ok)
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 0)
        transport.beforeResponse = nil
        let next = try await client.flush()
        XCTAssertEqual(next.sent, 0)
        XCTAssertEqual(transport.count, 1)
    }

    func testValidation() async throws {
        let client = try makeClient(transport: FakeTransport())
        for name in ["", "orderCompleted", "1_event", String(repeating: "a", count: 101), "has-dash"] {
            await assertInvalidEvent { _ = try await client.track(name) }
        }
        await assertInvalidEvent { _ = try await client.track("ok", properties: ["1bad": 1]) }
        await assertInvalidEvent { _ = try await client.track("ok", properties: ["bad-key": 1]) }
        await assertInvalidEvent { _ = try await client.track("ok", properties: ["a" + String(repeating: "b", count: 64): 1]) }
        var tooMany: [String: FeralinValue] = [:]
        for index in 0..<101 { tooMany["k\(index)"] = .int(Int64(index)) }
        await assertInvalidEvent { [tooMany] in _ = try await client.track("ok", properties: tooMany) }
        await assertInvalidEvent { _ = try await client.track("ok", userID: String(repeating: "u", count: 129)) }
        await assertInvalidEvent { _ = try await client.track("ok", properties: ["nan": .double(.nan)]) }
        await assertInvalidEvent { try await client.identify(String(repeating: "u", count: 129)) }
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 0, "geçersiz olaylar kuyruğa girmemeli")

        tooMany.removeValue(forKey: "k100")
        let full = try await client.track("ok", properties: tooMany)
        XCTAssertNotNil(full)
        let system = try await client.track("fr_system_event_9", properties: ["Camel_Key9": "x"])
        XCTAssertNotNil(system)
    }

    func testQueueLimitDropsOldest() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, batchSize: 10, queueLimit: 3)
        var ids: [String] = []
        for _ in 0..<5 {
            let event = try await client.track("e")
            ids.append(try XCTUnwrap(event).eventID)
        }
        let status = await client.status()
        XCTAssertEqual(status.queued, 3)
        XCTAssertEqual(status.dropped, 2)
        let result = try await client.flush()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(try transport.eventIDs(0), Array(ids[2...]))
    }

    func testBatchSplitting() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, batchSize: 2, queueLimit: 100)
        for _ in 0..<5 { try await client.track("e") }
        let result = try await client.flush()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.sent, 5)
        XCTAssertEqual(result.accepted, 5)
        XCTAssertEqual(transport.count, 3)
        XCTAssertEqual(try transport.eventIDs(0).count, 2)
        XCTAssertEqual(transport.request(0).headers["Idempotency-Key"], Wire.idempotencyKey(for: try transport.eventIDs(0)))
        XCTAssertEqual(try transport.eventIDs(2).count, 1)
    }

    func testBackgroundFlush() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, flushInterval: 0.02)
        try await client.track("bg")
        let deadline = Date().addingTimeInterval(3)
        var queued = await client.queuedCount
        while queued > 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            queued = await client.queuedCount
        }
        XCTAssertEqual(queued, 0)
        XCTAssertGreaterThanOrEqual(transport.count, 1)
        await client.close(timeout: 1)
    }

    func testBackgroundFlushRespectsBackoff() async throws {
        let transport = FakeTransport([.respond(503, "{}", [:])])
        let client = try makeClient(transport: transport, flushInterval: 0.01)
        try await client.track("bg")
        let deadline = Date().addingTimeInterval(3)
        while transport.count == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(transport.count, 1, "geri çekilme sırasında yeniden deneme olmamalı")
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 1)
        await client.setConsent(Consent())
        await client.close(timeout: 1)
    }

    func testCloseFlushesAndBlocksTrack() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport)
        for _ in 0..<3 { try await client.track("e") }
        let result = await client.close()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(transport.count, 1)
        XCTAssertEqual(try transport.eventIDs(0).count, 3)
        let status = await client.status()
        XCTAssertTrue(status.closed)
        do {
            _ = try await client.track("late")
            XCTFail("kapalı istemci track kabul etmemeli")
        } catch let error as FeralinError {
            XCTAssertEqual(error, .clientClosed)
        }
        do {
            _ = try await client.flush()
            XCTFail("kapalı istemci flush kabul etmemeli")
        } catch let error as FeralinError {
            XCTAssertEqual(error, .clientClosed)
        }
        let again = await client.close()
        XCTAssertTrue(again.ok, "ikinci close hatasız olmalı")
    }

    func testCloseReportsUndelivered() async throws {
        let transport = FakeTransport([.respond(503, "{}", [:])])
        let client = try makeClient(transport: transport)
        try await client.track("e")
        let result = await client.close(timeout: 1)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.retained, 1)
    }

    func testConcurrentTrackAndFlushKeepsOrderAndUniqueness() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, batchSize: FeralinClient.maxBatchSize, queueLimit: 5000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<100 { try await client.track("c") }
                }
            }
            group.addTask { _ = try await client.flush() }
            try await group.waitForAll()
        }
        let final = try await client.flush()
        XCTAssertTrue(final.ok)
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 0)
        var seen = Set<String>()
        for index in 0..<transport.count {
            for id in try transport.eventIDs(index) {
                XCTAssertFalse(seen.contains(id))
                seen.insert(id)
            }
        }
        XCTAssertEqual(seen.count, 800)
    }

    func testOccurredAtUsesInjectedClock() async throws {
        let fixed = Date(timeIntervalSince1970: 1_793_703_600.123456) // 2026-11-03T11:00:00.123Z
        let client = try makeClient(transport: FakeTransport(), now: { fixed })
        var event = try await client.track("clock")
        XCTAssertEqual(event?.occurredAt, "2026-11-03T11:00:00.123Z")
        event = try await client.track("clock", occurredAt: Date(timeIntervalSince1970: 1_767_323_045)) // 2026-01-02T03:04:05Z
        XCTAssertEqual(event?.occurredAt, "2026-01-02T03:04:05.000Z")
    }

    func testResetChangesInstallIDAndUser() async throws {
        let store = InMemoryInstallIDStore()
        let client = try makeClient(transport: FakeTransport(), store: store)
        try await client.identify("user_1")
        let before = try await client.track("a")
        await client.reset()
        let after = try await client.track("b")
        XCTAssertEqual(before?.userID, "user_1")
        XCTAssertNil(after?.userID)
        XCTAssertNotEqual(before?.anonymousID, after?.anonymousID)
        XCTAssertEqual(store.load(), after?.anonymousID)
    }

    func testInstallIDReusedFromStore() async throws {
        let store = InMemoryInstallIDStore(value: "01JC00000000000000000STORE")
        let client = try makeClient(transport: FakeTransport(), store: store)
        let event = try await client.track("a")
        XCTAssertEqual(event?.anonymousID, "01JC00000000000000000STORE")
    }

    func testInstallCodeRidesOnFirstQueuedEventOnly() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, installCode: " ABCDE-FGHJK ")
        let first = try await client.track("app_open")
        XCTAssertEqual(first?.properties?["fr_install_code"], .string("ABCDE-FGHJK"))
        let second = try await client.track("app_open", properties: ["a": 1])
        XCTAssertNil(second?.properties?["fr_install_code"])
        _ = try await client.flush()
        let events = try transport.events(0)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual((events[0]["properties"] as? [String: Any])?["fr_install_code"] as? String, "ABCDE-FGHJK")
        XCTAssertNil((events[1]["properties"] as? [String: Any])?["fr_install_code"])
    }

    func testInstallCodeIgnoredWhenMalformedAndKeptUntilAnEventIsQueued() async throws {
        // Boş, kısa, uzun, izinsiz karakterli ve Crockford dışı harfli (I, L, O, U) kodlar yok sayılır.
        for bad in ["", "kisa", "ABCDE-FGHJK-MNPQR-STVWX", "ABCDE*FGHJK", "ILOU-ILOU-1"] {
            let client = try makeClient(transport: FakeTransport(), installCode: bad)
            let event = try await client.track("app_open")
            XCTAssertNotNil(event, bad)
            XCTAssertNil(event?.properties?["fr_install_code"], bad)
        }
        // İzin yokken olay üretilmez ve kod harcanmaz; izin gelince ilk olaya eklenir.
        let client = try makeClient(transport: FakeTransport(), consent: Consent(analytics: false), installCode: "ABCDE-FGHJK")
        let none = try await client.track("app_open")
        XCTAssertNil(none)
        await client.setConsent(Consent(analytics: true))
        let event = try await client.track("app_open")
        XCTAssertEqual(event?.properties?["fr_install_code"], .string("ABCDE-FGHJK"))
        // Geçersiz olay (doğrulamada düşer) kodu harcamaz.
        let other = try makeClient(transport: FakeTransport(), installCode: "ABCDE-FGHJK")
        do {
            _ = try await other.track("")
            XCTFail("boş olay adı reddedilmeliydi")
        } catch {}
        let kept = try await other.track("app_open")
        XCTAssertEqual(kept?.properties?["fr_install_code"], .string("ABCDE-FGHJK"))
    }
}
