import Capacitor
import Foundation

/// Capacitor iOS köprüsü. Çağrılar `FeralinBridge` üzerinden Feralin Swift SDK'sına gider; çağrı reddedilmez, sonuç her zaman nesnedir.
/// Universal Link açılışları Capacitor'ın `capacitorOpenUniversalLink` bildiriminden otomatik yakalanır (`autoCaptureDeepLinks` false değilse).
@objc(FeralinPlugin)
public class FeralinPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "FeralinPlugin"
    public let jsName = "Feralin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "initialize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setConsent", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "track", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "screen", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "identify", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reset", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "group", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setUserProperties", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setGlobalProperties", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearGlobalProperties", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "trackRevenue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "flush", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "trackFirstOpen", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getInstallStore", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "handleUniversalLink", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "handleShortLink", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "consumeDeferredDeepLink", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPushToken", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "installIdentifier", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getStatus", returnType: CAPPluginReturnPromise),
    ]

    // `bridge` adı CAPPlugin'in Capacitor köprüsüdür; Feralin köprüsü ayrı adla tutulur.
    private let feralin = FeralinBridge.shared
    private var linkObserver: NSObjectProtocol?

    deinit {
        if let linkObserver { NotificationCenter.default.removeObserver(linkObserver) }
    }

    @objc func initialize(_ call: CAPPluginCall) {
        let config = call.options["config"] as? [String: Any] ?? [:]
        let name = config["sdkName"] as? String ?? "@feralin/capacitor"
        let version = config["sdkVersion"] as? String ?? "0.0.0-dev"
        let ready = feralin.initialize(config, sdkName: name, sdkVersion: version)
        if ready, config["autoCaptureDeepLinks"] as? Bool ?? true { captureUniversalLinks() }
        call.resolve(["ready": ready])
    }

    /// JS başlamadan önce gelen açılış adresi Capacitor'da `lastURL` içinde kalır; sonrakiler bildirimle gelir.
    private func captureUniversalLinks() {
        guard linkObserver == nil else { return }
        let feralin = self.feralin
        if let url = ApplicationDelegateProxy.shared.lastURL, url.scheme == "https" {
            Task { _ = await feralin.handleUniversalLink(url.absoluteString) }
        }
        linkObserver = NotificationCenter.default.addObserver(forName: .capacitorOpenUniversalLink, object: nil, queue: nil) { notification in
            guard let payload = notification.object as? [String: Any], let url = payload["url"] as? URL else { return }
            Task { _ = await feralin.handleUniversalLink(url.absoluteString) }
        }
    }

    @objc func setConsent(_ call: CAPPluginCall) {
        let consent = call.options["consent"]
        run(call) { feralin in ["ok": await feralin.setConsent(consent)] }
    }

    @objc func track(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? ""
        let properties = call.options["properties"]
        run(call) { feralin in Self.eventID(await feralin.track(name, properties: properties)) }
    }

    @objc func screen(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? ""
        let properties = call.options["properties"]
        run(call) { feralin in Self.eventID(await feralin.screen(name, properties: properties)) }
    }

    @objc func identify(_ call: CAPPluginCall) {
        let userID = call.getString("userId") ?? ""
        run(call) { feralin in ["ok": await feralin.identify(userID)] }
    }

    @objc func reset(_ call: CAPPluginCall) {
        run(call) { feralin in ["ok": await feralin.reset()] }
    }

    @objc func group(_ call: CAPPluginCall) {
        let groupID = call.getString("groupId") ?? ""
        let traits = call.options["traits"]
        run(call) { feralin in Self.eventID(await feralin.group(groupID, traits: traits)) }
    }

    @objc func setUserProperties(_ call: CAPPluginCall) {
        let properties = call.options["properties"]
        run(call) { feralin in Self.eventID(await feralin.setUserProperties(properties)) }
    }

    @objc func setGlobalProperties(_ call: CAPPluginCall) {
        let properties = call.options["properties"]
        run(call) { feralin in ["count": await feralin.setGlobalProperties(properties)] }
    }

    @objc func clearGlobalProperties(_ call: CAPPluginCall) {
        run(call) { feralin in ["ok": await feralin.clearGlobalProperties()] }
    }

    /// `properties` JS katmanının sözleşmeye göre kurduğu `feralin_purchase` özellikleridir.
    @objc func trackRevenue(_ call: CAPPluginCall) {
        let properties = call.options["properties"]
        run(call) { feralin in Self.eventID(await feralin.trackRevenue(properties: properties)) }
    }

    @objc func flush(_ call: CAPPluginCall) {
        run(call) { feralin in await feralin.flush() }
    }

    @objc func trackFirstOpen(_ call: CAPPluginCall) {
        let options = call.options["options"] as? [String: Any] ?? [:]
        run(call) { feralin in await feralin.trackFirstOpen(options) }
    }

    @objc func getInstallStore(_ call: CAPPluginCall) {
        run(call) { feralin in ["installStore": await feralin.installStore() ?? NSNull()] }
    }

    @objc func handleUniversalLink(_ call: CAPPluginCall) {
        let url = call.getString("url") ?? ""
        run(call) { feralin in await feralin.handleUniversalLink(url) }
    }

    @objc func handleShortLink(_ call: CAPPluginCall) {
        let url = call.getString("url") ?? ""
        run(call) { feralin in await feralin.handleShortLink(url) }
    }

    @objc func consumeDeferredDeepLink(_ call: CAPPluginCall) {
        run(call) { feralin in await feralin.consumeDeferredDeepLink() }
    }

    @objc func setPushToken(_ call: CAPPluginCall) {
        let token = call.getString("token") ?? ""
        run(call) { feralin in Self.eventID(await feralin.setPushToken(token)) }
    }

    @objc func installIdentifier(_ call: CAPPluginCall) {
        run(call) { feralin in ["installId": await feralin.installIdentifier() ?? NSNull()] }
    }

    @objc func getStatus(_ call: CAPPluginCall) {
        run(call) { feralin in await feralin.status() }
    }

    // MARK: - Yardımcılar

    private func run(_ call: CAPPluginCall, _ work: @escaping @Sendable (FeralinBridge) async -> [String: Any]) {
        let feralin = self.feralin
        Task {
            let value = await work(feralin)
            call.resolve(value)
        }
    }

    private static func eventID(_ id: String?) -> [String: Any] {
        ["eventId": id ?? NSNull()]
    }
}
