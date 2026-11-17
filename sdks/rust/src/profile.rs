//! UTP §8.2 kimlik yöntemleri: `group` (`fr_group`) ve `set_user_properties` (`fr_user_properties`).
//!
//! Kurallar bütün SDK'larda ve toplayıcıda (`services/collect/internal/httpapi/profile_filter.go`) aynıdır:
//! - Anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`; çağrı başına en çok 50 özellik.
//! - Değer dizge (en çok 256 karakter, kontrol karakteri yok, e-posta biçiminde değil), sayı ya da bool; nesne, dizi ve null düşer.
//! - Doğrulama alanları (`verified`, `receipt` vb.) düşer: istemci doğrulama beyan edemez.
//! - Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) düşer.
//!
//! Toplayıcı ayrıca projenin izin listesini uygular; liste boşsa olay sayılır ama özellik saklanmaz.

use serde_json::{Map, Value};

use crate::client::Client;
use crate::error::Error;
use crate::event::{Event, TrackedEvent};

/// Grup olayı adı (Web, Node, Go ve öteki SDK'larla aynı).
pub const GROUP_EVENT_NAME: &str = "fr_group";
/// Kullanıcı özellikleri olayı adı.
pub const USER_PROPERTIES_EVENT_NAME: &str = "fr_user_properties";
/// Çağrı başına en çok özellik sayısı.
pub const MAX_PROFILE_PROPERTIES: usize = 50;
/// Dizge değerin en çok karakter (kod noktası) sayısı.
pub const MAX_PROFILE_VALUE_LENGTH: usize = 256;
/// Grup kimliğinin en çok karakter sayısı.
pub const MAX_GROUP_ID_LENGTH: usize = 128;

const RESERVED_KEYS: [&str; 6] = ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"];
// Toplayıcıdaki piiTokens, piiFragments ve piiExact listeleriyle birebir.
const PII_TOKENS: [&str; 28] = [
    "email",
    "mail",
    "phone",
    "tel",
    "telephone",
    "mobile",
    "msisdn",
    "gsm",
    "ip",
    "ipv4",
    "ipv6",
    "ssn",
    "tckn",
    "passport",
    "password",
    "iban",
    "address",
    "adres",
    "eposta",
    "telefon",
    "soyad",
    "surname",
    "firstname",
    "lastname",
    "fullname",
    "birthdate",
    "birthday",
    "dob",
];
const PII_FRAGMENTS: [&str; 12] = [
    "email",
    "phonenumber",
    "ipaddress",
    "firstname",
    "lastname",
    "fullname",
    "surname",
    "soyad",
    "eposta",
    "telefon",
    "password",
    "birthdate",
];
const PII_EXACT: [&str; 5] = ["name", "username", "displayname", "isim", "ad"];

/// Kimlik yöntemlerinde çağrı başına kimlik. `user_id` boşsa `identify` ile verilen varsayılan kullanılır.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Identity {
    pub user_id: Option<String>,
    pub anonymous_id: Option<String>,
    pub session_id: Option<String>,
}

impl Identity {
    fn apply(self, mut event: Event) -> Event {
        event.user_id = self.user_id;
        event.anonymous_id = self.anonymous_id;
        event.session_id = self.session_id;
        event
    }
}

/// Anahtarı sözcüklere böler: küçük harf ya da rakamdan sonra gelen büyük harf yeni sözcük başlatır; alt çizgi ayırıcıdır.
fn key_tokens(key: &str) -> Vec<String> {
    let chars: Vec<char> = key.chars().collect();
    let mut joined = String::with_capacity(key.len() + 4);
    for (index, ch) in chars.iter().enumerate() {
        if index > 0 && ch.is_uppercase() && (chars[index - 1].is_lowercase() || chars[index - 1].is_numeric()) {
            joined.push('_');
        }
        joined.extend(ch.to_lowercase());
    }
    joined.split('_').filter(|token| !token.is_empty()).map(str::to_string).collect()
}

/// Anahtar kişisel veriye benziyor mu (toplayıcıyla aynı kural).
pub fn is_pii_like_key(key: &str) -> bool {
    let tokens = key_tokens(key);
    if tokens.iter().any(|token| PII_TOKENS.contains(&token.as_str())) {
        return true;
    }
    let joined = tokens.concat();
    PII_EXACT.contains(&joined.as_str()) || PII_FRAGMENTS.iter().any(|fragment| joined.contains(fragment))
}

fn valid_key(key: &str) -> bool {
    let bytes = key.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_alphabetic()
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_')
        && !RESERVED_KEYS.contains(&key)
        && !is_pii_like_key(key)
}

/// `[^\s@]+@[^\s@]+\.[^\s@]+` ile aynı: `@` öncesinde boşluk ve `@` olmayan bir karakter, sonrasındaki kesintisiz parçada iki yanı dolu bir nokta.
fn looks_like_email(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();
    let plain = |ch: char| !ch.is_whitespace() && ch != '@';
    for (index, ch) in chars.iter().enumerate() {
        if *ch != '@' || index == 0 || !plain(chars[index - 1]) {
            continue;
        }
        let run: Vec<char> = chars[index + 1..].iter().copied().take_while(|ch| plain(*ch)).collect();
        if run.len() >= 3 && run[1..run.len() - 1].contains(&'.') {
            return true;
        }
    }
    false
}

fn valid_value(value: &Value) -> bool {
    match value {
        // serde_json sayısı her zaman sonludur.
        Value::Bool(_) | Value::Number(_) => true,
        Value::String(text) => {
            text.chars().count() <= MAX_PROFILE_VALUE_LENGTH && !text.chars().any(char::is_control) && !looks_like_email(text)
        }
        _ => false,
    }
}

/// Özellikleri kimlik sözleşmesine indirger; geçersiz anahtar ve değer düşer. `Map` sözlük sırasındadır: sınırı aşan fazlalık anahtar
/// bu sıraya göre düşer (Go SDK ile aynı deterministik sonuç).
pub fn sanitize_profile_properties(properties: &Map<String, Value>) -> Map<String, Value> {
    let mut out = Map::new();
    for (key, value) in properties {
        if out.len() >= MAX_PROFILE_PROPERTIES {
            break;
        }
        if valid_key(key) && valid_value(value) {
            out.insert(key.clone(), value.clone());
        }
    }
    out
}

/// Grup kimliği kuralı: 1-128 karakter, yalnız boşluk değil, `@` ve kontrol karakteri yok (kişisel veri taşımamalı).
pub fn valid_group_id(group_id: &str) -> bool {
    !group_id.trim().is_empty()
        && group_id.chars().count() <= MAX_GROUP_ID_LENGTH
        && !group_id.contains('@')
        && !group_id.chars().any(char::is_control)
}

impl Client {
    /// Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve temizlenmiş özellikler. Grup kimliği kurala
    /// uymazsa olay üretilmez ve `Error::InvalidEvent` döner. `analytics` izni yoksa `Ok(None)`.
    pub fn group(&self, group_id: &str, traits: Map<String, Value>, who: Identity) -> Result<Option<TrackedEvent>, Error> {
        if !valid_group_id(group_id) {
            return Err(Error::InvalidEvent("group_id 1-128 karakter olmalı, '@' ve kontrol karakteri içermemeli".to_string()));
        }
        let mut properties = sanitize_profile_properties(&traits);
        properties.insert("group_id".to_string(), Value::from(group_id));
        self.track(who.apply(Event::new(GROUP_EVENT_NAME).properties(properties)))
    }

    /// Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer
    /// düşer; geçerli özellik kalmazsa olay üretilmez ve `Ok(None)` döner. Toplayıcı yalnız projenin izin listesindeki anahtarları saklar.
    pub fn set_user_properties(&self, properties: Map<String, Value>, who: Identity) -> Result<Option<TrackedEvent>, Error> {
        let clean = sanitize_profile_properties(&properties);
        if clean.is_empty() {
            return Ok(None);
        }
        self.track(who.apply(Event::new(USER_PROPERTIES_EVENT_NAME).properties(clean)))
    }
}
