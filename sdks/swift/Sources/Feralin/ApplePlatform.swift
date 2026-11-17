import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
// Apple belgelerine göre AAAttribution: iOS 14.3, Mac Catalyst 14.3, macOS 11.1, visionOS 1.0. tvOS ve watchOS'ta yoktur.
#if canImport(AdServices) && !os(tvOS) && !os(watchOS)
import AdServices
#endif
// SKAdNetwork ve AdAttributionKit Postback belgelerde yalnız iOS, iPadOS ve Mac Catalyst'te listelenir.
#if canImport(StoreKit) && os(iOS)
import StoreKit
#endif
#if canImport(AdAttributionKit) && os(iOS)
import AdAttributionKit
#endif

/// ATT durumu. SDK izin penceresi göstermez: `NSUserTrackingUsageDescription` ve zamanlama uygulamanındır.
public enum TrackingAuthorizationStatus: String, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    /// Bu platformda ATT yok (watchOS gibi).
    case unavailable
}

public enum AdServicesTokenResult: Equatable, Sendable {
    case token(String)
    /// Çerçeve ya da işletim sistemi sürümü desteklemiyor (tvOS, watchOS, iOS 14.3 altı).
    case notSupported
    case failed(String)
}

public enum CoarseConversionLevel: String, Equatable, Sendable {
    case low
    case medium
    case high
}

/// Hangi çerçevenin çağrılacağı. Apple: ağınız ikisiyle de bütünleşikse ikisi de çağrılır.
public struct ConversionFrameworks: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let adAttributionKit = ConversionFrameworks(rawValue: 1)
    public static let skAdNetwork = ConversionFrameworks(rawValue: 2)
    public static let both: ConversionFrameworks = [.adAttributionKit, .skAdNetwork]
}

/// `called` çağrının hatasız döndüğünü söyler; atıf gerçekleştiği anlamına gelmez.
/// Bekleyen postback yoksa sistem çağrıyı yok sayar (Apple belgesi) ve SDK bunu ayırt edemez.
public enum ConversionCallOutcome: Equatable, Sendable {
    case called
    case notSupported
    case notRequested
    case skippedNoConsent
    case failed(String)
}

public struct ConversionUpdateResult: Equatable, Sendable {
    public let adAttributionKit: ConversionCallOutcome
    public let skAdNetwork: ConversionCallOutcome

    public init(adAttributionKit: ConversionCallOutcome, skAdNetwork: ConversionCallOutcome) {
        self.adAttributionKit = adAttributionKit
        self.skAdNetwork = skAdNetwork
    }
}

/// Apple çerçevelerine ince köprü. Hiçbiri IDFA ya da cihaz parmak izi okumaz; Feralin sunucusuna istek atmaz.
/// Token ve dönüşüm çağrıları izin denetimi yapmadığından dışarı açık değildir; izinli yol `FeralinClient` yöntemleridir.
/// `@usableFromInline`: `FeralinClient.init` varsayılan bağımsız değişkenleri bunlara başvurur.
public enum FeralinApple {
    /// Geçerli ATT durumunu okur, izin penceresi açmaz.
    public static func trackingAuthorizationStatus() -> TrackingAuthorizationStatus {
        #if canImport(AppTrackingTransparency)
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        // Apple'ın ekleyeceği bilinmeyen durum kapalı sayılır; `unavailable` reklam iznini açık bırakırdı.
        @unknown default: return .restricted
        }
        #else
        return .unavailable
        #endif
    }

    /// `AAAttribution.attributionToken()` çağrısı. Eşzamanlıdır; `FeralinClient` bunu aktör dışında çalıştırır.
    /// Token 24 saat geçerlidir ve atıf kanıtı değildir: Apple'da kaydı olmayabilir.
    @usableFromInline
    static func adServicesToken() -> AdServicesTokenResult {
        #if canImport(AdServices) && !os(tvOS) && !os(watchOS)
        if #available(iOS 14.3, macOS 11.1, *) {
            do {
                return .token(try AAAttribution.attributionToken())
            } catch {
                return .failed("AdServices hatası: \(error.localizedDescription)")
            }
        }
        return .notSupported
        #else
        return .notSupported
        #endif
    }

    /// Dönüşüm değerini Apple'a bildirir. İnce değer 0-63 aralığındadır. SKAdNetwork iOS 16.1, AdAttributionKit iOS 17.4 ister.
    /// İzin denetimi burada yapılmaz; izinli yol `FeralinClient.updateConversionValue` yöntemidir.
    @usableFromInline
    static func updateConversionValue(
        fine: Int,
        coarse: CoarseConversionLevel,
        lock: Bool = false,
        frameworks: ConversionFrameworks = .both
    ) async -> ConversionUpdateResult {
        guard (0...63).contains(fine) else {
            let outcome = ConversionCallOutcome.failed("dönüşüm değeri 0-63 aralığında olmalı")
            return ConversionUpdateResult(adAttributionKit: outcome, skAdNetwork: outcome)
        }
        let aak: ConversionCallOutcome = frameworks.contains(.adAttributionKit)
            ? await callAdAttributionKit(fine: fine, coarse: coarse, lock: lock) : .notRequested
        let skan: ConversionCallOutcome = frameworks.contains(.skAdNetwork)
            ? await callSKAdNetwork(fine: fine, coarse: coarse, lock: lock) : .notRequested
        return ConversionUpdateResult(adAttributionKit: aak, skAdNetwork: skan)
    }

    private static func callAdAttributionKit(fine: Int, coarse: CoarseConversionLevel, lock: Bool) async -> ConversionCallOutcome {
        #if canImport(AdAttributionKit) && os(iOS)
        if #available(iOS 17.4, *) {
            let level: AdAttributionKit.CoarseConversionValue
            switch coarse {
            case .low: level = .low
            case .medium: level = .medium
            case .high: level = .high
            }
            do {
                try await Postback.updateConversionValue(fine, coarseConversionValue: level, lockPostback: lock)
                return .called
            } catch {
                return .failed("AdAttributionKit hatası: \(error.localizedDescription)")
            }
        }
        return .notSupported
        #else
        return .notSupported
        #endif
    }

    private static func callSKAdNetwork(fine: Int, coarse: CoarseConversionLevel, lock: Bool) async -> ConversionCallOutcome {
        #if canImport(StoreKit) && os(iOS)
        if #available(iOS 16.1, *) {
            let level: SKAdNetwork.CoarseConversionValue
            switch coarse {
            case .low: level = .low
            case .medium: level = .medium
            case .high: level = .high
            }
            do {
                try await SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: level, lockWindow: lock)
                return .called
            } catch {
                return .failed("SKAdNetwork hatası: \(error.localizedDescription)")
            }
        }
        return .notSupported
        #else
        return .notSupported
        #endif
    }
}
