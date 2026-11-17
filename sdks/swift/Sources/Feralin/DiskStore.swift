import Foundation

/// Diskteki kuyruk satırı. `raw`, tel üzerinde gidecek olay JSON'unun UTF-8 metnidir; olduğu gibi yeniden gönderilir.
struct PersistedEvent: Codable, Equatable, Sendable {
    let id: String
    let raw: String
}

/// Diskteki oturum kaydı: süreç yeniden başlayınca 30 dk kuralının işleyebilmesi için son etkinlik zamanı da tutulur.
struct PersistedSession: Codable, Equatable, Sendable {
    var version: Int
    var sessionID: String
    var lastActivityMillis: Int64
}

private struct PersistedQueueFile: Codable {
    var version: Int
    var events: [PersistedEvent]
}

/// Kalıcı kuyruk ve oturum deposu. Dosyalar verilen dizinin altında tutulur, her yazım atomiktir (geçici dosya + yeniden adlandırma).
/// Disk hatası SDK'yı düşürmez: yazım başarısız olursa bellekteki kuyruk çalışmaya devam eder, okuma bozuksa kayıt sıfırlanır.
/// Bir dizin tek bir istemciye aittir; aynı dizini paylaşan iki istemci birbirinin kuyruğunu ezer.
final class FeralinDiskStore: @unchecked Sendable {
    static let formatVersion = 1
    static let queueFileName = "feralin-queue-v1.json"
    static let sessionFileName = "feralin-session-v1.json"
    /// Bundan büyük dosya bozuk sayılır; kuyruk sınırı bunun çok altında kalır.
    static let maxFileBytes = 16 * 1024 * 1024

    let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    var queueURL: URL { directory.appendingPathComponent(Self.queueFileName, isDirectory: false) }
    var sessionURL: URL { directory.appendingPathComponent(Self.sessionFileName, isDirectory: false) }

    /// Uygulama Destek dizininde SDK'ya ayrılmış varsayılan klasör. Bulunamazsa nil döner (kalıcılık kapalı kalır).
    static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Feralin", isDirectory: true)
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    // MARK: - Kuyruk

    /// En fazla `limit` olay döndürür; kuyruk doluysa en yeniler kalır. Dosya yoksa boş, bozuksa sıfırlanıp boş döner.
    /// Geçerli JSON nesnesi olmayan satırlar atılır: tek bir bozuk satır bütün batch'in 4xx ile reddedilmesine yol açmasın.
    func loadQueue(limit: Int) -> [PersistedEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = readFile(queueURL) else { return [] }
        guard let file = try? JSONDecoder().decode(PersistedQueueFile.self, from: data),
              file.version == Self.formatVersion else {
            removeFile(queueURL)
            return []
        }
        var seen = Set<String>()
        var valid: [PersistedEvent] = []
        for event in file.events {
            guard !event.id.isEmpty, seen.insert(event.id).inserted else { continue }
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(event.raw.utf8)), parsed is [String: Any] else { continue }
            valid.append(event)
        }
        if valid.count > limit { valid.removeFirst(valid.count - limit) }
        return valid
    }

    /// Kuyruğun tamamını atomik olarak yazar. Başarılıysa true.
    @discardableResult
    func saveQueue(_ events: [PersistedEvent]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(PersistedQueueFile(version: Self.formatVersion, events: events)) else { return false }
        return writeFile(data, to: queueURL)
    }

    func clearQueue() {
        lock.lock()
        defer { lock.unlock() }
        removeFile(queueURL)
    }

    // MARK: - Oturum

    func loadSession() -> PersistedSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = readFile(sessionURL) else { return nil }
        guard let session = try? JSONDecoder().decode(PersistedSession.self, from: data),
              session.version == Self.formatVersion,
              !session.sessionID.isEmpty,
              session.sessionID.unicodeScalars.count <= 128 else {
            removeFile(sessionURL)
            return nil
        }
        return session
    }

    @discardableResult
    func saveSession(sessionID: String, lastActivityMillis: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let session = PersistedSession(version: Self.formatVersion, sessionID: sessionID, lastActivityMillis: lastActivityMillis)
        guard let data = try? JSONEncoder().encode(session) else { return false }
        return writeFile(data, to: sessionURL)
    }

    func clearSession() {
        lock.lock()
        defer { lock.unlock() }
        removeFile(sessionURL)
    }

    // MARK: - Dosya işlemleri (kilit altında çağrılır)

    /// Dosya yoksa ya da aşırı büyükse nil; aşırı büyük dosya silinir.
    private func readFile(_ url: URL) -> Data? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            removeFile(url)
            return nil
        }
        if data.count > Self.maxFileBytes {
            removeFile(url)
            return nil
        }
        return data
    }

    private func writeFile(_ data: Data, to url: URL) -> Bool {
        do {
            try ensureDirectory()
            try data.write(to: url, options: Self.writeOptions)
            return true
        } catch {
            return false
        }
    }

    private func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func ensureDirectory() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) { return }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // Olay kuyruğu yedekle başka cihaza taşınmamalı.
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        #endif
    }
}
