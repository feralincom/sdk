import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// Kısa link ve derin bağlantı yardımcıları: bağlantı açılışını yakalama, ertelenmiş derin bağlantı ve izinli pano eşlemesi.
/// Çözümleme saf fonksiyonlardır (`FeralinLinks`); istemci yöntemleri izin denetimini ve olay gönderimini ekler.
public enum FeralinLinks {
    /// Sunucunun ürettiği tıklama kimliğinin biçimi; uymayan değer gönderilmez.
    static let clickPattern = "^[A-Za-z0-9_-]{16,64}$"

    static func isClickID(_ value: String) -> Bool {
        value.range(of: clickPattern, options: .regularExpression) != nil
    }

    /// Bağlantının `fr_click` değeri; yoksa ya da biçimi bozuksa nil.
    public static func clickID(in url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        guard let value = items.first(where: { $0.name == Wire.attributionClickProperty })?.value, isClickID(value) else { return nil }
        return value
    }

    /// Uygulamanın açacağı yol: bağlantının yolu ve Feralin'e ait olmayan sorgu parametreleri. `fr_` ile başlayan parametreler çıkarılır.
    public static func destination(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.path.isEmpty ? "/" : url.path }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let kept = (components.percentEncodedQueryItems ?? []).filter { !$0.name.hasPrefix("fr_") }
        guard !kept.isEmpty else { return path }
        return path + "?" + kept.map { item in item.value.map { "\(item.name)=\($0)" } ?? item.name }.joined(separator: "&")
    }

    /// Pano metni, verilen kısa link hostlarından birine ait `https` adresiyse ve geçerli `fr_click` taşıyorsa tıklama kimliğini döner.
    /// Başka her metin (parola, adres, başka site) için nil: pano içeriği saklanmaz, gönderilmez, loglanmaz.
    public static func clipboardClick(_ text: String, linkHosts: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 512, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let allowed = linkHosts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return clickID(in: url)
    }
}

/// Yakalanan bağlantı açılışı: uygulamanın gideceği yol ve gönderilen olay.
public struct LinkOpen: Equatable, Sendable {
    /// Yol ve Feralin'e ait olmayan sorgu (ör. `/urun/42?renk=mavi`).
    public let destination: String
    /// Bağlantıdaki tıklama kimliği; reklam ölçümü izni yoksa olaya eklenmez.
    public let hasClickID: Bool
    /// Üretilen `deep_link_opened` olayı; analitik izni yoksa nil.
    public let event: TrackedEvent?
}

/// Ertelenmiş derin bağlantı: kurulumun atfedildiği link.
public struct DeferredLink: Equatable, Sendable, Decodable {
    public let decisionID: String
    public let linkCode: String?
    /// Uygulamanın açacağı yol; link yol taşımıyorsa nil (atıf var, yönlendirme yok).
    public let deepLinkPath: String?
    public let utm: [String: String]
    public let evidenceClass: String
    public let confidence: String
    public let attributionSource: String

    enum CodingKeys: String, CodingKey {
        case utm, confidence
        case decisionID = "decision_id"
        case linkCode = "link_code"
        case deepLinkPath = "deep_link_path"
        case evidenceClass = "evidence_class"
        case attributionSource = "attribution_source"
    }
}

public enum DeferredDeepLink: Equatable, Sendable {
    case matched(DeferredLink)
    /// Karar var, atıf yok; neden sunucunun `reason_code` değeridir.
    case noMatch(reason: String?)
    /// Deneme sayısı bitti, karar hâlâ yazılmadı. Sonraki açılışta yeniden sorulabilir.
    case pending
    case skippedNoConsent
    case notConfigured
    case rejected(status: Int, detail: String)
    case temporaryFailure(status: Int, message: String)
}

struct DeferredLinkResponse: Decodable {
    let status: String
    let reason: String?
    let retryAfterSeconds: Double?
    let link: DeferredLink?

    enum CodingKeys: String, CodingKey {
        case status, reason, link
        case retryAfterSeconds = "retry_after_seconds"
    }
}

extension FeralinClient {
    /// İlk açılış olayı (`app_first_open`). Tıklama kimliği verilirse kaynağıyla birlikte eklenir; reklam ölçümü izni yoksa kimlik çıkarılır.
    /// Uygulama bu yöntemi kurulumdan sonraki ilk açılışta bir kez çağırır; "ilk açılış" bilgisini uygulama tutar.
    /// `installStore`: `await FeralinInstallSource.current()` değeri (App Store, TestFlight, alternatif pazar yeri…); listede olmayan değer yok sayılır.
    /// `advertisingID`: isteğe bağlı IDFA. SDK, AdSupport'a bağlanmaz ve kimliği kendisi okumaz; uygulama ATT izni `authorized` olduktan sonra
    /// `ASIdentifierManager.shared().advertisingIdentifier.uuidString` değerini verir. Kimlik yalnız reklam ölçümü izni açıksa, uygulama çocuklara
    /// yönelik değilse ve değer sıfırlanmamış bir UUID ise gönderilir; sunucu onu yalnız panelde projenin "Reklam kimliği" ayarı da açıksa saklar.
    /// Simülatörde derlenmiş uygulama ilk açılışa `device_emulator: true`, jailbreak'li görünen cihaz `device_rooted: true` ekler (evet/hayır; cihaz kimliği değildir).
    @discardableResult
    public func trackFirstOpen(clickID: String? = nil, source: String? = nil, installStore: String? = nil, advertisingID: String? = nil) throws -> TrackedEvent? {
        var properties: [String: FeralinValue] = [:]
        if let installStore, FeralinInstallSource.values.contains(installStore) { properties["install_store"] = .string(installStore) }
        if FeralinInstallSource.isSimulator { properties["device_emulator"] = .bool(true) }
        if FeralinInstallSource.isJailbroken { properties["device_rooted"] = .bool(true) }
        if let osVersion = FeralinInstallSource.osVersion { properties["os_version"] = .string(osVersion) }
        if let adID = FeralinInstallSource.normalizedAdvertisingID(advertisingID) { properties[Wire.advertisingIDProperty] = .string(adID) }
        // Yeniden kurulum (saas-api 0180): anahtar zincirinde kalan önceki kurulum kimliği.
        if let previous = previousInstallIDForFirstOpen() { properties["previous_install_id"] = .string(previous) }
        if let clickID, FeralinLinks.isClickID(clickID), let source {
            properties[Wire.attributionClickProperty] = .string(clickID)
            properties["attribution_source"] = .string(source)
        }
        return try track("app_first_open", properties: properties.isEmpty ? nil : properties)
    }

    /// Universal Link ile açılışı yakalar: `deep_link_opened` olayını gönderir ve uygulamanın açacağı yolu döner.
    /// `application(_:continue:restorationHandler:)` ya da SwiftUI `onOpenURL` içinden çağrılır.
    @discardableResult
    public func handleUniversalLink(_ url: URL) throws -> LinkOpen {
        let click = FeralinLinks.clickID(in: url)
        var properties: [String: FeralinValue] = ["attribution_source": .string("universal_link")]
        if let click { properties[Wire.attributionClickProperty] = .string(click) }
        let event = try track("deep_link_opened", properties: properties)
        return LinkOpen(destination: FeralinLinks.destination(of: url), hasClickID: click != nil, event: event)
    }

    /// Panodaki kısa link adresinden tıklama kimliğini okur (izinli pano eşlemesi). Yalnız reklam ölçümü izni varken çalışır; izin yoksa
    /// pano hiç okunmaz. iOS, okuma sırasında kullanıcıya yapıştırma izni sorabilir. Pano içeriği kısa link adresi değilse hiçbir şey
    /// saklanmaz. Dönen kimlik `trackFirstOpen(clickID:source:)` çağrısına `clipboard` kaynağıyla verilir.
    /// - Parameters:
    ///   - linkHosts: Kısa linklerinizin hostları (ör. `feralin.com`, markalı alanınız). Başka hostun adresi kabul edilmez.
    ///   - reader: Pano okuyucu; varsayılanı iOS'ta `UIPasteboard`, öteki platformlarda boş.
    public func clipboardClickID(linkHosts: [String], reader: @Sendable () -> String? = FeralinClient.systemClipboard) -> String? {
        guard installIdentifier() != nil else { return nil }
        guard let text = reader() else { return nil }
        return FeralinLinks.clipboardClick(text, linkHosts: linkHosts)
    }

    /// Sistem panosu. Önce panoda adres biçiminde içerik olup olmadığına bakılır (bu denetim izin sormaz); adres yoksa içerik okunmaz.
    public static let systemClipboard: @Sendable () -> String? = {
        #if canImport(UIKit) && os(iOS)
        guard UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings else { return nil }
        if let url = UIPasteboard.general.url { return url.absoluteString }
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }

    /// Ertelenmiş derin bağlantıyı sorar: kurulum bir linke atfedildiyse linkin uygulama içi yolunu döner. İlk açılış olayı gönderildikten
    /// sonra çağrılır; karar birkaç saniye içinde yazıldığı için `pending` yanıtında kısa aralıkla yeniden sorar.
    /// - Parameters:
    ///   - maxAttempts: En çok deneme (1–10).
    ///   - sleep: Bekleme; yalnız testler değiştirir.
    public func fetchDeferredDeepLink(
        maxAttempts: Int = 4,
        sleep: @Sendable (TimeInterval) async -> Void = { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
    ) async -> DeferredDeepLink {
        guard let attribution = attributionConfiguration else { return .notConfigured }
        guard let installID = installIdentifier() else { return .skippedNoConsent }
        // İlk açılış olayı kuyruktaysa önce gönderilir; karar o olaydan üretilir.
        _ = try? await flush()
        let attempts = min(max(maxAttempts, 1), 10)
        for attempt in 1...attempts {
            let response: TransportResponse
            do {
                response = try await postAttribution(attribution, path: "attribution/deferred-link", body: .object(["install_id": .string(installID), "consent": .bool(true)]))
            } catch {
                return .temporaryFailure(status: 0, message: FeralinClient.describe(error))
            }
            switch response.status {
            case 200:
                guard let decoded = try? JSONDecoder().decode(DeferredLinkResponse.self, from: response.body) else {
                    return .temporaryFailure(status: 200, message: "yanıt çözümlenemedi")
                }
                if decoded.status == "matched", let link = decoded.link { return .matched(link) }
                if decoded.status == "no_match" { return .noMatch(reason: decoded.reason) }
                if attempt == attempts { return .pending }
                await sleep(min(max(decoded.retryAfterSeconds ?? 3, 1), 30))
            case 500...: return .temporaryFailure(status: response.status, message: FeralinClient.summarize(response.body))
            default: return .rejected(status: response.status, detail: FeralinClient.summarize(response.body))
            }
        }
        return .pending
    }
}

/// Fera Fly kısa link çözümlemesi: uygulama `https://marka.fera.fly/kod` gibi bir kısa linkle doğrudan açıldığında (Universal Link) yönlendirici
/// atlanır. SDK aynı adresi `application/vnd.feralin.link+json` türüyle ister; linkin uygulama içi yolu, UTM'si ve (izin varsa) tıklama kimliği döner.
public struct ResolvedShortLink: Equatable, Sendable, Decodable {
    public let code: String
    public let destination: String
    public let deepLinkPath: String?
    public let utm: [String: String]
    public let clickID: String?
    public let rule: String

    enum CodingKeys: String, CodingKey {
        case code, destination, utm, rule
        case deepLinkPath = "deep_link_path"
        case clickID = "click_id"
    }
}

extension FeralinLinks {
    /// Feralin'in resmi kısa alanı. Markalı alanınız varsa `linkHosts` listesine ekleyin.
    public static let defaultLinkHosts = ["fera.fly"]
    static let resolveAccept = "application/vnd.feralin.link+json"

    /// Adres bir Feralin kısa linki mi: `https` ve host listedeki bir host ya da onun alt alanı (`marka.fera.fly`).
    public static func isShortLink(_ url: URL, linkHosts: [String] = defaultLinkHosts) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        let allowed = linkHosts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        return allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    /// Çözümleme isteği. Kullanıcı-ajanı yönlendiricinin cihaz sınıfını (iPhone, Mac) bulmasına yeter; cihaz modeli ya da başka ayrıntı
    /// gönderilmez. Reklam ölçümü izni yoksa `Feralin-Attribution: off`: yönlendirici tıklamayı toplam sayar ama kanıt (IP içeren) yazmaz.
    static func resolveRequest(for url: URL, osVersion: String?, attribution: Bool) -> TransportRequest {
        let os = (osVersion ?? "17_0").replacingOccurrences(of: ".", with: "_")
        #if os(macOS)
        let agent = "FeralinSDK (Macintosh; Intel Mac OS X \(os))"
        #else
        let agent = "FeralinSDK (iPhone; CPU iPhone OS \(os) like Mac OS X)"
        #endif
        var headers = ["Accept": resolveAccept, "User-Agent": agent]
        if !attribution { headers["Feralin-Attribution"] = "off" }
        var request = TransportRequest(url: url, body: Data(), headers: headers, timeout: 5)
        request.method = "GET"
        return request
    }
}

extension FeralinClient {
    /// Kısa linkle açılışı yakalar (Fera Fly). Adres kısa link değilse ya da çözümlenemezse `handleUniversalLink` ile aynı davranır.
    /// Çözümlenince uygulamanın açacağı yol linkin derin yoludur (yoksa `/`), `deep_link_opened` olayı kısa kodu ve (izin varsa) tıklama
    /// kimliğini taşır. `application(_:continue:restorationHandler:)` ya da SwiftUI `onOpenURL` içinden `await` ile çağrılır.
    public func handleShortLink(_ url: URL, linkHosts: [String] = FeralinLinks.defaultLinkHosts) async -> LinkOpen {
        let fallback: () -> LinkOpen = {
            (try? self.handleUniversalLink(url)) ?? LinkOpen(destination: FeralinLinks.destination(of: url), hasClickID: false, event: nil)
        }
        guard FeralinLinks.isShortLink(url, linkHosts: linkHosts), FeralinLinks.clickID(in: url) == nil else { return fallback() }
        let request = FeralinLinks.resolveRequest(for: url, osVersion: FeralinInstallSource.osVersion, attribution: linkAttributionAllowed)
        guard let response = try? await sendLinkRequest(request), response.status == 200,
              let resolved = try? JSONDecoder().decode(ResolvedShortLink.self, from: response.body) else { return fallback() }
        var properties: [String: FeralinValue] = ["attribution_source": .string("universal_link"), "link_code": .string(resolved.code)]
        if let click = resolved.clickID, FeralinLinks.isClickID(click) { properties[Wire.attributionClickProperty] = .string(click) }
        let event = try? track("deep_link_opened", properties: properties)
        return LinkOpen(destination: resolved.deepLinkPath ?? "/", hasClickID: properties[Wire.attributionClickProperty] != nil, event: event)
    }
}
