import Foundation

/// UTP §8.2 kimlik yöntemlerinin istemci kuralları (`group`, `setUserProperties`, `setGlobalProperties`). Bütün SDK'larda ve toplayıcıda
/// (`services/collect/internal/httpapi/profile_filter.go`) birebir aynıdır; toplayıcı ayrıca projenin izin listesini uygular.
///
/// DİKKAT: Bu dosya macOS/Xcode olmadan yazıldı ve DERLENMEDİ; testleri koşulmadı (Mac M1 gerekir).
public enum ProfileRules {
    /// Grup olayı adı; React Native, Unity ve Android ile aynı.
    public static let groupEventName = "fr_group"
    /// Kullanıcı özellikleri olayı adı.
    public static let userPropertiesEventName = "fr_user_properties"
    /// Çağrı başına ve global haritada en çok özellik sayısı.
    public static let maxProperties = 50
    static let maxValueLength = 256
    static let maxGroupIDLength = 128

    // İstemci doğrulama beyan edemez: bu anahtarlar düşer, toplayıcı da düşürür.
    static let reservedKeys: Set<String> = ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"]

    // Kişisel veri anahtar kuralı (toplayıcıdaki piiTokens, piiFragments, piiExact ile aynı listeler).
    static let piiTokens: Set<String> = [
        "email", "mail", "phone", "tel", "telephone", "mobile", "msisdn", "gsm",
        "ip", "ipv4", "ipv6", "ssn", "tckn", "passport", "password", "iban",
        "address", "adres", "eposta", "telefon", "soyad", "surname", "firstname",
        "lastname", "fullname", "birthdate", "birthday", "dob",
    ]
    static let piiFragments: [String] = [
        "email", "phonenumber", "ipaddress", "firstname", "lastname", "fullname", "surname", "soyad", "eposta", "telefon", "password", "birthdate",
    ]
    static let piiExact: Set<String> = ["name", "username", "displayname", "isim", "ad"]

    // swiftlint:disable:next force_try
    private static let emailLike = try! NSRegularExpression(pattern: "[^\\s@]+@[^\\s@]+\\.[^\\s@]+")

    /// Sistem olayı (`fr_` önekli) mı; global özellikler bunlara eklenmez.
    public static func isSystemEvent(_ name: String) -> Bool { name.hasPrefix("fr_") }

    /// Anahtarı sözcüklere böler: küçük harf ya da rakamdan sonra gelen büyük harf yeni sözcük başlatır; alt çizgi ayırır.
    public static func keyTokens(_ key: String) -> [String] {
        var out = ""
        var previous: Character?
        for char in key {
            if let prev = previous, char.isUppercase, prev.isLowercase || prev.isNumber {
                out.append("_")
            }
            out.append(contentsOf: char.lowercased())
            previous = char
        }
        return out.split(separator: "_").map(String.init)
    }

    /// Anahtar kişisel veriye (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) benziyor mu.
    public static func isPIILikeKey(_ key: String) -> Bool {
        let tokens = keyTokens(key)
        if tokens.contains(where: piiTokens.contains) { return true }
        let joined = tokens.joined()
        if piiExact.contains(joined) { return true }
        return piiFragments.contains { joined.contains($0) }
    }

    /// Grup kimliği kuralı: 1-128 karakter, yalnız boşluk değil, `@` ve kontrol karakteri yok.
    public static func isValidGroupID(_ groupID: String) -> Bool {
        !groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && groupID.count <= maxGroupIDLength
            && !groupID.contains("@")
            && !hasControl(groupID)
    }

    static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func validKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        func letter(_ b: UInt8) -> Bool { (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) }
        func digit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        let shaped = !bytes.isEmpty && bytes.count <= 64 && letter(bytes[0]) && bytes.allSatisfy { letter($0) || digit($0) || $0 == 0x5F }
        return shaped && !reservedKeys.contains(key) && !isPIILikeKey(key)
    }

    /// Değer dizge (≤256, kontrol karakteri ve e-posta biçimi yok), sonlu sayı ya da mantıksal ise kendisi; değilse nil.
    static func cleanValue(_ value: FeralinValue) -> FeralinValue? {
        switch value {
        case .string(let text):
            let range = NSRange(text.startIndex..., in: text)
            if text.count > maxValueLength || hasControl(text) || emailLike.firstMatch(in: text, range: range) != nil { return nil }
            return value
        case .bool, .int:
            return value
        case .double(let number):
            // Üçlü ifadede `nil`, FeralinValue'nun nil literal'i (`.null`) olarak çözülür ve değer düşmek yerine null gider;
            // bu yüzden açık dönüş kullanılır.
            guard number.isFinite else { return nil }
            return value
        case .array, .object, .null:
            return nil
        }
    }

    /// Özellikleri sözleşmeye indirger; anahtar sırası deterministik olsun diye sözlük sırasıyla işlenir, çağrı başına en çok 50 özellik
    /// tutulur. `allowNull` yalnız global haritada kullanılır: `.null` değer anahtarı silme isteğidir.
    public static func sanitize(_ properties: [String: FeralinValue]?, allowNull: Bool = false) -> (properties: [String: FeralinValue], dropped: Int) {
        var out: [String: FeralinValue] = [:]
        var dropped = 0
        guard let properties else { return (out, 0) }
        for key in properties.keys.sorted() {
            guard let value = properties[key], validKey(key) else {
                dropped += 1
                continue
            }
            let clean: FeralinValue?
            if allowNull, value == .null {
                clean = .null
            } else {
                clean = cleanValue(value)
            }
            guard let clean, out.count < maxProperties || out[key] != nil else {
                dropped += 1
                continue
            }
            out[key] = clean
        }
        return (out, dropped)
    }
}
