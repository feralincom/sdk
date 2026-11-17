use std::time::SystemTime;

use serde_json::{json, Map, Value};

use crate::error::{DeliveryError, Error};

pub(crate) const MAX_EVENT_NAME_LENGTH: usize = 100;
pub(crate) const MAX_PROPERTIES: usize = 100;
pub(crate) const MAX_IDENTIFIER_LENGTH: usize = 128;
/// Reklam izni yoksa olaydan çıkarılan özellik.
pub const ATTRIBUTION_CLICK_PROPERTY: &str = "fr_click";

/// İzin anlık görüntüsü. `analytics` false ise hiçbir olay üretilmez. Varsayılan hepsi kapalıdır.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Consent {
    pub analytics: bool,
    pub advertising: bool,
    pub personalization: bool,
    pub session_replay: bool,
}

impl Consent {
    pub(crate) fn to_json(self) -> Value {
        json!({
            "analytics": self.analytics,
            "advertising": self.advertising,
            "personalization": self.personalization,
            "session_replay": self.session_replay,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Screen {
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AppInfo {
    pub version: Option<String>,
    pub build: Option<String>,
}

/// Şemadaki `context` nesnesi; yalnız dolu alanlar gönderilir. SDK cihazdan kendiliğinden context toplamaz.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Context {
    pub page_url: Option<String>,
    pub page_title: Option<String>,
    pub referrer: Option<String>,
    pub locale: Option<String>,
    pub timezone: Option<String>,
    pub screen: Option<Screen>,
    pub app: Option<AppInfo>,
}

impl Context {
    pub(crate) fn to_json(&self) -> Map<String, Value> {
        let mut out = Map::new();
        let texts = [
            ("page_url", &self.page_url),
            ("page_title", &self.page_title),
            ("referrer", &self.referrer),
            ("locale", &self.locale),
            ("timezone", &self.timezone),
        ];
        for (key, value) in texts {
            if let Some(text) = value.as_deref().filter(|text| !text.is_empty()) {
                out.insert(key.to_string(), Value::from(text));
            }
        }
        if let Some(screen) = self.screen {
            out.insert("screen".to_string(), json!({ "width": screen.width, "height": screen.height }));
        }
        if let Some(app) = &self.app {
            let mut info = Map::new();
            if let Some(version) = app.version.as_deref().filter(|text| !text.is_empty()) {
                info.insert("version".to_string(), Value::from(version));
            }
            if let Some(build) = app.build.as_deref().filter(|text| !text.is_empty()) {
                info.insert("build".to_string(), Value::from(build));
            }
            if !info.is_empty() {
                out.insert("app".to_string(), Value::Object(info));
            }
        }
        out
    }
}

/// `Client::track` girdisi.
#[derive(Debug, Clone, Default)]
pub struct Event {
    pub(crate) name: String,
    pub(crate) properties: Map<String, Value>,
    pub(crate) user_id: Option<String>,
    pub(crate) anonymous_id: Option<String>,
    pub(crate) session_id: Option<String>,
    pub(crate) occurred_at: Option<SystemTime>,
    pub(crate) context: Option<Context>,
}

impl Event {
    pub fn new(name: impl Into<String>) -> Self {
        Self { name: name.into(), ..Self::default() }
    }

    /// Tek özellik ekler. `serde_json` `NaN` ve sonsuz değeri `null` yapar; bu değerler için hata alınmaz.
    pub fn property(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.properties.insert(key.into(), value.into());
        self
    }

    pub fn properties(mut self, properties: Map<String, Value>) -> Self {
        self.properties.extend(properties);
        self
    }

    /// Yalnız uygulamanın kendi opak kimliği verilir, e-posta verilmez.
    pub fn user_id(mut self, value: impl Into<String>) -> Self {
        self.user_id = Some(value.into());
        self
    }

    pub fn anonymous_id(mut self, value: impl Into<String>) -> Self {
        self.anonymous_id = Some(value.into());
        self
    }

    pub fn session_id(mut self, value: impl Into<String>) -> Self {
        self.session_id = Some(value.into());
        self
    }

    pub fn occurred_at(mut self, value: SystemTime) -> Self {
        self.occurred_at = Some(value);
        self
    }

    pub fn context(mut self, value: Context) -> Self {
        self.context = Some(value);
        self
    }
}

/// Kuyruğa giren olay: `payload` tel üzerinde giden JSON'dur.
#[derive(Debug, Clone, PartialEq)]
pub struct TrackedEvent {
    pub event_id: String,
    pub payload: Value,
}

/// Bir `flush` çağrısının toplu sonucu.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FlushResult {
    pub sent: usize,
    pub accepted: usize,
    pub rejected: usize,
    pub batch_id: Option<String>,
    pub status: u16,
    pub retained: usize,
    pub error: Option<DeliveryError>,
}

impl FlushResult {
    pub fn ok(&self) -> bool {
        self.error.is_none()
    }
}

/// Web, Node, .NET, Android ve Python SDK'larıyla aynı anahtar: sıralı tüm `event_id` değerlerinin FNV-1a 64 özeti ve sayı.
pub fn idempotency_key_for<S: AsRef<str>>(event_ids: &[S]) -> String {
    let mut ordered: Vec<&str> = event_ids.iter().map(|id| id.as_ref()).collect();
    ordered.sort_unstable();
    let mut value: u64 = 0xCBF2_9CE4_8422_2325;
    for byte in ordered.join(",").bytes() {
        value = (value ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01B3);
    }
    format!("{value:016x}-{}", ordered.len())
}

pub(crate) fn validate_event_name(name: &str) -> Result<(), Error> {
    let bytes = name.as_bytes();
    let valid = !bytes.is_empty()
        && bytes.len() <= MAX_EVENT_NAME_LENGTH
        && bytes[0].is_ascii_lowercase()
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_');
    if valid {
        Ok(())
    } else {
        Err(Error::InvalidEvent("event_name snake_case olmalı (^[a-z][a-z0-9_]*$, en fazla 100 karakter)".to_string()))
    }
}

pub(crate) fn validate_properties(properties: &Map<String, Value>) -> Result<(), Error> {
    if properties.len() > MAX_PROPERTIES {
        return Err(Error::InvalidEvent(format!("properties en fazla 100 anahtar içerebilir ({} verildi)", properties.len())));
    }
    for key in properties.keys() {
        let bytes = key.as_bytes();
        let valid = !bytes.is_empty()
            && bytes.len() <= 64
            && bytes[0].is_ascii_alphabetic()
            && bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_');
        if !valid {
            return Err(Error::InvalidEvent("properties anahtarı ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ desenine uymalı".to_string()));
        }
    }
    Ok(())
}

/// Boş kimlik yok sayılır; uzun kimlik reddedilir.
pub(crate) fn validate_identifier(value: Option<String>, field: &str) -> Result<Option<String>, Error> {
    match value {
        None => Ok(None),
        Some(text) if text.is_empty() => Ok(None),
        Some(text) if text.chars().count() > MAX_IDENTIFIER_LENGTH => {
            Err(Error::InvalidEvent(format!("{field} en fazla 128 karakter olmalı")))
        }
        Some(text) => Ok(Some(text)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idempotency_key_matches_other_sdks() {
        assert_eq!(idempotency_key_for(&["01JC0000000000000000000002", "01JC0000000000000000000001"]), "8f95d6b736d56c98-2");
    }

    #[test]
    fn context_omits_empty_fields() {
        let context = Context {
            locale: Some("tr-TR".to_string()),
            timezone: Some(String::new()),
            app: Some(AppInfo { version: Some("1.2.3".to_string()), build: None }),
            ..Context::default()
        };
        assert_eq!(Value::Object(context.to_json()), json!({ "locale": "tr-TR", "app": { "version": "1.2.3" } }));
        assert!(Context::default().to_json().is_empty());
    }
}
