import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// E-posta servis sağlayıcısının (ESP: SendGrid, Iterable, Braze, Klaviyo, SFMC…) tıklama izleme adresini çözer (Adjust karşılaştırması
/// madde 15). ESP, e-postadaki Feralin kısa linkini kendi tıklama alanına sarar; uygulama Universal Link ile bu sarılı adresle açılır.
/// Çözücü yönlendirmeleri izlemeden tek tek okur (en çok `maxHops` adım), yalnız `Location` başlığına bakar ve yalnız https adres izler.
/// Çözülemezse özgün adres döner. ESP tıklamayı bu istekle kaydeder: açılış ESP raporunda da görünür.
public struct TrackedLinkResolver: Sendable {
    public static let maxHops = 4

    /// Bir adımın sonucu: durum kodu ve (varsa) `Location` başlığı.
    public typealias Hop = @Sendable (URL) async throws -> (status: Int, location: String?)

    private let open: Hop

    public init(open: Hop? = nil) {
        self.open = open ?? TrackedLinkResolver.request
    }

    public func resolve(_ url: URL) async -> URL {
        var current = url
        for _ in 0..<Self.maxHops {
            guard current.scheme?.lowercased() == "https" else { return current }
            guard let hop = try? await open(current), (300...399).contains(hop.status), let location = hop.location?.trimmingCharacters(in: .whitespaces), !location.isEmpty,
                  let next = URL(string: location, relativeTo: current)?.absoluteURL else { return current }
            current = next
        }
        return current
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    private static let request: Hop = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("feralin-swift-link-resolver", forHTTPHeaderField: "User-Agent")
        let response: URLResponse = try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { _, response, error in
                if let response {
                    continuation.resume(returning: response)
                } else {
                    continuation.resume(throwing: error ?? URLError(.badServerResponse))
                }
            }.resume()
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, http.value(forHTTPHeaderField: "Location"))
    }
}

/// Push bildirimi açılışı (madde 15): bildirim verisindeki kampanya alanları `fr_push_open` olayına taşınır. Yalnız kapalı listedeki
/// anahtarlar okunur; başlık, gövde ve öteki veri gitmez. Kaldırma ölçümü bildirimi açılış sayılmaz.
enum PushOpen {
    static let event = "fr_push_open"
    private static let keys = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "fr_push_id"]

    static func properties(_ userInfo: [AnyHashable: Any]) -> [String: FeralinValue]? {
        if FeralinClient.isUninstallCheck(userInfo) { return nil }
        var props: [String: FeralinValue] = [:]
        for key in keys {
            guard let raw = userInfo[key] as? String else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...128).contains(value.count), value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { continue }
            props[key == "fr_push_id" ? "push_id" : key] = .string(value)
        }
        // Kampanya bilgisi olmayan bildirim de açılış olarak sayılır; ortam "push" olur.
        if props["utm_medium"] == nil { props["utm_medium"] = .string("push") }
        return props
    }
}

extension FeralinClient {
    /// Push bildirimine dokunarak açılışı bildirir (`fr_push_open`). `userNotificationCenter(_:didReceive:withCompletionHandler:)` içinden
    /// `response.notification.request.content.userInfo` ile çağrılır. Kaldırma ölçümü bildirimi için `nil` döner.
    @discardableResult
    public func trackPushOpen(userInfo: [AnyHashable: Any]) throws -> TrackedEvent? {
        guard let props = PushOpen.properties(userInfo) else { return nil }
        return try track(PushOpen.event, properties: props)
    }

    /// ESP tıklama izleme adresini Feralin kısa linkine çözer; dönen adres `handleUniversalLink(_:)` ile işlenir.
    public static func resolveTrackedLink(_ url: URL) async -> URL {
        await TrackedLinkResolver().resolve(url)
    }
}
