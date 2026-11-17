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
