import Cordova
import Foundation

/// Cordova iOS köprüsü (cordova-ios 8, Swift Package eklentisi). Eylemler `FeralinBridge` üzerinden Feralin Swift SDK'sına gider;
/// sonuç her zaman `ok` durumuyla döner, hata JS'e reddedilmiş sonuç olarak geçmez. `ios-package` değeri bu sınıfın Objective-C adıdır.
@objc(FeralinCordovaPlugin)
final class FeralinCordovaPlugin: CDVPlugin {
    private let bridge = FeralinBridge.shared

    @objc func initialize(_ command: CDVInvokedUrlCommand) {
        let config = command.argument(at: 0) as? [String: Any] ?? [:]
        let name = config["sdkName"] as? String ?? "cordova-plugin-feralin"
        let version = config["sdkVersion"] as? String ?? "0.0.0-dev"
        send(command, bridge.initialize(config, sdkName: name, sdkVersion: version))
    }

    @objc func setConsent(_ command: CDVInvokedUrlCommand) {
        let consent = command.argument(at: 0)
        run(command) { bridge in await bridge.setConsent(consent) }
    }

    @objc func track(_ command: CDVInvokedUrlCommand) {
        guard let name = command.argument(at: 0) as? String else { return send(command, nil) }
        let properties = command.argument(at: 1)
        run(command) { bridge in await bridge.track(name, properties: properties) }
    }

    @objc func screen(_ command: CDVInvokedUrlCommand) {
        guard let name = command.argument(at: 0) as? String else { return send(command, nil) }
        let properties = command.argument(at: 1)
        run(command) { bridge in await bridge.screen(name, properties: properties) }
    }

    @objc func identify(_ command: CDVInvokedUrlCommand) {
        guard let userID = command.argument(at: 0) as? String else { return send(command, false) }
        run(command) { bridge in await bridge.identify(userID) }
    }

    @objc func reset(_ command: CDVInvokedUrlCommand) {
        run(command) { bridge in await bridge.reset() }
    }

    @objc func group(_ command: CDVInvokedUrlCommand) {
        guard let groupID = command.argument(at: 0) as? String else { return send(command, nil) }
        let traits = command.argument(at: 1)
        run(command) { bridge in await bridge.group(groupID, traits: traits) }
    }

    @objc func setUserProperties(_ command: CDVInvokedUrlCommand) {
        let properties = command.argument(at: 0)
        run(command) { bridge in await bridge.setUserProperties(properties) }
    }

    @objc func setGlobalProperties(_ command: CDVInvokedUrlCommand) {
        let properties = command.argument(at: 0)
        run(command) { bridge in await bridge.setGlobalProperties(properties) }
    }

    @objc func clearGlobalProperties(_ command: CDVInvokedUrlCommand) {
        run(command) { bridge in await bridge.clearGlobalProperties() }
    }

    /// İkinci argüman JS katmanının sözleşmeye göre kurduğu `feralin_purchase` özellikleridir.
    @objc func trackRevenue(_ command: CDVInvokedUrlCommand) {
        let properties = command.argument(at: 1)
        run(command) { bridge in await bridge.trackRevenue(properties: properties) }
    }

    @objc func flush(_ command: CDVInvokedUrlCommand) {
        run(command) { bridge in await bridge.flush() }
    }

    @objc func trackFirstOpen(_ command: CDVInvokedUrlCommand) {
        let options = command.argument(at: 0) as? [String: Any] ?? [:]
        run(command) { bridge in await bridge.trackFirstOpen(options) }
    }

    @objc func getInstallStore(_ command: CDVInvokedUrlCommand) {
        run(command) { bridge in await bridge.installStore() }
    }

    @objc func handleUniversalLink(_ command: CDVInvokedUrlCommand) {
        guard let url = command.argument(at: 0) as? String else { return send(command, nil) }
        run(command) { bridge in await bridge.handleUniversalLink(url) }
    }

    @objc func handleShortLink(_ command: CDVInvokedUrlCommand) {
        guard let url = command.argument(at: 0) as? String else { return send(command, nil) }
        run(command) { bridge in await bridge.handleShortLink(url) }
    }

    @objc func consumeDeferredDeepLink(_ command: CDVInvokedUrlCommand) {
        run(command) { bridge in await bridge.consumeDeferredDeepLink() }
    }

    @objc func setPushToken(_ command: CDVInvokedUrlCommand) {
        guard let token = command.argument(at: 0) as? String else { return send(command, nil) }
        run(command) { bridge in await bridge.setPushToken(token) }
    }

    @objc func installIdentifier(_ command: CDVInvokedUrlCommand) {
        run(command) { bridge in await bridge.installIdentifier() }
    }

    @objc func getStatus(_ command: CDVInvokedUrlCommand) {
        run(command) { bridge in await bridge.status() }
    }

    // MARK: - Yardımcılar

    private func run<T>(_ command: CDVInvokedUrlCommand, _ work: @escaping @Sendable (FeralinBridge) async -> T) {
        let bridge = self.bridge
        Task { [weak self] in
            let value = await work(bridge)
            self?.send(command, value)
        }
    }

    /// `commandDelegate.send` iş parçacığı bağımsızdır; Cordova sonucu ana iş parçacığına kendisi taşır.
    private func send(_ command: CDVInvokedUrlCommand, _ value: Any?) {
        let result: CDVPluginResult
        switch value {
        case let flag as Bool: result = CDVPluginResult(status: .ok, messageAs: flag)
        case let number as Int: result = CDVPluginResult(status: .ok, messageAs: number)
        case let text as String: result = CDVPluginResult(status: .ok, messageAs: text)
        case let map as [String: Any]: result = CDVPluginResult(status: .ok, messageAs: map)
        default: result = CDVPluginResult(status: .ok)
        }
        commandDelegate.send(result, callbackId: command.callbackId)
    }
}
