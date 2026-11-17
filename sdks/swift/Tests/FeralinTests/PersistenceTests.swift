import Foundation
import XCTest
@testable import Feralin

/// Elle ilerletilen sahte saat; oturum eşiğini gerçek beklemeden sınamak için.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_793_703_600)) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

final class PersistenceTests: XCTestCase {
    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feralin-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// `track` sonucunu açar; `XCTUnwrap` otomatik kapanışında `await` kullanılamadığından ayrı tutulur.
    private func tracked(_ client: FeralinClient, _ name: String, sessionID: String? = nil) async throws -> TrackedEvent {
        let event = try await client.track(name, sessionID: sessionID)
        return try XCTUnwrap(event)
    }

    private func queueFileExists(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(FeralinDiskStore.queueFileName).path)
    }

    private func persistedClient(
        _ directory: URL,
        transport: FakeTransport = FakeTransport(),
        consent: Consent = Consent(analytics: true),
        queueLimit: Int = FeralinClient.defaultQueueLimit,
        clock: TestClock = TestClock(),
        sessionTimeout: TimeInterval = FeralinClient.defaultSessionTimeout
    ) throws -> FeralinClient {
        try makeClient(
            transport: transport,
            consent: consent,
            queueLimit: queueLimit,
            now: { clock.now() },
            storageDirectory: directory,
            sessionTimeout: sessionTimeout
        )
    }

    // MARK: - Kalıcı kuyruk

    func testQueueRestoredAfterRestart() async throws {
        let directory = makeDirectory()
        let first = try persistedClient(directory)
        let a = try await tracked(first, "a")
        let b = try await tracked(first, "b")

        // "Süreç ölümü": ilk istemci hiç flush edilmeden bırakılır, aynı dizinle yenisi açılır.
        let transport = FakeTransport()
        let second = try persistedClient(directory, transport: transport)
        let restored = await second.queuedCount
        XCTAssertEqual(restored, 2)

        let result = try await second.flush()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(try transport.eventIDs(0), [a.eventID, b.eventID])
        XCTAssertEqual(transport.request(0).headers["Idempotency-Key"], Wire.idempotencyKey(for: [a.eventID, b.eventID]))
        let after = await second.queuedCount
        XCTAssertEqual(after, 0)
    }

    func testNoFileOnFirstLaunchStartsEmpty() async throws {
        let directory = makeDirectory()
        let client = try persistedClient(directory)
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 0)
        XCTAssertFalse(queueFileExists(directory))
    }

    func testAcceptedBatchRemovedFromDisk() async throws {
        let directory = makeDirectory()
        let client = try persistedClient(directory)
        try await client.track("a")
        XCTAssertTrue(queueFileExists(directory))
        let result = try await client.flush()
        XCTAssertTrue(result.ok)
        XCTAssertFalse(queueFileExists(directory), "202 sonrası kuyruk dosyası silinmeli")
    }

    func testServerErrorKeepsEventsOnDisk() async throws {
        let directory = makeDirectory()
        let transport = FakeTransport([
            .respond(503, "{}", [:]),
            .fail("bağlantı koptu"),
        ])
        let client = try persistedClient(directory, transport: transport)
        let event = try await tracked(client, "a")

        var result = try await client.flush()
        guard case .temporary(503, _)? = result.error else { return XCTFail("503 bekleniyordu") }
        XCTAssertEqual(FeralinDiskStore(directory: directory).loadQueue(limit: 100).map(\.id), [event.eventID])

        result = try await client.flush()
        guard case .temporary(0, _)? = result.error else { return XCTFail("ağ hatası bekleniyordu") }
        XCTAssertEqual(FeralinDiskStore(directory: directory).loadQueue(limit: 100).map(\.id), [event.eventID])

        // Yeniden başlatma sonrası da aynı olay 2xx gelene kadar kuyrukta.
        let retry = FakeTransport()
        let restarted = try persistedClient(directory, transport: retry)
        result = try await restarted.flush()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(try retry.eventIDs(0), [event.eventID])
        XCTAssertFalse(queueFileExists(directory))
    }

    func testPermanentRejectionRemovesFromDisk() async throws {
        let directory = makeDirectory()
        let transport = FakeTransport([.respond(400, "{\"title\":\"geçersiz\"}", [:])])
        let client = try persistedClient(directory, transport: transport)
        try await client.track("a")
        let result = try await client.flush()
        guard case .rejected(400, _)? = result.error else { return XCTFail("400 bekleniyordu") }
        XCTAssertFalse(queueFileExists(directory), "kalıcı red sonrası olay yeniden gönderilmemeli")
    }

    func testCorruptQueueFileIsResetWithoutCrash() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(FeralinDiskStore.queueFileName)
        try Data("{bozuk json".utf8).write(to: url)

        let client = try persistedClient(directory)
        var queued = await client.queuedCount
        XCTAssertEqual(queued, 0)
        XCTAssertFalse(queueFileExists(directory), "bozuk dosya sıfırlanmalı")

        // İstemci bozuk dosyadan sonra normal çalışır.
        try await client.track("a")
        queued = await client.queuedCount
        XCTAssertEqual(queued, 1)
        XCTAssertTrue(queueFileExists(directory))
    }

    func testUnknownFormatVersionIsReset() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(FeralinDiskStore.queueFileName)
        try Data(#"{"version":99,"events":[{"id":"01A","raw":"{}"}]}"#.utf8).write(to: url)

        let client = try persistedClient(directory)
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 0)
    }

    func testInvalidRowsAreDropped() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(FeralinDiskStore.queueFileName)
        let content = #"{"version":1,"events":[{"id":"01A","raw":"{\"event_id\":\"01A\"}"},{"id":"01B","raw":"json degil"},{"id":"","raw":"{}"},{"id":"01A","raw":"{\"event_id\":\"01A\"}"}]}"#
        try Data(content.utf8).write(to: url)

        let client = try persistedClient(directory)
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 1, "yalnız geçerli ve tekil satır kalmalı")
    }

    func testPersistentQueueLimitDropsOldest() async throws {
        let directory = makeDirectory()
        let first = try persistedClient(directory, queueLimit: 3)
        var ids: [String] = []
        for _ in 0..<5 {
            let event = try await tracked(first, "e")
            ids.append(event.eventID)
        }
        XCTAssertEqual(FeralinDiskStore(directory: directory).loadQueue(limit: 100).map(\.id), Array(ids[2...]))

        // Yeniden başlatmada daha küçük bir sınır verilirse en yeniler kalır.
        let transport = FakeTransport()
        let second = try persistedClient(directory, transport: transport, queueLimit: 2)
        let queued = await second.queuedCount
        XCTAssertEqual(queued, 2)
        _ = try await second.flush()
        XCTAssertEqual(try transport.eventIDs(0), Array(ids[3...]))
    }

    func testAnalyticsOffAtLaunchClearsPersistedData() async throws {
        let directory = makeDirectory()
        let first = try persistedClient(directory)
        try await first.track("a")
        XCTAssertTrue(queueFileExists(directory))

        let second = try persistedClient(directory, consent: Consent(analytics: false))
        let queued = await second.queuedCount
        XCTAssertEqual(queued, 0)
        XCTAssertFalse(queueFileExists(directory))
        XCTAssertNil(FeralinDiskStore(directory: directory).loadSession())
    }

    func testRevokingConsentClearsDisk() async throws {
        let directory = makeDirectory()
        let client = try persistedClient(directory)
        try await client.track("a")
        XCTAssertTrue(queueFileExists(directory))
        await client.setConsent(Consent(analytics: false))
        XCTAssertFalse(queueFileExists(directory))
        XCTAssertNil(FeralinDiskStore(directory: directory).loadSession())
    }

    func testWithoutStorageDirectoryNothingIsPersisted() async throws {
        let configuration = FeralinClient.Configuration(projectKey: testKey, collectURL: testCollect)
        XCTAssertNil(configuration.storageDirectory)
        XCTAssertEqual(configuration.sessionTimeout, 1800)

        let transport = FakeTransport()
        let first = try makeClient(transport: transport)
        try await first.track("a")
        let second = try makeClient(transport: transport)
        let queued = await second.queuedCount
        XCTAssertEqual(queued, 0, "dizin verilmeyen istemcide kuyruk yalnız bellektedir")
    }

    // MARK: - Oturum

    func testSessionIDIsAddedToEvents() async throws {
        let client = try makeClient(transport: FakeTransport())
        let current = await client.currentSessionID
        XCTAssertTrue(isULID(current))
        let event = try await tracked(client, "a")
        XCTAssertEqual(event.sessionID, current)
    }

    func testExplicitSessionIDWinsWithoutChangingAutomaticSession() async throws {
        let client = try makeClient(transport: FakeTransport())
        let before = await client.currentSessionID
        let event = try await tracked(client, "a", sessionID: "ses_manual")
        XCTAssertEqual(event.sessionID, "ses_manual")
        let after = await client.currentSessionID
        XCTAssertEqual(after, before)
    }

    func testSessionKeptBelowThirtyMinutes() async throws {
        let clock = TestClock()
        let client = try makeClient(transport: FakeTransport(), now: { clock.now() })
        let first = try await tracked(client, "a")
        clock.advance(29 * 60 + 59)
        let second = try await tracked(client, "b")
        XCTAssertEqual(second.sessionID, first.sessionID)
        // Etkinlik süreyi sıfırlar: son olaydan 29:59 sonra yine aynı oturum.
        clock.advance(29 * 60 + 59)
        let third = try await tracked(client, "c")
        XCTAssertEqual(third.sessionID, first.sessionID)
    }

    func testSessionRenewedAtThirtyMinutes() async throws {
        let clock = TestClock()
        let client = try makeClient(transport: FakeTransport(), now: { clock.now() })
        let first = try await tracked(client, "a")
        clock.advance(30 * 60)
        let second = try await tracked(client, "b")
        XCTAssertNotEqual(second.sessionID, first.sessionID)
        XCTAssertTrue(isULID(try XCTUnwrap(second.sessionID)))
        // Yeni oturum eşik altında korunur.
        clock.advance(60)
        let third = try await tracked(client, "c")
        XCTAssertEqual(third.sessionID, second.sessionID)
    }

    func testForegroundChecksSessionTimeout() async throws {
        let clock = TestClock()
        let client = try makeClient(transport: FakeTransport(), now: { clock.now() })
        let initial = await client.currentSessionID

        await client.didEnterBackground()
        clock.advance(10 * 60)
        await client.willEnterForeground()
        var current = await client.currentSessionID
        XCTAssertEqual(current, initial, "10 dk arka plan oturumu bitirmemeli")

        await client.didEnterBackground()
        clock.advance(31 * 60)
        await client.willEnterForeground()
        current = await client.currentSessionID
        XCTAssertNotEqual(current, initial, "31 dk arka plan sonrası yeni oturum başlamalı")
    }

    func testCustomSessionTimeout() async throws {
        let clock = TestClock()
        let client = try makeClient(transport: FakeTransport(), now: { clock.now() }, sessionTimeout: 60)
        let first = try await tracked(client, "a")
        clock.advance(59)
        let second = try await tracked(client, "b")
        XCTAssertEqual(second.sessionID, first.sessionID)
        clock.advance(60)
        let third = try await tracked(client, "c")
        XCTAssertNotEqual(third.sessionID, first.sessionID)
    }

    func testSessionSurvivesRestartWithinThirtyMinutes() async throws {
        let directory = makeDirectory()
        let clock = TestClock()
        let first = try persistedClient(directory, clock: clock)
        let event = try await tracked(first, "a")

        clock.advance(10 * 60)
        let second = try persistedClient(directory, clock: clock)
        let resumed = await second.currentSessionID
        XCTAssertEqual(resumed, event.sessionID, "süreç yeniden başlasa da 30 dk içinde oturum sürmeli")
    }

    func testSessionRenewedAfterRestartPastThirtyMinutes() async throws {
        let directory = makeDirectory()
        let clock = TestClock()
        let first = try persistedClient(directory, clock: clock)
        let event = try await tracked(first, "a")

        clock.advance(31 * 60)
        let second = try persistedClient(directory, clock: clock)
        let renewed = await second.currentSessionID
        XCTAssertNotEqual(renewed, event.sessionID, "30 dk sonra yeniden başlatma yeni oturum açmalı")
        XCTAssertTrue(isULID(renewed))
    }

    func testCorruptSessionFileStartsNewSession() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(FeralinDiskStore.sessionFileName)
        try Data("çöp".utf8).write(to: url)

        let client = try persistedClient(directory)
        let current = await client.currentSessionID
        XCTAssertTrue(isULID(current))
    }

    func testResetStartsNewSession() async throws {
        let client = try makeClient(transport: FakeTransport())
        let before = await client.currentSessionID
        await client.reset()
        let after = await client.currentSessionID
        XCTAssertNotEqual(before, after)
    }

    func testRejectsNonPositiveSessionTimeout() {
        XCTAssertThrowsError(try makeClient(transport: FakeTransport(), sessionTimeout: 0)) { error in
            guard let feralin = error as? FeralinError, case .configuration = feralin else {
                XCTFail("yapılandırma hatası bekleniyordu: \(error)")
                return
            }
        }
    }
}
