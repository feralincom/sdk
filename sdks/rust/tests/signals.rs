//! Gelir (`feralin_purchase`), kimlik (`fr_group`, `fr_user_properties`) ve hata (`fr_error`) sözleşme testleri.
use std::sync::{Arc, Mutex};
use std::time::Duration;

use feralin::{
    is_pii_like_key, revenue_properties, Client, Config, Consent, Error, ErrorOrigin, ErrorReport, Identity, PurchaseType, ReceiptProvider,
    Response, Revenue, Transport, TransportError, ERROR_EVENT_NAME, GROUP_EVENT_NAME, MAX_AMOUNT_MINOR, REVENUE_EVENT_NAME,
    USER_PROPERTIES_EVENT_NAME,
};
use serde_json::{json, Map, Value};

const TEST_KEY: &str = "pk_test_rust_0001";

struct Seen {
    body: Value,
}

/// Sahte toplayıcı: gövdeleri kaydeder, her isteğe 202 döner.
#[derive(Default)]
struct FakeCollector {
    seen: Mutex<Vec<Seen>>,
}

impl FakeCollector {
    fn request(&self, index: usize) -> Value {
        self.seen.lock().unwrap()[index].body.clone()
    }
}

impl Transport for FakeCollector {
    fn post(&self, _url: &str, body: &[u8], _headers: &[(&str, &str)], _timeout: Duration) -> Result<Response, TransportError> {
        let parsed: Value = serde_json::from_slice(body).expect("gövde geçerli JSON olmalı");
        let count = parsed["events"].as_array().unwrap().len();
        self.seen.lock().unwrap().push(Seen { body: parsed });
        Ok(Response { status: 202, body: format!("{{\"accepted\":{count},\"rejected\":0}}").into_bytes(), retry_after: None })
    }
}

fn analytics() -> Consent {
    Consent { analytics: true, ..Consent::default() }
}

fn config(collector: &Arc<FakeCollector>) -> Config {
    Config::new(TEST_KEY, "https://collect.example.test").consent(analytics()).flush_interval(Duration::ZERO).transport(collector.clone())
}

fn client(collector: &Arc<FakeCollector>) -> Client {
    Client::new(config(collector)).unwrap()
}
// ---------------------------------------------------------------- gelir (`feralin_purchase`)

#[test]
fn track_revenue_contract_drops_verification_fields() {
    let collector = Arc::new(FakeCollector::default());
    let client = client(&collector);
    let event = client
        .track_revenue(
            Revenue::new("ord_1", 4999, "TRY")
                .product_id("pro")
                .purchase_type(PurchaseType::SubscriptionStart)
                .receipt(ReceiptProvider::Stripe, "tok_1")
                .property("verified", true)
                .property("receipt_digest", "x")
                .property("plan", "pro")
                .user_id("user_42"),
        )
        .unwrap()
        .expect("izin varken olay üretilmeli");
    assert_eq!(event.payload["event_name"], REVENUE_EVENT_NAME);
    assert_eq!(event.payload["user_id"], "user_42");
    assert_eq!(
        event.payload["properties"],
        json!({
            "transaction_id": "ord_1", "amount_minor": 4999, "currency": "TRY", "quantity": 1, "purchase_type": "subscription_start",
            "product_id": "pro", "plan": "pro", "receipt": { "provider": "stripe", "token": "tok_1" }
        })
    );
    assert!(client.flush().unwrap().ok());
    let wire = &collector.request(0)["events"][0];
    assert!(wire.get("verified").is_none() && wire["properties"].get("verified").is_none());
}

#[test]
fn track_revenue_rejects_invalid_input() {
    let collector = Arc::new(FakeCollector::default());
    let client = client(&collector);
    let cases = [
        Revenue::new("", 1, "TRY"),
        Revenue::new("t".repeat(129), 1, "TRY"),
        Revenue::new("t", -1, "TRY"),
        Revenue::new("t", MAX_AMOUNT_MINOR + 1, "TRY"),
        Revenue::new("t", 1, "try"),
        Revenue::new("t", 1, "TRYX"),
        Revenue::new("t", 1, "TRY").quantity(-1),
        Revenue::new("t", 1, "TRY").quantity(100_001),
        Revenue::new("t", 1, "TRY").product_id(""),
        Revenue::new("t", 1, "TRY").receipt(ReceiptProvider::Apple, ""),
        Revenue::new("t", 1, "TRY").receipt(ReceiptProvider::Google, "x".repeat(8193)),
        Revenue::new("t", 1, "TRY").purchase_type(PurchaseType::SubscriptionCancel),
    ];
    for (index, revenue) in cases.into_iter().enumerate() {
        assert!(matches!(client.track_revenue(revenue), Err(Error::InvalidEvent(_))), "durum {index}");
    }
    assert_eq!(client.queued(), 0, "geçersiz girdi kuyruğa girmemeli");
    let cancel = revenue_properties(&Revenue::new("t", 0, "USD").purchase_type(PurchaseType::SubscriptionCancel).quantity(0)).unwrap();
    assert_eq!((cancel["amount_minor"].as_i64(), cancel["quantity"].as_i64()), (Some(0), Some(0)));
    assert_eq!(revenue_properties(&Revenue::new("t", MAX_AMOUNT_MINOR, "EUR")).unwrap()["amount_minor"].as_i64(), Some(MAX_AMOUNT_MINOR));
}

#[test]
fn track_revenue_respects_consent() {
    let collector = Arc::new(FakeCollector::default());
    let client = Client::new(config(&collector).consent(Consent::default())).unwrap();
    assert!(client.track_revenue(Revenue::new("t", 100, "TRY")).unwrap().is_none());
    assert_eq!(client.queued(), 0);
}

// ---------------------------------------------------------------- kimlik (`fr_group`, `fr_user_properties`)

#[test]
fn group_sanitizes_traits_and_validates_id() {
    let collector = Arc::new(FakeCollector::default());
    let client = client(&collector);
    let mut traits = Map::new();
    traits.insert("plan".to_string(), json!("pro"));
    traits.insert("seats".to_string(), json!(12));
    traits.insert("email".to_string(), json!("a@b.co"));
    traits.insert("full_name".to_string(), json!("Ali"));
    traits.insert("nested".to_string(), json!({ "a": 1 }));
    traits.insert("verified".to_string(), json!(true));
    let event = client
        .group("acct_1", traits, Identity { user_id: Some("user_1".to_string()), ..Identity::default() })
        .unwrap()
        .expect("izin varken olay üretilmeli");
    assert_eq!(event.payload["event_name"], GROUP_EVENT_NAME);
    assert_eq!(event.payload["user_id"], "user_1");
    assert_eq!(event.payload["properties"], json!({ "plan": "pro", "seats": 12, "group_id": "acct_1" }));
    let too_long = "g".repeat(129);
    for bad in ["", "   ", "a@b", "acct\u{0007}", too_long.as_str()] {
        assert!(matches!(client.group(bad, Map::new(), Identity::default()), Err(Error::InvalidEvent(_))), "{bad:?}");
    }
    assert_eq!(client.queued(), 1);
}

#[test]
fn set_user_properties_drops_pii_and_limits() {
    let collector = Arc::new(FakeCollector::default());
    let client = client(&collector);
    let mut props = Map::new();
    props.insert("plan".to_string(), json!("pro"));
    props.insert("beta".to_string(), json!(true));
    props.insert("phoneNumber".to_string(), json!("5551234567"));
    props.insert("note".to_string(), json!("ali@example.com"));
    props.insert("long".to_string(), json!("x".repeat(257)));
    props.insert("ctrl".to_string(), json!("a\nb"));
    props.insert("tags".to_string(), json!(["a"]));
    props.insert("bad-key".to_string(), json!(1));
    let event = client.set_user_properties(props, Identity::default()).unwrap().expect("geçerli özellik var");
    assert_eq!(event.payload["event_name"], USER_PROPERTIES_EVENT_NAME);
    assert_eq!(event.payload["properties"], json!({ "plan": "pro", "beta": true }));

    let mut only_pii = Map::new();
    only_pii.insert("email".to_string(), json!("x"));
    assert!(client.set_user_properties(only_pii, Identity::default()).unwrap().is_none(), "geçerli özellik yoksa olay yok");

    let mut many = Map::new();
    for index in 0..60 {
        many.insert(format!("k{index:02}"), json!(index));
    }
    let event = client.set_user_properties(many, Identity::default()).unwrap().unwrap();
    assert_eq!(event.payload["properties"].as_object().unwrap().len(), 50);
    assert_eq!(client.queued(), 2);
}

#[test]
fn pii_key_rule_matches_collector() {
    for key in ["email", "userEmail", "phone_number", "firstName", "ip", "name", "displayName", "tckn", "birthDate", "ev_adres"] {
        assert!(is_pii_like_key(key), "{key}");
    }
    for key in ["plan", "seats", "company_size", "ipsum", "tier"] {
        assert!(!is_pii_like_key(key), "{key}");
    }
}

// ---------------------------------------------------------------- hata (`fr_error`)

#[derive(Debug)]
struct PaymentFailed(String);

impl std::fmt::Display for PaymentFailed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for PaymentFailed {}

#[test]
fn capture_error_builds_contract_without_pii() {
    let collector = Arc::new(FakeCollector::default());
    let client = Client::new(config(&collector).app_version("2.3.4")).unwrap();
    let error = PaymentFailed("telefon +90 555 123 45 67 reddedildi, kullanıcı ali@example.com https://pay.example/x?t=1".to_string());
    let event = client.capture_error(&error).unwrap().expect("izin varken olay üretilmeli");
    assert_eq!(event.payload["event_name"], ERROR_EVENT_NAME);
    let props = event.payload["properties"].as_object().unwrap();
    assert_eq!(props["error_type"], "PaymentFailed");
    assert_eq!(props["message"], "telefon [num] reddedildi, kullanıcı [email] [url]");
    let fingerprint = props["fingerprint"].as_str().unwrap().to_string();
    assert!(fingerprint.len() == 16 && fingerprint.chars().all(|ch| ch.is_ascii_digit() || ('a'..='f').contains(&ch)));
    assert_eq!(props["frame_count"], 0);
    assert!(props.get("top_frame").is_none());
    assert_eq!(props["app_version"], "2.3.4");
    assert_eq!(
        (props["handled"].as_bool(), props["fatal"].as_bool(), props["origin"].as_str()),
        (Some(true), Some(false), Some("handled"))
    );
    let allowed =
        ["error_type", "message", "fingerprint", "top_frame", "frame_count", "app_version", "handled", "fatal", "origin", "frames"];
    assert!(props.keys().all(|key| allowed.contains(&key.as_str())), "{props:?}");

    // Aynı tür ve yalnız PII parçaları farklı mesaj aynı parmak izini üretir.
    let other = client.capture_error(&PaymentFailed(
        "telefon +90 532 765 43 21 reddedildi, kullanıcı veli@example.com https://pay.example/y".to_string(),
    ));
    assert_eq!(other.unwrap().unwrap().payload["properties"]["fingerprint"], fingerprint.as_str());

    let parse = "x".parse::<i32>().unwrap_err();
    let parsed = client.capture_error(&parse).unwrap().unwrap();
    assert_eq!(parsed.payload["properties"]["error_type"], "ParseIntError");
    let boxed: Box<dyn std::error::Error + Send + Sync> = Box::new(PaymentFailed("x".to_string()));
    assert_eq!(client.capture_error(boxed.as_ref()).unwrap().unwrap().payload["properties"]["error_type"], "Error");

    assert!(client.flush().unwrap().ok());
    let wire = &collector.request(0)["events"][0];
    assert_eq!(wire["event_name"], "fr_error");
}

#[test]
fn capture_error_report_origin_and_limits() {
    let collector = Arc::new(FakeCollector::default());
    let client = Client::new(config(&collector).app_version("v".repeat(33)).queue_limit(100)).unwrap();
    let fatal =
        client.capture_error_report(ErrorReport::new("Panic", "boom").origin(ErrorOrigin::UncaughtException).fatal(true)).unwrap().unwrap();
    let props = &fatal.payload["properties"];
    assert_eq!(
        (props["handled"].as_bool(), props["fatal"].as_bool(), props["origin"].as_str()),
        (Some(false), Some(true), Some("uncaught_exception"))
    );
    assert!(props.get("app_version").is_none(), "32 karakteri aşan sürüm gönderilmez");
    let manual = client.capture_error_report(ErrorReport::new("", "").origin(ErrorOrigin::Manual)).unwrap().unwrap();
    assert_eq!(manual.payload["properties"]["error_type"], "Error");
    assert!(manual.payload["properties"].get("message").is_none());
    assert_eq!(manual.payload["properties"]["handled"], true);

    // Aynı parmak izi en çok 3 kez.
    let same: Vec<bool> = (0..5).map(|_| client.capture_error_report(ErrorReport::new("Same", "x")).unwrap().is_some()).collect();
    assert_eq!(same, [true, true, true, false, false]);
    // Süreç başına en çok 20 olay: şimdiye kadar 5 (1 + 1 + 3).
    let distinct =
        (0..30).filter(|index| client.capture_error_report(ErrorReport::new(format!("E{index}"), "x")).unwrap().is_some()).count();
    assert_eq!(distinct, 15);
    assert_eq!(client.queued(), 20);
}

#[test]
fn capture_error_requires_consent_and_sampling() {
    let collector = Arc::new(FakeCollector::default());
    let client = Client::new(config(&collector).consent(Consent::default())).unwrap();
    // İzin yokken sınır sayacı tüketilmez.
    for _ in 0..25 {
        assert!(client.capture_error(&PaymentFailed("x".to_string())).unwrap().is_none());
    }
    client.set_consent(analytics());
    assert!(client.capture_error(&PaymentFailed("x".to_string())).unwrap().is_some());

    let sampled = Client::new(config(&collector).error_sample_rate(0.0)).unwrap();
    assert!(sampled.capture_error(&PaymentFailed("x".to_string())).unwrap().is_none());
    assert_eq!(sampled.queued(), 0);
    sampled.close(Duration::from_millis(10));
    assert!(matches!(sampled.capture_error(&PaymentFailed("x".to_string())), Err(Error::ClientClosed)));
}
