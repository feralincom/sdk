import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TransportRequest: Sendable {
    public let url: URL
    public let body: Data
    public let headers: [String: String]
    public let timeout: TimeInterval
    /// HTTP yöntemi; olay ve atıf istekleri `POST`, kısa link çözümlemesi (Fera Fly) `GET`. Özel `Transport` uygulamaları bu alanı okumalıdır.
    public var method: String = "POST"
}

public struct TransportResponse: Sendable {
    public let status: Int
    public let body: Data
    public let headers: [String: String]

    public init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}

/// Ağ veya zaman aşımı hatası: olaylar kuyrukta kalır.
public struct TransportError: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// Testler ve özel ağ yığınları için değiştirilebilir taşıma. HTTP hata kodları normal yanıt olarak döner.
public protocol Transport: Sendable {
    func send(_ request: TransportRequest) async throws -> TransportResponse
}

/// Yönlendirme izlenmez: proje anahtarı başka adrese taşınmaz, 3xx yanıtı kalıcı olmayan hata gibi işlenir. Yanıt gövdesi indirme
/// sırasında 64 KB ile sınırlanır; sınır aşılınca istek kesilir, durum kodu ve kesilmiş gövde döner.
/// `URLSession.data(for:)` iOS 15 ister ve görev başına delege de iOS 15 ile gelir; paket iOS 14'ü desteklediğinden oturum delegesi kullanılır.
public struct URLSessionTransport: Transport {
    static let maxResponseBody = 64 * 1024

    private let owner: SessionOwner

    /// Çerez ve önbellek taşımayan ephemeral oturum.
    public init() {
        owner = SessionOwner(configuration: .ephemeral)
    }

    /// Verilen oturumun yalnız yapılandırması kullanılır: sınırlar için kendi delegesiyle yeni oturum açılır, verilen oturumun
    /// delegesi çağrılmaz. Özel ağ yığını gerekiyorsa `Transport` uygulanır.
    public init(session: URLSession) {
        owner = SessionOwner(configuration: session.configuration)
    }

    public func send(_ request: TransportRequest) async throws -> TransportResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        // GET gövde taşımaz (URLSession reddeder).
        if request.method != "GET" { urlRequest.httpBody = request.body }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransportResponse, Error>) in
            let task = owner.session.dataTask(with: urlRequest)
            owner.delegate.register(task.taskIdentifier, continuation)
            task.resume()
        }
    }
}

/// `URLSession` delegesini güçlü tutar; taşıma bırakılınca oturum kapatılır, delege sızmaz.
private final class SessionOwner: @unchecked Sendable {
    let delegate = LimitingSessionDelegate()
    let session: URLSession

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }
}

private final class LimitingSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<TransportResponse, Error>
        var body = Data()
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    func register(_ taskID: Int, _ continuation: CheckedContinuation<TransportResponse, Error>) {
        lock.lock()
        defer { lock.unlock() }
        pending[taskID] = Pending(continuation: continuation)
    }

    private func take(_ taskID: Int) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: taskID)
    }

    /// Sınır aşıldıysa kayıt çıkarılıp döner; aşılmadıysa veri eklenir, nil döner.
    private func append(_ data: Data, taskID: Int) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = pending[taskID] else { return nil }
        let room = URLSessionTransport.maxResponseBody - entry.body.count
        entry.body.append(data.prefix(room))
        if data.count > room {
            pending.removeValue(forKey: taskID)
            return entry
        }
        pending[taskID] = entry
        return nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let entry = append(data, taskID: dataTask.taskIdentifier) else { return }
        finish(entry, response: dataTask.response)
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = take(task.taskIdentifier) else { return }
        if let error {
            entry.continuation.resume(throwing: TransportError(message: "ağ hatası: \(error.localizedDescription)"))
            return
        }
        finish(entry, response: task.response)
    }

    private func finish(_ entry: Pending, response: URLResponse?) {
        guard let http = response as? HTTPURLResponse else {
            entry.continuation.resume(throwing: TransportError(message: "ağ hatası: HTTP yanıtı yok"))
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        entry.continuation.resume(returning: TransportResponse(status: http.statusCode, body: entry.body, headers: headers))
    }
}
