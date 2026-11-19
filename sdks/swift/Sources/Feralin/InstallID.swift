import Foundation

/// Anonim kurulum kimliğinin saklandığı yer. Kimlik cihazdan türetilmez; rastgele ULID'dir ve uygulamaya özeldir.
public protocol InstallIDStore: Sendable {
    func load() -> String?
    func save(_ value: String)
    func clear()
}

/// `UserDefaults` tabanlı depo. Apple belgelerine göre `UserDefaults` iş parçacığı güvenlidir.
public final class UserDefaultsInstallIDStore: InstallIDStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "com.feralin.sdk.install_id") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> String? { defaults.string(forKey: key) }
    public func save(_ value: String) { defaults.set(value, forKey: key) }
    public func clear() { defaults.removeObject(forKey: key) }
}

/// Süreç ömrü kadar yaşayan depo; testler ve kalıcı kimlik istemeyen uygulamalar için.
public final class InMemoryInstallIDStore: InstallIDStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    public init(value: String? = nil) { self.value = value }

    public func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func save(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        value = nil
    }
}

#if canImport(Security)
import Security

/// Anahtar zinciri tabanlı kurulum kimliği kasası (yeniden kurulum ölçümü, saas-api 0180). iOS'ta anahtar zinciri öğesi uygulama
/// kaldırıldıktan sonra genellikle kalır; yeniden kurulumda önceki kurulum kimliği buradan okunur. Apple bunu garanti etmez: kalmadığında
/// yeniden kurulum görülmez (yanlış "yeni kurulum" yazılır, uydurma yeniden kurulum yazılmaz). Öğe yalnız bu cihazda ve ilk kilit
/// açılışından sonra okunabilir; iCloud anahtar zinciriyle başka cihaza taşınmaz.
public final class KeychainInstallIDStore: InstallIDStore, @unchecked Sendable {
    private let service: String
    private let account = "feralin.install_id"

    public init(service: String = "com.feralin.sdk") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ value: String) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
#endif
