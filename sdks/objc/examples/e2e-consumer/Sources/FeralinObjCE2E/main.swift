// Gerçek services/collect tüketicisi: scripts/sdk-e2e/run.mjs objc tarafından macOS üzerinde çalıştırılır.
// FRLFeralin köprüsünün @objc yüzeyi kullanılır; kurulum özel taşıma ve ATT durumu için Swift kurucusundan geçer.
import Feralin
import FeralinObjC
import Foundation

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

func make(key: String = projectKey, consent: FRLConsent = FRLConsent()) throws -> FRLFeralin {
    // Komut satırı sürecinde ATT sorulamaz; macOS notDetermined verir ve fr_click senaryosu sınanamazdı. Bu yüzden Swift kurucusu.
    let client = try FeralinClient(
        configuration: .init(
            projectKey: key,
            collectURL: collectURL,
            consent: Consent(analytics: consent.analytics, advertising: consent.advertising, personalization: consent.personalization, sessionReplay: consent.sessionReplay),
            flushInterval: 0,
            sdk: FRLFeralin.sdk
        ),
        installIDStore: InMemoryInstallIDStore(),
        trackingStatusProvider: { .authorized }
    )
    return FRLFeralin(client: client)
}

func track(_ bridge: FRLFeralin, _ name: String, _ properties: [String: Any]?) async -> String? {
    await withCheckedContinuation { continuation in
        bridge.track(name, properties: properties) { id, error in
            must(error == nil, "track hata verdi")
            continuation.resume(returning: id)
        }
    }
}

func flush(_ bridge: FRLFeralin) async -> FRLFlushResult {
    await withCheckedContinuation { continuation in
        bridge.flush { result, _ in
            guard let result else { fatalError("KALDI: kapalı istemci") }
            continuation.resume(returning: result)
        }
    }
}

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

let analyticsOnly = FRLConsent(analytics: true, advertising: false, personalization: false, sessionReplay: false)

// 202 + outbox satırı + fr_click reklam izniyle
var bridge = try make(consent: FRLConsent(analytics: true, advertising: true, personalization: false, sessionReplay: false))
let first = await track(bridge, "order_completed", ["order_id": "ord_objc_1", "fr_click": "clk_objc_1"])
var result = await flush(bridge)
must(first != nil && result.status == 202 && result.accepted == 1, "202 bekleniyordu")
try expect("frclick \(result.batchID ?? "")")
try expect("once \(first ?? "")")
print("  OK 202-outbox-frclick: \(result.status)")

// Reklam izni yok: fr_click çıkarılır
bridge = try make(consent: analyticsOnly)
_ = await track(bridge, "order_completed", ["order_id": "ord_objc_2", "fr_click": "clk_objc_2"])
result = await flush(bridge)
must(result.status == 202, "202 bekleniyordu")
try expect("nofrclick \(result.batchID ?? "")")
print("  OK frclick-izinsiz-cikarildi: \(result.status)")

// İzinsiz: SDK olay üretmez
bridge = try make()
let denied = await track(bridge, "order_completed", nil)
result = await flush(bridge)
must(denied == nil && result.sent == 0, "izinsiz olay üretilmemeliydi")
print("  OK izinsiz-sdk-uretmez: 0")

// İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
let stamp = String(UInt64(Date().timeIntervalSince1970 * 1_000_000))
let rawID = String(("01JCOC" + String(repeating: "0", count: 20 - min(20, stamp.count)) + stamp).prefix(26))
let occurred = ISO8601DateFormatter().string(from: Date())
let rawBody = "{\"events\":[{\"event_id\":\"\(rawID)\",\"event_name\":\"denied_event\",\"occurred_at\":\"\(occurred)\",\"platform\":\"other\",\"schema_version\":1,\"consent\":{\"analytics\":false}}]}"
var rawRequest = URLRequest(url: URL(string: collectURL + "/v1/batch")!)
rawRequest.httpMethod = "POST"
rawRequest.httpBody = Data(rawBody.utf8)
rawRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
rawRequest.setValue(projectKey, forHTTPHeaderField: "X-Feralin-Project-Key")
rawRequest.setValue(FeralinClient.idempotencyKey(for: [rawID]), forHTTPHeaderField: "Idempotency-Key")
let (rawData, rawResponse) = try await URLSession.shared.data(for: rawRequest)
let rawJSON = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any] ?? [:]
let reasons = rawJSON["rejected_reasons"] as? [String: Any]
must((rawResponse as? HTTPURLResponse)?.statusCode == 202 && rawJSON["accepted"] as? Int == 0 && reasons?["consent_denied"] as? Int == 1, "toplayıcı izinsiz olayı reddetmeliydi")
try expect("absent \(rawID)")
print("  OK izinsiz-toplayici-red")

// Yanlış anahtar: 401, olay atılır, uygulama düşmez
bridge = try make(key: "pk_test_wrong_key_000", consent: analyticsOnly)
let wrong = await track(bridge, "order_completed", ["order_id": "ord_objc_wrong"])
result = await flush(bridge)
must(result.status == 401 && result.rejected == 1 && result.error?.code == FRLErrorCode.rejected.rawValue, "401 bekleniyordu")
try expect("absent \(wrong ?? "")")
print("  OK yanlis-anahtar-401: \(result.status)")

// Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
let lossy = LossyTransport()
let core = try FeralinClient(
    configuration: .init(projectKey: projectKey, collectURL: collectURL, consent: Consent(analytics: true), flushInterval: 0, sdk: FRLFeralin.sdk),
    transport: lossy,
    installIDStore: InMemoryInstallIDStore()
)
bridge = FRLFeralin(client: core)
let retried = await track(bridge, "order_completed", ["order_id": "ord_objc_retry"])
let lost = await flush(bridge)
must(!lost.ok && lost.retained == 1, "yanıt kaybı kuyrukta tutulmalıydı")
let following = await track(bridge, "order_shipped", ["order_id": "ord_objc_retry"])
result = await flush(bridge)
must(result.ok && result.status == 202 && result.retained == 0, "tekrar 202 vermeliydi")
let keys = lossy.seenKeys
must(keys.count == 3 && keys[0] == keys[1], "aynı anahtar bekleniyordu")
try expect("once \(retried ?? "")")
try expect("once \(following ?? "")")
print("  OK idempotency-tekrar: \(keys[0])")

print("objc tüketici: tüm senaryolar geçti")
