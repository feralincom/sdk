import Foundation
#if canImport(Darwin)
import Darwin
import MachO
#endif

/// iOS sembolleştirme çerçeveleri (`fr_error.properties.frames`). Yüklenen dSYM ile sunucuda (`llvm-symbolizer`) okuma anında çözülür.
///
/// Sözleşme sunucudaki `macho-symbols.ts` ile birebir aynıdır:
/// - `file` = `<modül>~<uuid>`: modül görüntünün (image) dosya adıdır, izinsiz karakterler `_` olur, en çok 95 karakter, `.so` ile bitmez;
///   UUID görüntünün `LC_UUID` değeridir (küçük harf, tiresiz 32 onaltılı). dSYM ile ikilinin aynı derleme olduğu yalnız UUID ile doğrulanır.
/// - Görüntü başlangıcına göre göreli adres iki alana bölünür, çünkü toplayıcı satır ve sütunu 10.000.000 ile sınırlar:
///   `line = offset / 10.000.000 + 1`, `column = offset % 10.000.000`.
/// - `function` gönderilmez; ham bellek adresi, dosya yolu ve kullanıcı verisi gitmez. Sistem görüntüleri (`/System/`, `/usr/lib/`)
///   atlanır: onların dSYM'si uygulama sahibinde yoktur.
enum AppleFrames {
    static let split: UInt64 = 10_000_000
    static let maxFrames = 5
    private static let maxLine: UInt64 = 10_000_000

    /// Sunucudaki `appleModuleName` ile aynı kural.
    static func moduleName(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let allowed = (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A) || scalar == "." || scalar == "_" || scalar == "-"
            scalars.append(allowed ? scalar : "_")
        }
        var name = String(String(scalars).prefix(95))
        if name.hasSuffix(".so") { name = String(name.prefix(94)) + "_" }
        return name
    }

    /// Tek çerçeve; modül adı boşsa, UUID biçimi bozuksa ya da adres sınır dışıysa `nil`.
    static func frame(module: String, uuid: String, offset: UInt64) -> FeralinValue? {
        let name = moduleName(module)
        guard !name.isEmpty, uuid.count == 32, uuid.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        let line = offset / split + 1
        guard line <= maxLine else { return nil }
        return .object([
            "file": .string("\(name)~\(uuid)"),
            "line": .int(Int64(line)),
            "column": .int(Int64(offset % split)),
        ])
    }

    /// Küçük harf onaltılı gösterim.
    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return out
    }

    #if canImport(Darwin)
    /// Çağrı yığınının dönüş adreslerinden (`Thread.callStackReturnAddresses`, `NSException.callStackReturnAddresses`) uygulama
    /// görüntülerine düşen ilk beş çerçeve. Dönüş adresi çağrı komutundan sonrasını gösterdiği için 1 çıkarılır (çözüm çağrının satırına düşer).
    static func capture(_ returnAddresses: [NSNumber]) -> [FeralinValue] {
        var frames: [FeralinValue] = []
        var uuids: [UInt: String] = [:]
        for number in returnAddresses.prefix(64) {
            guard frames.count < maxFrames else { break }
            let address = number.uintValue
            guard address > 1, let pointer = UnsafeRawPointer(bitPattern: address - 1) else { continue }
            var info = Dl_info()
            guard dladdr(pointer, &info) != 0, let base = info.dli_fbase, let fname = info.dli_fname else { continue }
            let path = String(cString: fname)
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/") { continue }
            let baseAddress = UInt(bitPattern: base)
            guard address - 1 >= baseAddress else { continue }
            let uuid: String
            if let cached = uuids[baseAddress] {
                uuid = cached
            } else if let read = imageUUID(UnsafeRawPointer(base)) {
                uuid = read
                uuids[baseAddress] = read
            } else {
                continue
            }
            let module = (path as NSString).lastPathComponent
            if let frame = frame(module: module, uuid: uuid, offset: UInt64(address - 1 - baseAddress)) { frames.append(frame) }
        }
        return frames
    }

    /// Bellekteki Mach-O başlığından `LC_UUID`; bulunamazsa `nil`.
    static func imageUUID(_ base: UnsafeRawPointer) -> String? {
        let magic = base.load(as: UInt32.self)
        let headerSize: Int
        switch magic {
        case UInt32(MH_MAGIC_64): headerSize = MemoryLayout<mach_header_64>.size
        case UInt32(MH_MAGIC): headerSize = MemoryLayout<mach_header>.size
        default: return nil
        }
        let header = base.load(as: mach_header.self)
        var cursor = base + headerSize
        for _ in 0..<min(header.ncmds, 4096) {
            let command = cursor.load(as: load_command.self)
            if command.cmd == UInt32(LC_UUID) {
                let uuid = cursor.load(as: uuid_command.self).uuid
                let bytes = withUnsafeBytes(of: uuid) { Array($0) }
                let text = hex(bytes)
                return text == String(repeating: "0", count: 32) ? nil : text
            }
            guard command.cmdsize >= 8 else { return nil }
            cursor += Int(command.cmdsize)
        }
        return nil
    }
    #else
    /// Darwin dışı platformlarda (Linux'ta derleme ve test) görüntü bilgisi okunmaz: çerçeve gönderilmez.
    static func capture(_ returnAddresses: [NSNumber]) -> [FeralinValue] { [] }
    #endif
}
