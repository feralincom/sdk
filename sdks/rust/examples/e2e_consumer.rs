//! Gerçek services/collect tüketicisi: scripts/sdk-e2e/run.mjs rust tarafından çalıştırılır.
//! Denetim satırları sdks/android/scripts/outbox_check.go ile PostgreSQL üzerinde doğrulanır.
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use feralin::{idempotency_key_for, Client, Config, Consent, DeliveryError, Event, Response, Transport, TransportError, UreqTransport};
use serde_json::Value;

fn must(condition: bool, message: &str) {
    if !condition {
        eprintln!("KALDI: {message}");
        std::process::exit(1);
    }
}

fn expect(checks: &str, line: &str) {
    let mut file = OpenOptions::new().create(true).append(true).open(checks).expect("denetim dosyası açılamadı");
    writeln!(file, "{line}").expect("denetim satırı yazılamadı");
}

fn make(url: &str, key: &str, consent: Consent, transport: Option<Arc<dyn Transport>>) -> Client {
    let mut config = Config::new(key, url).consent(consent).flush_interval(Duration::ZERO);
    if let Some(transport) = transport {
        config = config.transport(transport);
    }
    Client::new(config).expect("istemci kurulamadı")
}

/// İlk yanıtı kaybeden taşıma: sunucu yazar ama istemci yanıtı görmez.
struct Lossy {
    inner: UreqTransport,
    keys: Mutex<Vec<String>>,
}

impl Transport for Lossy {
    fn post(&self, url: &str, body: &[u8], headers: &[(&str, &str)], timeout: Duration) -> Result<Response, TransportError> {
        let key = headers.iter().find(|(name, _)| *name == "Idempotency-Key").map_or("", |(_, value)| *value).to_string();
        let attempt = {
            let mut keys = self.keys.lock().unwrap();
            keys.push(key);
            keys.len()
        };
        let response = self.inner.post(url, body, headers, timeout)?;
        if attempt == 1 {
            return Err(TransportError { message: "yanıt yolda kayboldu".to_string() });
        }
        Ok(response)
    }
}

fn main() {
    let url = std::env::var("FERALIN_E2E_COLLECT_URL").expect("FERALIN_E2E_COLLECT_URL");
    let key = std::env::var("FERALIN_E2E_PROJECT_KEY").expect("FERALIN_E2E_PROJECT_KEY");
    let checks = std::env::var("FERALIN_E2E_CHECKS").expect("FERALIN_E2E_CHECKS");
    let analytics = Consent { analytics: true, ..Consent::default() };

    // 202 + outbox satırı + fr_click reklam izniyle
    let client = make(&url, &key, Consent { analytics: true, advertising: true, ..Consent::default() }, None);
    let event = client
        .track(Event::new("order_completed").property("order_id", "ord_rs_1").property("fr_click", "clk_rs_1").user_id("user_rs_1"))
        .unwrap()
        .expect("izinle olay üretilmeliydi");
    let result = client.flush().unwrap();
    must(result.status == 202 && result.accepted == 1, "202 bekleniyordu");
    expect(&checks, &format!("frclick {}", result.batch_id.clone().unwrap_or_default()));
    expect(&checks, &format!("once {}", event.event_id));
    println!("  OK 202-outbox-frclick: {}", result.status);

    // Reklam izni yok: fr_click çıkarılır
    let client = make(&url, &key, analytics, None);
    let event =
        client.track(Event::new("order_completed").property("order_id", "ord_rs_2").property("fr_click", "clk_rs_2")).unwrap().unwrap();
    must(event.payload["properties"].get("fr_click").is_none(), "fr_click çıkarılmalıydı");
    let result = client.flush().unwrap();
    must(result.status == 202, "202 bekleniyordu");
    expect(&checks, &format!("nofrclick {}", result.batch_id.clone().unwrap_or_default()));
    println!("  OK frclick-izinsiz-cikarildi: {}", result.status);

    // İzinsiz: SDK olay üretmez
    let client = make(&url, &key, Consent::default(), None);
    must(
        client.track(Event::new("order_completed")).unwrap().is_none() && client.flush().unwrap().sent == 0,
        "izinsiz olay üretilmemeliydi",
    );
    println!("  OK izinsiz-sdk-uretmez: 0");

    // İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let event_id: String = format!("01JCRS{nanos:020}").chars().take(26).collect();
    let body = format!(
        "{{\"events\":[{{\"event_id\":\"{event_id}\",\"event_name\":\"denied_event\",\"occurred_at\":\"2026-11-06T10:00:00Z\",\"platform\":\"rust\",\"schema_version\":1,\"consent\":{{\"analytics\":false}}}}]}}"
    );
    let idempotency = idempotency_key_for(&[event_id.as_str()]);
    let headers =
        [("Content-Type", "application/json"), ("X-Feralin-Project-Key", key.as_str()), ("Idempotency-Key", idempotency.as_str())];
    let response = UreqTransport::new().post(&format!("{url}/v1/batch"), body.as_bytes(), &headers, Duration::from_secs(10)).unwrap();
    let denied: Value = serde_json::from_slice(&response.body).unwrap();
    must(
        response.status == 202 && denied["accepted"] == 0 && denied["rejected_reasons"]["consent_denied"] == 1,
        "toplayıcı izinsiz olayı reddetmeliydi",
    );
    expect(&checks, &format!("absent {event_id}"));
    println!("  OK izinsiz-toplayici-red");

    // Yanlış anahtar: 401, olay atılır, uygulama düşmez
    let client = make(&url, "pk_test_wrong_key_000", analytics, None);
    let event = client.track(Event::new("order_completed").property("order_id", "ord_rs_wrong")).unwrap().unwrap();
    let result = client.flush().unwrap();
    must(
        matches!(result.error, Some(DeliveryError::Rejected { status: 401, .. })) && result.rejected == 1 && client.queued() == 0,
        "401 bekleniyordu",
    );
    expect(&checks, &format!("absent {}", event.event_id));
    println!("  OK yanlis-anahtar-401: {}", result.status);

    // Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
    let lossy = Arc::new(Lossy { inner: UreqTransport::new(), keys: Mutex::new(Vec::new()) });
    let client = make(&url, &key, analytics, Some(lossy.clone()));
    let first = client.track(Event::new("order_completed").property("order_id", "ord_rs_retry")).unwrap().unwrap();
    let lost = client.flush().unwrap();
    must(matches!(lost.error, Some(DeliveryError::Temporary { .. })) && client.queued() == 1, "yanıt kaybı kuyrukta tutulmalıydı");
    let second = client.track(Event::new("order_shipped").property("order_id", "ord_rs_retry")).unwrap().unwrap();
    let result = client.flush().unwrap();
    must(result.ok() && result.status == 202 && client.queued() == 0, "tekrar 202 vermeliydi");
    {
        let keys = lossy.keys.lock().unwrap();
        must(keys.len() == 3 && keys[0] == keys[1], "aynı anahtar bekleniyordu");
        println!("  OK idempotency-tekrar: {}", keys[0]);
    }
    expect(&checks, &format!("once {}", first.event_id));
    expect(&checks, &format!("once {}", second.event_id));

    println!("rust tüketici: tüm senaryolar geçti");
}
