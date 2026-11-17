import Foundation

/// Monotonik ULID üretimi (26 karakter Crockford base32). Web ve Python SDK'larıyla aynı düzen:
/// 10 karakter zaman (ms) + 16 adet 5 bitlik rastgele basamak (80 bit). İstemci aktörü içinde kullanılır, kilit gerekmez.
struct ULIDGenerator {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private var lastMillis: Int64 = -1
    private var lastRandom = [UInt8](repeating: 0, count: 16)

    /// Aynı milisaniyede (veya saat geri gittiğinde) son değeri artırarak sıralamayı korur.
    mutating func next(millis now: Int64) -> String {
        var millis = now
        if millis > lastMillis {
            fillRandom()
        } else {
            millis = lastMillis
            if !incrementRandom() {
                millis += 1
                fillRandom()
            }
        }
        lastMillis = millis

        var head = [Character](repeating: "0", count: 10)
        var rest = millis
        for index in stride(from: 9, through: 0, by: -1) {
            head[index] = Self.alphabet[Int(rest & 31)]
            rest >>= 5
        }
        return String(head) + String(lastRandom.map { Self.alphabet[Int($0)] })
    }

    /// Yalnız birim testi için: rastgele kısmı taşma sınırına getirir.
    mutating func saturateRandomForTesting() {
        lastRandom = [UInt8](repeating: 31, count: 16)
    }

    private mutating func fillRandom() {
        // SystemRandomNumberGenerator Apple platformlarında kriptografik olarak güvenlidir.
        var generator = SystemRandomNumberGenerator()
        for index in lastRandom.indices {
            lastRandom[index] = UInt8.random(in: 0...31, using: &generator)
        }
    }

    private mutating func incrementRandom() -> Bool {
        for index in stride(from: 15, through: 0, by: -1) {
            if lastRandom[index] < 31 {
                lastRandom[index] += 1
                return true
            }
            lastRandom[index] = 0
        }
        return false
    }
}

/// 26 karakterlik Crockford base32 ULID biçim denetimi (ilk karakter en fazla '7').
public func isULID(_ value: String) -> Bool {
    let characters = Array(value)
    guard characters.count == 26, characters[0] <= "7" else { return false }
    return characters.allSatisfy { ULIDGenerator.alphabet.contains($0) }
}
