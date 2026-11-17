import CryptoKit
import Flutter
import Foundation
import Security

/// Yalnız kuyruk şifreleme köprüsü: AES-256-GCM anahtarı Keychain'de kalır ve Dart'a hiç geçmez.
/// Biçim Android çekirdeği ve Android eklentisiyle aynıdır: `enc1:` + onaltılı(nonce ‖ şifreli metin ‖ etiket), ilişkilendirilmiş veri olay kimliği.
/// Hata durumunda kanal `nil` döner; Dart tarafı olayı düz metne yazmadan bellekte tutar.
public class FeralinFlutterPlugin: NSObject, FlutterPlugin {
    private static let service = "com.feralin.sdk.flutter.queue.v1"
    private static let account = "queue-key"
    private static let prefix = "enc1:"
    private static let nonceBytes = 12
    private static let tagBytes = 16

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.feralin/flutter", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(FeralinFlutterPlugin(), channel: channel)
    }

    private let queue = DispatchQueue(label: "com.feralin.flutter.queue-crypto")

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "encryptQueue" || call.method == "decryptQueue" else {
            result(FlutterMethodNotImplemented)
            return
        }
        let encrypting = call.method == "encryptQueue"
        guard let args = call.arguments as? [String: Any],
              let first = args[encrypting ? "plain" : "stored"] as? String,
              let aad = args["aad"] as? String else {
            result(nil)
            return
        }
        // Keychain erişimi ana iş parçacığını bekletmesin.
        queue.async {
            let value = encrypting ? Self.encrypt(first, aad: aad) : Self.decrypt(first, aad: aad)
            DispatchQueue.main.async { result(value) }
        }
    }

    static func encrypt(_ plain: String, aad: String) -> String? {
        guard let key = loadOrCreateKey() else { return nil }
        do {
            let box = try AES.GCM.seal(Data(plain.utf8), using: key, authenticating: Data(aad.utf8))
            guard let combined = box.combined else { return nil }
            return prefix + hex(combined)
        } catch {
            return nil
        }
    }

    /// Açılamazsa (bozuk, kurcalanmış, anahtar kayıp) `nil`.
    static func decrypt(_ stored: String, aad: String) -> String? {
        guard stored.hasPrefix(prefix),
              let raw = unhex(String(stored.dropFirst(prefix.count))),
              raw.count > nonceBytes + tagBytes,
              let key = loadKey() else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: raw)
            let plain = try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
            return String(data: plain, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func loadKey() -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    private static func loadOrCreateKey() -> SymmetricKey? {
        if let key = loadKey() { return key }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        var query = baseQuery()
        query[kSecValueData as String] = Data(bytes)
        // Cihaza bağlı ve yedeğe girmez: başka cihaza taşınan kuyruk açılmaz, bu bilinçlidir.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return loadKey() }
        return status == errSecSuccess ? SymmetricKey(data: Data(bytes)) : nil
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func unhex(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
            out.append(UInt8(high << 4 | low))
            index += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> Int? {
        switch c {
        case 48...57: return Int(c) - 48
        case 97...102: return Int(c) - 87
        case 65...70: return Int(c) - 55
        default: return nil
        }
    }
}
