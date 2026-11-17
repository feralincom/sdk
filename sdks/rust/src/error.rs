use std::fmt;

/// Yapılandırma ve doğrulama hataları. Teslim hataları `FlushResult::error` içinde döner; `flush` ağ hatası için `Err` vermez.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// Geçersiz proje anahtarı, adres veya seçenek.
    Configuration(String),
    /// Olay adı, özellik veya kimlik UTP v1 kurallarına uymuyor.
    InvalidEvent(String),
    /// `close` sonrası `track` veya `flush` çağrıldı.
    ClientClosed,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Configuration(message) => write!(f, "yapılandırma hatası: {message}"),
            Error::InvalidEvent(message) => write!(f, "geçersiz olay: {message}"),
            Error::ClientClosed => write!(f, "istemci kapatıldı"),
        }
    }
}

impl std::error::Error for Error {}

/// Toplayıcıya gönderim hatası. `status` 0 ise ağ hatasıdır.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeliveryError {
    /// 4xx (429 hariç): batch kalıcı olarak reddedildi, olaylar kuyruktan atıldı.
    Rejected { status: u16, detail: String },
    /// 5xx, 429 veya ağ hatası: olaylar kuyrukta, aynı `Idempotency-Key` ile yeniden denenir.
    Temporary { status: u16, message: String },
}

impl DeliveryError {
    pub fn status(&self) -> u16 {
        match self {
            DeliveryError::Rejected { status, .. } | DeliveryError::Temporary { status, .. } => *status,
        }
    }
}

impl fmt::Display for DeliveryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DeliveryError::Rejected { status, detail } => write!(f, "HTTP {status}: {detail}"),
            DeliveryError::Temporary { status: 0, message } => write!(f, "{message}"),
            DeliveryError::Temporary { status, message } => write!(f, "HTTP {status}: {message}"),
        }
    }
}

impl std::error::Error for DeliveryError {}
