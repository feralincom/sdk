import Foundation
import XCTest
@testable import Feralin

let testKey = "pk_test_swift_0001"
let testCollect = "https://collect.example.test"

/// Sahte toplayıcı: gelen istekleri kaydeder, sıradaki yanıtı ya da hatayı döner; sıra bitince 202.
final class FakeTransport: Transport, @unchecked Sendable {
    enum Step {
        case respond(Int, String, [String: String])
        case fail(String)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var requests: [TransportRequest] = []
    /// Yanıttan önce çağrılır; sürerken izin geri çekme gibi durumları sınamak için.
    var beforeResponse: (@Sendable () async -> Void)?

    init(_ steps: [Step] = []) {
        self.steps = steps
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func request(_ index: Int) -> TransportRequest {
        lock.lock()
        defer { lock.unlock() }
        return requests[index]
    }

    func body(_ index: Int) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: request(index).body)
        return try XCTUnwrap(object as? [String: Any])
    }

    func events(_ index: Int) throws -> [[String: Any]] {
        try XCTUnwrap(try body(index)["events"] as? [[String: Any]])
    }

    func eventIDs(_ index: Int) throws -> [String] {
        try events(index).compactMap { $0["event_id"] as? String }
    }

    private func next(_ request: TransportRequest) -> (Step?, Int) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let step = steps.isEmpty ? nil : steps.removeFirst()
        return (step, requests.count)
    }

    func send(_ request: TransportRequest) async throws -> TransportResponse {
        let (step, _) = next(request)
        if let beforeResponse { await beforeResponse() }
        switch step {
        case .respond(let status, let body, let headers):
            return TransportResponse(status: status, body: Data(body.utf8), headers: headers)
        case .fail(let message):
            throw TransportError(message: message)
        case nil:
            let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            let events = object?["events"] as? [[String: Any]] ?? []
            let payload = "{\"accepted\":\(events.count),\"rejected\":0,\"batch_id\":\"01TESTBATCH0000000000000000\"}"
            return TransportResponse(status: 202, body: Data(payload.utf8))
        }
    }
}

func makeClient(
    transport: FakeTransport,
    consent: Consent = Consent(analytics: true),
    flushInterval: TimeInterval = 0,
    batchSize: Int = FeralinClient.defaultBatchSize,
    queueLimit: Int = FeralinClient.defaultQueueLimit,
    attribution: AttributionConfiguration? = nil,
    platform: String? = nil,
    store: any InstallIDStore = InMemoryInstallIDStore(),
    now: @escaping @Sendable () -> Date = { Date() },
    tokenProvider: @escaping @Sendable () -> AdServicesTokenResult = { .notSupported },
    conversionUpdater: @escaping @Sendable (Int, CoarseConversionLevel, Bool, ConversionFrameworks) async -> ConversionUpdateResult = { _, _, _, _ in
        ConversionUpdateResult(adAttributionKit: .called, skAdNetwork: .called)
    },
    trackingStatus: @escaping @Sendable () -> TrackingAuthorizationStatus = { .authorized },
    storageDirectory: URL? = nil,
    sessionTimeout: TimeInterval = FeralinClient.defaultSessionTimeout,
    installCode: String? = nil
) throws -> FeralinClient {
    var configuration = FeralinClient.Configuration(
        projectKey: testKey,
        collectURL: testCollect,
        consent: consent,
        flushInterval: flushInterval,
        batchSize: batchSize,
        queueLimit: queueLimit,
        attribution: attribution,
        storageDirectory: storageDirectory,
        sessionTimeout: sessionTimeout,
        installCode: installCode
    )
    configuration.platformOverride = platform
    return try FeralinClient(
        configuration: configuration,
        transport: transport,
        installIDStore: store,
        now: now,
        adServicesTokenProvider: tokenProvider,
        conversionUpdater: conversionUpdater,
        trackingStatusProvider: trackingStatus
    )
}

func assertInvalidEvent(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("InvalidEvent bekleniyordu", file: file, line: line)
    } catch let error as FeralinError {
        guard case .invalidEvent = error else {
            XCTFail("InvalidEvent bekleniyordu: \(error)", file: file, line: line)
            return
        }
    } catch {
        XCTFail("beklenmeyen hata: \(error)", file: file, line: line)
    }
}
