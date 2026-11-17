//! `fr_error` sözleşmesi (X4): hata türü adı, temizlenmiş kısa mesaj, parmak izi ve sayaçlar. Kurallar Android (`ErrorEvent.kt`),
//! React Native (`signals.ts`) ve Web (`errors.ts`) SDK'larıyla aynıdır; toplayıcı (`error_adrevenue_filter.go`) mesajı ayrıca temizler
//! ve izin listesi dışı alanı düşürür.
//!
//! Ham yığın izi, kaynak dosya yolu ve kullanıcı verisi GİTMEZ. Rust hata değerleri yığın izi taşımaz; bu yüzden çerçeve listesi boştur
//! (`frame_count: 0`, `top_frame` yok) ve parmak izi tür adı ile rakamları `#` yapılmış temizlenmiş mesajdan kurulur.

use serde_json::{Map, Value};

use crate::client::Client;
use crate::error::Error;
use crate::event::{Event, TrackedEvent};

/// Hata olayı adı.
pub const ERROR_EVENT_NAME: &str = "fr_error";
/// Temizlenmiş mesajın üst sınırı (karakter).
pub const ERROR_MAX_MESSAGE: usize = 200;
const MAX_TYPE: usize = 64;
const MAX_FRAME: usize = 160;
const MAX_APP_VERSION: usize = 32;
const FINGERPRINT_FRAMES: usize = 5;
/// Süreç başına en çok hata olayı.
pub const ERROR_MAX_EVENTS: u32 = 20;
/// Aynı parmak izi için süreç başına en çok olay.
pub const ERROR_MAX_PER_FINGERPRINT: u32 = 3;

/// Hatanın nereden geldiği; toplayıcının kabul ettiği değerlerden SDK'nın üretebildikleri.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ErrorOrigin {
    /// try/catch ile yakalanan hata (`handled: true`).
    #[default]
    Handled,
    /// Uygulamanın elle bildirdiği durum (`handled: true`).
    Manual,
    /// Yakalanmamış hata (ör. uygulamanın kendi panik kancası); `handled: false`.
    UncaughtException,
}

impl ErrorOrigin {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorOrigin::Handled => "handled",
            ErrorOrigin::Manual => "manual",
            ErrorOrigin::UncaughtException => "uncaught_exception",
        }
    }
}

/// Elle kurulan hata raporu (`Client::capture_error_report`). Tür adı kod tanımlayıcısı olmalıdır (kullanıcı verisi değil).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ErrorReport {
    error_type: String,
    message: String,
    origin: ErrorOrigin,
    fatal: bool,
}

impl ErrorReport {
    pub fn new(error_type: impl Into<String>, message: impl Into<String>) -> Self {
        Self { error_type: error_type.into(), message: message.into(), origin: ErrorOrigin::Handled, fatal: false }
    }

    pub fn origin(mut self, value: ErrorOrigin) -> Self {
        self.origin = value;
        self
    }

    pub fn fatal(mut self, value: bool) -> Self {
        self.fatal = value;
        self
    }
}

/// FNV-1a 64 bit; 16 küçük harf onaltılı. UTF-8 baytları üzerinden hesaplanır (ASCII metinde Web ve RN SDK'larıyla aynı sonuç).
pub fn fnv1a64_hex(text: &str) -> String {
    let mut value: u64 = 0xCBF2_9CE4_8422_2325;
    for byte in text.bytes() {
        value = (value ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01B3);
    }
    format!("{value:016x}")
}

fn is_word(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_'
}

/// Toplayıcıdaki RE2 `\s` ile aynı: yalnız ASCII boşluk karakterleri.
fn is_space(ch: char) -> bool {
    matches!(ch, ' ' | '\t' | '\n' | '\r' | '\x0B' | '\x0C')
}

/// `\b` denetimi: `index` konumunda kelime karakteri ile kelime dışı karakter arasında geçiş var mı.
fn boundary(chars: &[char], index: usize) -> bool {
    let before = index > 0 && is_word(chars[index - 1]);
    let after = index < chars.len() && is_word(chars[index]);
    before != after
}

/// Desen eşleştiricisini soldan sağa uygular; eşleşen parça `replace` sonucuyla değişir (None ise olduğu gibi kalır).
fn replace_matches(
    text: &str,
    matcher: impl Fn(&[char], usize) -> Option<usize>,
    replace: impl Fn(&str) -> Option<&'static str>,
) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < chars.len() {
        match matcher(&chars, index) {
            Some(end) if end > index => {
                let found: String = chars[index..end].iter().collect();
                match replace(&found) {
                    Some(label) => out.push_str(label),
                    None => out.push_str(&found),
                }
                index = end;
            }
            _ => {
                out.push(chars[index]);
                index += 1;
            }
        }
    }
    out
}

/// `(?i)\b[a-z][a-z0-9+.-]*://[^\s"'<>]+`
fn match_url(chars: &[char], start: usize) -> Option<usize> {
    if !chars[start].is_ascii_alphabetic() || !boundary(chars, start) {
        return None;
    }
    let mut index = start + 1;
    while index < chars.len() && (chars[index].is_ascii_alphanumeric() || matches!(chars[index], '+' | '.' | '-')) {
        index += 1;
    }
    if chars.get(index..index + 3) != Some(&[':', '/', '/'][..]) {
        return None;
    }
    let rest = index + 3;
    let mut end = rest;
    while end < chars.len() && !is_space(chars[end]) && !matches!(chars[end], '"' | '\'' | '<' | '>') {
        end += 1;
    }
    (end > rest).then_some(end)
}

/// `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`
fn match_email(chars: &[char], start: usize) -> Option<usize> {
    let local = |ch: char| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '%' | '+' | '-');
    let mut at = start;
    while at < chars.len() && local(chars[at]) {
        at += 1;
    }
    if at == start || chars.get(at) != Some(&'@') {
        return None;
    }
    let domain_start = at + 1;
    let mut domain_end = domain_start;
    while domain_end < chars.len() && (chars[domain_end].is_ascii_alphanumeric() || matches!(chars[domain_end], '.' | '-')) {
        domain_end += 1;
    }
    // Açgözlü alan adı geri çekilir: en sağdaki uygun noktadan sonra en az iki harf.
    for dot in (domain_start + 1..domain_end).rev() {
        if chars[dot] != '.' {
            continue;
        }
        let letters = chars[dot + 1..domain_end].iter().take_while(|ch| ch.is_ascii_alphabetic()).count();
        if letters >= 2 {
            return Some(dot + 1 + letters);
        }
    }
    None
}

/// `(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`
fn match_uuid(chars: &[char], start: usize) -> Option<usize> {
    if !boundary(chars, start) {
        return None;
    }
    let mut index = start;
    for (group, length) in [8, 4, 4, 4, 12].into_iter().enumerate() {
        if group > 0 {
            if chars.get(index) != Some(&'-') {
                return None;
            }
            index += 1;
        }
        for _ in 0..length {
            if !chars.get(index).is_some_and(char::is_ascii_hexdigit) {
                return None;
            }
            index += 1;
        }
    }
    boundary(chars, index).then_some(index)
}

/// `\b[A-Za-z0-9_\-+/=]{24,}\b`
fn match_token(chars: &[char], start: usize) -> Option<usize> {
    if !boundary(chars, start) {
        return None;
    }
    let token = |ch: char| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '+' | '/' | '=');
    let mut end = start;
    while end < chars.len() && token(chars[end]) {
        end += 1;
    }
    (start + 24..=end).rev().find(|candidate| boundary(chars, *candidate))
}

/// `\+?\d[\d\s\-().]{5,}\d`
fn match_number(chars: &[char], start: usize) -> Option<usize> {
    let mut index = start;
    if chars[index] == '+' {
        index += 1;
    }
    if !chars.get(index).is_some_and(char::is_ascii_digit) {
        return None;
    }
    let middle = index + 1;
    let mut end = middle;
    while end < chars.len() && (chars[end].is_ascii_digit() || is_space(chars[end]) || matches!(chars[end], '-' | '(' | ')' | '.')) {
        end += 1;
    }
    // Son rakam ortadaki en az beş karakterden sonra gelmeli; açgözlü eşleşme en sağdaki rakamı seçer.
    (middle + 5..end).rev().find(|candidate| chars[*candidate].is_ascii_digit()).map(|last| last + 1)
}

/// Mesajdan URL, e-posta, UUID, rakam içeren uzun belirteç ve en az yedi rakamlı sayı dizilerini etiketle değiştirir; boşlukları
/// tekler, kırpar ve 200 karaktere indirir. Sıra toplayıcıyla aynıdır (URL e-postadan önce).
pub fn scrub_error_message(message: &str) -> String {
    let text = replace_matches(message, match_url, |_| Some("[url]"));
    let text = replace_matches(&text, match_email, |_| Some("[email]"));
    let text = replace_matches(&text, match_uuid, |_| Some("[id]"));
    let text = replace_matches(&text, match_token, |found| found.chars().any(|ch| ch.is_ascii_digit()).then_some("[token]"));
    let text = replace_matches(&text, match_number, |found| (found.chars().filter(char::is_ascii_digit).count() >= 7).then_some("[num]"));
    text.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(ERROR_MAX_MESSAGE).collect()
}

/// `std::any::type_name` çıktısından kısa tür adı: modül yolu ve tür argümanları atılır (`core::num::ParseIntError` → `ParseIntError`,
/// `dyn core::error::Error + Send` → `Error`). Boş kalırsa `Error`.
pub(crate) fn short_type_name(full: &str) -> String {
    let text = full.trim();
    let text = text.strip_prefix("dyn ").unwrap_or(text);
    let text = text.split(['<', ' ', '+']).next().unwrap_or("");
    let name: String = text.rsplit("::").next().unwrap_or("").trim_start_matches('&').chars().take(MAX_TYPE).collect();
    if name.is_empty() {
        "Error".to_string()
    } else {
        name
    }
}

/// Hata gövdesi: sözleşme alanlarının tamamı. `frames` normalize çerçeveler (satır, sütun ve yol içermez); Rust hatalarında boştur.
pub fn error_properties(
    error_type: &str,
    raw_message: &str,
    frames: &[String],
    origin: ErrorOrigin,
    fatal: bool,
    app_version: Option<&str>,
) -> Map<String, Value> {
    let error_type: String = error_type.trim().chars().take(MAX_TYPE).collect();
    let error_type = if error_type.is_empty() { "Error".to_string() } else { error_type };
    let message = scrub_error_message(raw_message);
    let basis = if frames.is_empty() {
        replace_matches(
            &message,
            |chars, index| {
                chars[index].is_ascii_digit().then(|| index + chars[index..].iter().take_while(|ch| ch.is_ascii_digit()).count())
            },
            |_| Some("#"),
        )
    } else {
        frames.iter().take(FINGERPRINT_FRAMES).map(String::as_str).collect::<Vec<_>>().join("|")
    };
    let mut out = Map::new();
    out.insert("fingerprint".to_string(), Value::from(fnv1a64_hex(&format!("{error_type}|{basis}"))));
    out.insert("error_type".to_string(), Value::from(error_type));
    if !message.is_empty() {
        out.insert("message".to_string(), Value::from(message));
    }
    if let Some(top) = frames.first() {
        out.insert("top_frame".to_string(), Value::from(top.chars().take(MAX_FRAME).collect::<String>()));
    }
    out.insert("frame_count".to_string(), Value::from(frames.len().min(1000)));
    if let Some(version) = app_version.filter(|version| !version.is_empty() && version.chars().count() <= MAX_APP_VERSION) {
        out.insert("app_version".to_string(), Value::from(version));
    }
    out.insert("handled".to_string(), Value::from(matches!(origin, ErrorOrigin::Handled | ErrorOrigin::Manual)));
    out.insert("fatal".to_string(), Value::from(fatal));
    out.insert("origin".to_string(), Value::from(origin.as_str()));
    out
}

/// Hata fırtınası sınırı: süreç başına en çok 20 olay, aynı parmak izi için en çok 3; örnekleme oranı 0..1.
#[derive(Debug)]
pub(crate) struct ErrorLimiter {
    sample_rate: f64,
    total: u32,
    per_fingerprint: std::collections::HashMap<String, u32>,
}

impl ErrorLimiter {
    pub(crate) fn new(sample_rate: f64) -> Self {
        let sample_rate = if sample_rate.is_nan() { 1.0 } else { sample_rate.clamp(0.0, 1.0) };
        Self { sample_rate, total: 0, per_fingerprint: std::collections::HashMap::new() }
    }

    pub(crate) fn allow(&mut self, fingerprint: &str, random: impl FnOnce() -> f64) -> bool {
        if self.total >= ERROR_MAX_EVENTS {
            return false;
        }
        if self.sample_rate < 1.0 && random() >= self.sample_rate {
            return false;
        }
        let seen = self.per_fingerprint.get(fingerprint).copied().unwrap_or(0);
        if seen >= ERROR_MAX_PER_FINGERPRINT {
            return false;
        }
        self.per_fingerprint.insert(fingerprint.to_string(), seen + 1);
        self.total += 1;
        true
    }
}

impl Client {
    /// Yakalanan bir hatayı `fr_error` olarak bildirir (`origin: handled`, `fatal: false`). Tür adı `E` türünün kısa adıdır, mesaj
    /// `Display` çıktısının temizlenmiş hâlidir; yığın izi ve kaynak zinciri gitmez. `analytics` izni yoksa, örneklemede düşerse ya da
    /// sınır (süreç başına 20, parmak izi başına 3) dolduysa olay üretilmez ve `Ok(None)` döner.
    pub fn capture_error<E: std::error::Error + ?Sized>(&self, error: &E) -> Result<Option<TrackedEvent>, Error> {
        let report = ErrorReport::new(short_type_name(std::any::type_name::<E>()), error.to_string());
        self.capture_error_report(report)
    }

    /// Elle kurulan raporu `fr_error` olarak bildirir; `capture_error` ile aynı izin, temizlik ve sınır kuralları.
    pub fn capture_error_report(&self, report: ErrorReport) -> Result<Option<TrackedEvent>, Error> {
        // İzin yoksa sınır sayacı tüketilmez.
        if !self.analytics_allowed()? {
            return Ok(None);
        }
        let properties = error_properties(&report.error_type, &report.message, &[], report.origin, report.fatal, self.app_version());
        let fingerprint = properties.get("fingerprint").and_then(Value::as_str).unwrap_or_default().to_string();
        if !self.allow_error(&fingerprint) {
            return Ok(None);
        }
        self.track(Event::new(ERROR_EVENT_NAME).properties(properties))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrub_matches_collector_rules() {
        assert_eq!(scrub_error_message("see https://x.example/a?b=1 now"), "see [url] now");
        assert_eq!(scrub_error_message("user ali.veli@example.com failed"), "user [email] failed");
        assert_eq!(scrub_error_message("id 123e4567-e89b-12d3-a456-426614174000 x"), "id [id] x");
        assert_eq!(scrub_error_message("tok abcdefghijklmnopqrstuvwx1 end"), "tok [token] end");
        assert_eq!(scrub_error_message("UnsupportedOperationExceptionLongName ok"), "UnsupportedOperationExceptionLongName ok");
        assert_eq!(scrub_error_message("call +90 (555) 123-4567 now"), "call [num] now");
        assert_eq!(scrub_error_message("version 1.4.2 and 12345"), "version 1.4.2 and 12345");
        assert_eq!(scrub_error_message("  a \n\t b  "), "a b");
        assert_eq!(scrub_error_message(&"x".repeat(500)).chars().count(), 200);
        assert_eq!(scrub_error_message("1abc://host"), "1abc://host");
    }

    #[test]
    fn fnv_matches_reference() {
        // Web SDK `fnv1a64("")` ve `fnv1a64("a")` değerleri.
        assert_eq!(fnv1a64_hex(""), "cbf29ce484222325");
        assert_eq!(fnv1a64_hex("a"), "af63dc4c8601ec8c");
    }

    #[test]
    fn short_type_names() {
        assert_eq!(short_type_name("core::num::error::ParseIntError"), "ParseIntError");
        assert_eq!(short_type_name("dyn core::error::Error + core::marker::Send"), "Error");
        assert_eq!(short_type_name("my_crate::Wrapper<alloc::string::String>"), "Wrapper");
        assert_eq!(short_type_name(""), "Error");
    }

    #[test]
    fn limiter_caps_total_and_fingerprint() {
        let mut limiter = ErrorLimiter::new(1.0);
        assert!((0..3).all(|_| limiter.allow("a", || 0.0)));
        assert!(!limiter.allow("a", || 0.0));
        for index in 0..17 {
            assert!(limiter.allow(&format!("f{index}"), || 0.0));
        }
        assert!(!limiter.allow("z", || 0.0));
        let mut sampled = ErrorLimiter::new(0.5);
        assert!(!sampled.allow("a", || 0.7));
        assert!(sampled.allow("a", || 0.2));
    }
}
