import Foundation

/// Yapılandırma ve doğrulama hataları fırlatılır. Teslim hataları `FlushResult.error` içinde döner; `flush()` ağ hatası için fırlatmaz.
public enum FeralinError: Error, Equatable, Sendable, CustomStringConvertible {
    case configuration(String)
    case invalidEvent(String)
    case clientClosed

    public var description: String {
        switch self {
        case .configuration(let message): return "yapılandırma hatası: \(message)"
        case .invalidEvent(let message): return "geçersiz olay: \(message)"
        case .clientClosed: return "istemci kapatıldı"
        }
    }
}

/// Toplayıcıya gönderim sonucu oluşan hata. `status` 0 ise ağ hatasıdır.
public enum DeliveryError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 4xx (429 hariç): batch kalıcı olarak reddedildi, olaylar kuyruktan atıldı.
    case rejected(status: Int, detail: String)
    /// 5xx, 429 veya ağ hatası: olaylar kuyrukta, aynı Idempotency-Key ile yeniden denenir.
    case temporary(status: Int, message: String)

    public var status: Int {
        switch self {
        case .rejected(let status, _), .temporary(let status, _): return status
        }
    }

    public var description: String {
        switch self {
        case .rejected(let status, let detail): return "HTTP \(status): \(detail)"
        case .temporary(let status, let message): return status == 0 ? message : "HTTP \(status): \(message)"
        }
    }
}
