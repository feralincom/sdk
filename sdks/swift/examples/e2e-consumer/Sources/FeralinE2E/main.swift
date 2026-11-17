// Gerçek services/collect tüketicisi: scripts/sdk-e2e/run.mjs ios-swift tarafından çalıştırılır.
// Denetim satırları sdks/android/scripts/outbox_check.go ile PostgreSQL üzerinde doğrulanır.
import Feralin
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let environment = ProcessInfo.processInfo.environment
guard let collectURL = environment["FERALIN_E2E_COLLECT_URL"],
      let projectKey = environment["FERALIN_E2E_PROJECT_KEY"],
      let checksPath = environment["FERALIN_E2E_CHECKS"] else {
    fatalError("KALDI: FERALIN_E2E_* ortamı eksik")
}

func must(_ condition: Bool, _ message: String) {
    if !condition {
        print("KALDI: \(message)")
        exit(1)
    }
}

func expect(_ line: String) throws {
    let data = Data((line + "\n").utf8)
    if !FileManager.default.fileExists(atPath: checksPath) {
        FileManager.default.createFile(atPath: checksPath, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: checksPath))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

func make(key: String = projectKey, consent: Consent = Consent(), transport: (any Transport)? = nil) throws -> FeralinClient {
    try FeralinClient(
        configuration: .init(projectKey: key, collectURL: collectURL, consent: consent, flushInterval: 0),
        transport: transport,
        installIDStore: InMemoryInstallIDStore(),
        // Komut satırı sürecinde ATT sorulamaz; macOS notDetermined verir ve fr_click senaryosu sınanamazdı.
        trackingStatusProvider: { .authorized }
    )
}

/// İlk yanıtı kaybeden taşıma: sunucu yazar ama istemci yanıtı görmez.
final class LossyTransport: Transport, @unchecked Sendable {
    private let inner = URLSessionTransport()
    private let lock = NSLock()
    private var keys: [String] = []

    var seenKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }

    private func record(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        keys.append(key)
        return keys.count
    }

    func send(_ request: TransportRequest) async throws -> TransportResponse {
        let attempt = record(request.headers["Idempotency-Key"] ?? "")
        let response = try await inner.send(request)
        if attempt == 1 { throw TransportError(message: "yanıt yolda kayboldu") }
        return response
    }
}

// 202 + outbox satırı + fr_click reklam izniyle
var client = try make(consent: Consent(analytics: true, advertising: true))
let first = try await client.track("order_completed", properties: ["order_id": "ord_swift_1", "fr_click": "clk_swift_1"], userID: "user_swift_1")
var result = try await client.flush()
must(first != nil && result.status == 202 && result.accepted == 1, "202 bekleniyordu")
try expect("frclick \(result.batchID ?? "")")
try expect("once \(first?.eventID ?? "")")
print("  OK 202-outbox-frclick: \(result.status) \(result.batchID ?? "")")

// Reklam izni yok: fr_click çıkarılır
client = try make(consent: Consent(analytics: true))
let second = try await client.track("order_completed", properties: ["order_id": "ord_swift_2", "fr_click": "clk_swift_2"])
must(second != nil && second?.properties?["fr_click"] == nil, "fr_click çıkarılmalıydı")
result = try await client.flush()
must(result.status == 202, "202 bekleniyordu")
try expect("nofrclick \(result.batchID ?? "")")
print("  OK frclick-izinsiz-cikarildi: \(result.status)")

// İzinsiz: SDK olay üretmez
client = try make()
let denied = try await client.track("order_completed")
result = try await client.flush()
must(denied == nil && result.sent == 0, "izinsiz olay üretilmemeliydi")
print("  OK izinsiz-sdk-uretmez: 0")

// İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
let stamp = String(UInt64(Date().timeIntervalSince1970 * 1_000_000))
let rawID = String(("01JCSW" + String(repeating: "0", count: 20 - min(20, stamp.count)) + stamp).prefix(26))
let occurred = ISO8601DateFormatter().string(from: Date())
let rawBody = "{\"events\":[{\"event_id\":\"\(rawID)\",\"event_name\":\"denied_event\",\"occurred_at\":\"\(occurred)\",\"platform\":\"other\",\"schema_version\":1,\"consent\":{\"analytics\":false}}]}"

/// Ham POST: SDK kuyruğunu atlar, yalnız toplayıcının izinsiz olayı reddettiğini sınar.
func rawPost(url: URL, body: String, key: String, idempotencyKey: String) async throws -> (status: Int, json: [String: Any]) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "X-Feralin-Project-Key")
    request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
    let (status, data): (Int, Data) = try await withCheckedThrowingContinuation { continuation in
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
        }.resume()
    }
    let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return (status, parsed)
}

let (rawStatus, rawResponse) = try await rawPost(
    url: URL(string: collectURL + "/v1/batch")!,
    body: rawBody,
    key: projectKey,
    idempotencyKey: FeralinClient.idempotencyKey(for: [rawID])
)
let reasons = rawResponse["rejected_reasons"] as? [String: Any]
must(rawStatus == 202 && rawResponse["accepted"] as? Int == 0 && reasons?["consent_denied"] as? Int == 1, "toplayıcı izinsiz olayı reddetmeliydi")
try expect("absent \(rawID)")
print("  OK izinsiz-toplayici-red")

// Yanlış anahtar: 401, olay atılır, uygulama düşmez
client = try make(key: "pk_test_wrong_key_000", consent: Consent(analytics: true))
let wrong = try await client.track("order_completed", properties: ["order_id": "ord_swift_wrong"])
result = try await client.flush()
var isRejected = false
if case .rejected(401, _)? = result.error { isRejected = true }
let leftover = await client.queuedCount
must(isRejected && result.rejected == 1 && leftover == 0, "401 bekleniyordu")
try expect("absent \(wrong?.eventID ?? "")")
print("  OK yanlis-anahtar-401: \(result.status)")

// Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
let lossy = LossyTransport()
client = try make(consent: Consent(analytics: true), transport: lossy)
let retried = try await client.track("order_completed", properties: ["order_id": "ord_swift_retry"])
let lost = try await client.flush()
let retainedAfterLoss = await client.queuedCount
must(!lost.ok && retainedAfterLoss == 1, "yanıt kaybı kuyrukta tutulmalıydı")
let following = try await client.track("order_shipped", properties: ["order_id": "ord_swift_retry"])
result = try await client.flush()
let retainedAfterRetry = await client.queuedCount
must(result.ok && result.status == 202 && retainedAfterRetry == 0, "tekrar 202 vermeliydi")
let keys = lossy.seenKeys
must(keys.count == 3 && keys[0] == keys[1], "aynı anahtar bekleniyordu")
try expect("once \(retried?.eventID ?? "")")
try expect("once \(following?.eventID ?? "")")
print("  OK idempotency-tekrar: \(keys[0])")

print("swift tüketici: tüm senaryolar geçti")
