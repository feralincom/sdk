use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use feralin::{
    idempotency_key_for, is_ulid, AppInfo, Client, Config, Consent, Context, DeliveryError, Error, Event, Response, Transport,
    TransportError, MAX_BATCH_SIZE, SDK_VERSION,
};
use serde_json::{json, Map, Value};

const TEST_KEY: &str = "pk_test_rust_0001";

enum Step {
    Respond(u16, &'static str, Option<&'static str>),
    Fail(&'static str),
}

#[derive(Clone)]
struct Seen {
    url: String,
    body: Value,
    headers: Vec<(String, String)>,
}

impl Seen {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str())
    }

    fn event_ids(&self) -> Vec<String> {
        self.body["events"].as_array().unwrap().iter().map(|event| event["event_id"].as_str().unwrap().to_string()).collect()
    }
}

/// Sahte toplayıcı: istekleri kaydeder, sıradaki yanıtı döner; sıra bitince 202.
#[derive(Default)]
struct FakeCollector {
    steps: Mutex<VecDeque<Step>>,
    seen: Mutex<Vec<Seen>>,
}

impl FakeCollector {
    fn with(steps: Vec<Step>) -> Arc<Self> {
        Arc::new(Self { steps: Mutex::new(steps.into()), seen: Mutex::default() })
    }

    fn count(&self) -> usize {
        self.seen.lock().unwrap().len()
    }

    fn request(&self, index: usize) -> Seen {
        self.seen.lock().unwrap()[index].clone()
    }
}

impl Transport for FakeCollector {
    fn post(&self, url: &str, body: &[u8], headers: &[(&str, &str)], _timeout: Duration) -> Result<Response, TransportError> {
        let parsed: Value = serde_json::from_slice(body).expect("gövde geçerli JSON olmalı");
        let count = parsed["events"].as_array().unwrap().len();
        self.seen.lock().unwrap().push(Seen {
            url: url.to_string(),
            body: parsed,
            headers: headers.iter().map(|(key, value)| (key.to_string(), value.to_string())).collect(),
        });
        match self.steps.lock().unwrap().pop_front() {
            Some(Step::Respond(status, body, retry_after)) => {
                Ok(Response { status, body: body.as_bytes().to_vec(), retry_after: retry_after.map(str::to_string) })
            }
            Some(Step::Fail(message)) => Err(TransportError { message: message.to_string() }),
            None => Ok(Response {
                status: 202,
                body: format!("{{\"accepted\":{count},\"rejected\":0,\"batch_id\":\"01TESTBATCH0000000000000000\"}}").into_bytes(),
                retry_after: None,
            }),
        }
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

fn configuration_error(key: &str, url: &str) -> bool {
    matches!(Client::new(Config::new(key, url).flush_interval(Duration::ZERO)), Err(Error::Configuration(_)))
}

#[test]
fn rejects_secret_and_non_public_keys() {
    assert!(configuration_error("sk_live_abcdefgh", "https://collect.example.test"));
    assert!(configuration_error("dev_key_change_me_0001", "https://collect.example.test"));
    assert!(configuration_error("", "https://collect.example.test"));
}

#[test]
fn rejects_bad_collect_url() {
    assert!(configuration_error(TEST_KEY, "collect.example.test"));
    assert!(configuration_error(TEST_KEY, "ftp://collect.example.test"));
    assert!(configuration_error(TEST_KEY, "https://"));
}

#[test]
fn endpoint_is_built_from_root_and_status_hides_key() {
    let collector = Arc::new(FakeCollector::default());
    let client =
        Client::new(Config::new(TEST_KEY, "https://collect.example.test/").flush_interval(Duration::ZERO).transport(collector)).unwrap();
    let status = client.status();
    assert_eq!(status.endpoint, "https://collect.example.test/v1/batch");
    assert!(!format!("{status:?}").contains("pk_"));
}

#[test]
fn track_and_flush_are_accepted() {
    let collector = Arc::new(FakeCollector::default());
    let client = client(&collector);
    client.identify(Some("user_42".to_string())).unwrap();
    let context = Context {
        locale: Some("tr-TR".to_string()),
        timezone: Some("Europe/Istanbul".to_string()),
        app: Some(AppInfo { version: Some("1.2.3".to_string()), build: None }),
        ..Context::default()
    };
    let event = client
        .track(
            Event::new("order_completed")
                .property("order_id", "ord_1")
                .property("amount", 12.5)
                .property("items", 2)
                .anonymous_id("anon_1")
                .session_id("ses_1")
                .context(context),
        )
        .unwrap()
        .expect("izin varken olay üretilmeli");
    assert_eq!(event.payload["user_id"], "user_42");
    assert_eq!(client.queued(), 1);

    let result = client.flush().unwrap();
    assert!(result.ok(), "{:?}", result.error);
    assert_eq!((result.status, result.sent, result.accepted, result.rejected), (202, 1, 1, 0));
    assert_eq!(result.batch_id.as_deref(), Some("01TESTBATCH0000000000000000"));
    assert_eq!(client.queued(), 0);
    assert_eq!(collector.count(), 1);

    let request = collector.request(0);
    assert_eq!(request.url, "https://collect.example.test/v1/batch");
    assert_eq!(request.header("X-Feralin-Project-Key"), Some(TEST_KEY));
    assert_eq!(request.header("Idempotency-Key"), Some(idempotency_key_for(&[event.event_id.as_str()]).as_str()));
    assert_eq!(request.header("Content-Type"), Some("application/json"));
    assert!(request.body["sent_at"].is_string());

    let wire = &request.body["events"][0];
    assert_eq!(wire["event_id"], event.event_id.as_str());
    assert!(is_ulid(wire["event_id"].as_str().unwrap()));
    assert_eq!(wire["platform"], "rust");
    assert_eq!(wire["schema_version"], 1);
    assert_eq!(wire["sdk"], json!({ "name": "feralin-rust", "version": SDK_VERSION }));
    assert_eq!(wire["user_id"], "user_42");
    assert_eq!(wire["anonymous_id"], "anon_1");
    assert_eq!(wire["session_id"], "ses_1");
    assert_eq!(wire["properties"], json!({ "order_id": "ord_1", "amount": 12.5, "items": 2 }));
    assert_eq!(wire["context"], json!({ "locale": "tr-TR", "timezone": "Europe/Istanbul", "app": { "version": "1.2.3" } }));
    assert_eq!(wire["consent"], json!({ "analytics": true, "advertising": false, "personalization": false, "session_replay": false }));
    for forbidden in ["tenant_id", "project_id", "verified", "source_ip", "ip"] {
        assert!(wire.get(forbidden).is_none(), "gönderilmemeli: {forbidden}");
    }
}

#[test]
fn optional_fields_are_omitted() {
    let collector = Arc::new(FakeCollector::default());
    let client = client(&collector);
    let event = client.track(Event::new("signup")).unwrap().unwrap();
    for key in ["user_id", "anonymous_id", "session_id", "properties", "context"] {
        assert!(event.payload.get(key).is_none(), "{key}");
    }
}

#[test]
fn temporary_failure_keeps_queue_and_idempotency_key() {
    let collector = FakeCollector::with(vec![
        Step::Respond(503, r#"{"title":"Outbox yazılamadı"}"#, Some("5")),
        Step::Respond(429, r#"{"title":"Çok fazla istek"}"#, Some("1")),
    ]);
    let client = client(&collector);
    let event = client.track(Event::new("signup")).unwrap().unwrap();

    let result = client.flush().unwrap();
    assert!(matches!(result.error, Some(DeliveryError::Temporary { status: 503, .. })));
    assert_eq!((result.status, result.retained, client.queued()), (503, 1, 1));
    assert_eq!(client.status().backoff, Duration::from_secs(5));

    let result = client.flush().unwrap();
    assert!(matches!(result.error, Some(DeliveryError::Temporary { status: 429, .. })));
    assert_eq!(client.status().backoff, Duration::from_secs(10));

    let result = client.flush().unwrap();
    assert!(result.ok());
    assert_eq!((result.status, client.queued()), (202, 0));
    assert_eq!(client.status().backoff, Duration::ZERO);

    assert_eq!(collector.count(), 3);
    let expected = idempotency_key_for(&[event.event_id.as_str()]);
    for index in 0..3 {
        assert_eq!(collector.request(index).header("Idempotency-Key"), Some(expected.as_str()));
    }
}

#[test]
fn backoff_is_exponential_and_capped() {
    let collector = FakeCollector::with((0..7).map(|_| Step::Respond(503, "{}", None)).collect());
    let client = client(&collector);
    client.track(Event::new("signup")).unwrap();
    let mut seen = Vec::new();
    for _ in 0..7 {
        client.flush().unwrap();
        seen.push(client.status().backoff.as_secs());
    }
    assert_eq!(seen, [1, 2, 4, 8, 16, 30, 30]);
}

#[test]
fn fr_click_requires_advertising_consent() {
    let collector = Arc::new(FakeCollector::default());
    let client = client(&collector);
    let event = client.track(Event::new("order_completed").property("fr_click", "clk").property("order_id", "o1")).unwrap().unwrap();
    assert_eq!(event.payload["properties"], json!({ "order_id": "o1" }));
    let event = client.track(Event::new("order_completed").property("fr_click", "clk")).unwrap().unwrap();
    assert!(event.payload.get("properties").is_none());
    client.set_consent(Consent { analytics: true, advertising: true, ..Consent::default() });
    let event = client.track(Event::new("order_completed").property("fr_click", "clk")).unwrap().unwrap();
    assert_eq!(event.payload["properties"]["fr_click"], "clk");
}

#[test]
fn pinned_batch_keeps_content_across_retries() {
    let collector = FakeCollector::with(vec![Step::Fail("yanıt yolda kayboldu")]);
    let client = client(&collector);
    let first = client.track(Event::new("first_event")).unwrap().unwrap();
    assert!(!client.flush().unwrap().ok());
    let second = client.track(Event::new("second_event")).unwrap().unwrap();
    assert!(client.flush().unwrap().ok());
    assert_eq!(collector.count(), 3);
    let key = idempotency_key_for(&[first.event_id.as_str()]);
    assert_eq!(collector.request(0).header("Idempotency-Key"), Some(key.as_str()));
    assert_eq!(collector.request(1).header("Idempotency-Key"), Some(key.as_str()));
    assert_eq!(collector.request(2).header("Idempotency-Key"), Some(idempotency_key_for(&[second.event_id.as_str()]).as_str()));
}

#[test]
fn network_error_keeps_queue() {
    let collector = FakeCollector::with(vec![Step::Fail("ağ hatası: bağlantı yok")]);
    let client = client(&collector);
    client.track(Event::new("ping")).unwrap();
    let result = client.flush().unwrap();
    assert_eq!(result.error, Some(DeliveryError::Temporary { status: 0, message: "ağ hatası: bağlantı yok".to_string() }));
    assert_eq!((result.status, client.queued()), (0, 1));
    assert_eq!(client.status().backoff, Duration::from_secs(1));
}

#[test]
fn permanent_rejection_drops_events() {
    let collector = FakeCollector::with(vec![Step::Respond(401, r#"{"title":"Geçersiz anahtar","detail":"x"}"#, None)]);
    let client = client(&collector);
    client.track(Event::new("order_completed")).unwrap();
    let result = client.flush().unwrap();
    assert_eq!(result.error, Some(DeliveryError::Rejected { status: 401, detail: "Geçersiz anahtar x".to_string() }));
    assert_eq!((result.status, result.rejected, client.queued()), (401, 1, 0));
    assert!(client.flush().unwrap().ok());
    assert_eq!(collector.count(), 1, "atılan olay yeniden gönderilmemeli");
}

#[test]
fn consent_gate() {
    let collector = Arc::new(FakeCollector::default());
    let client =
        Client::new(Config::new(TEST_KEY, "https://collect.example.test").flush_interval(Duration::ZERO).transport(collector.clone()))
            .unwrap();
    assert!(client.track(Event::new("page_view")).unwrap().is_none());
    assert_eq!(client.queued(), 0);

    client.set_consent(analytics());
    assert!(client.track(Event::new("page_view")).unwrap().is_some());
    assert_eq!(client.queued(), 1);

    client.set_consent(Consent::default());
    assert_eq!(client.queued(), 0, "izin geri çekilince kuyruk temizlenmeli");
    assert!(client.flush().unwrap().ok());
    assert_eq!(collector.count(), 0, "izin yokken sunucuya istek gitmemeli");
}

#[test]
fn validation() {
    let collector = Arc::new(FakeCollector::default());
    let client = client(&collector);
    let too_long = "a".repeat(101);
    for name in ["", "orderCompleted", "1_event", too_long.as_str(), "has-dash"] {
        assert!(matches!(client.track(Event::new(name)), Err(Error::InvalidEvent(_))), "{name}");
    }
    let invalid = |event: Event| matches!(client.track(event), Err(Error::InvalidEvent(_)));
    assert!(invalid(Event::new("ok").property("1bad", 1)));
    assert!(invalid(Event::new("ok").property("bad-key", 1)));
    assert!(invalid(Event::new("ok").property(format!("a{}", "b".repeat(64)), 1)));
    let mut many = Map::new();
    for index in 0..101 {
        many.insert(format!("k{index}"), Value::from(index));
    }
    assert!(invalid(Event::new("ok").properties(many.clone())));
    assert!(invalid(Event::new("ok").user_id("u".repeat(129))));
    assert!(matches!(client.identify(Some("u".repeat(129))), Err(Error::InvalidEvent(_))));
    assert_eq!(client.queued(), 0, "geçersiz olaylar kuyruğa girmemeli");

    many.remove("k100");
    assert!(client.track(Event::new("ok").properties(many)).unwrap().is_some());
    assert!(client.track(Event::new("fr_system_event_9").property("Camel_Key9", "x")).unwrap().is_some());
    assert_eq!(client.queued(), 2);
}

#[test]
fn queue_limit_drops_oldest() {
    let collector = Arc::new(FakeCollector::default());
    let client = Client::new(config(&collector).batch_size(10).queue_limit(3)).unwrap();
    let ids: Vec<String> = (0..5).map(|_| client.track(Event::new("e")).unwrap().unwrap().event_id).collect();
    assert_eq!((client.queued(), client.status().dropped), (3, 2));
    assert!(client.flush().unwrap().ok());
    assert_eq!(collector.request(0).event_ids(), ids[2..]);
}

#[test]
fn batch_splitting() {
    let collector = Arc::new(FakeCollector::default());
    let client = Client::new(config(&collector).batch_size(2).queue_limit(100)).unwrap();
    for _ in 0..5 {
        client.track(Event::new("e")).unwrap();
    }
    let result = client.flush().unwrap();
    assert!(result.ok());
    assert_eq!((result.sent, result.accepted, client.queued()), (5, 5, 0));
    assert_eq!(collector.count(), 3);
    let first = collector.request(0);
    assert_eq!(first.event_ids().len(), 2);
    assert_eq!(first.header("Idempotency-Key"), Some(idempotency_key_for(&first.event_ids()).as_str()));
    assert_eq!(collector.request(2).event_ids().len(), 1);
}

fn wait_until(limit: Duration, condition: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    condition()
}

#[test]
fn background_flush() {
    let collector = Arc::new(FakeCollector::default());
    let client = Client::new(config(&collector).flush_interval(Duration::from_millis(20))).unwrap();
    client.track(Event::new("bg")).unwrap();
    assert!(wait_until(Duration::from_secs(3), || client.queued() == 0), "arka plan gönderici 3 sn içinde göndermedi");
    assert!(collector.count() >= 1);
    client.close(Duration::from_secs(1));
}

#[test]
fn full_batch_wakes_background_flush() {
    let collector = Arc::new(FakeCollector::default());
    let client = Client::new(config(&collector).flush_interval(Duration::from_secs(3600)).batch_size(2)).unwrap();
    client.track(Event::new("a")).unwrap();
    client.track(Event::new("b")).unwrap();
    assert!(wait_until(Duration::from_secs(3), || collector.count() == 1), "dolu batch göndericiyi uyandırmalı");
    client.close(Duration::from_secs(1));
}

#[test]
fn background_flush_respects_backoff() {
    let collector = FakeCollector::with(vec![Step::Respond(503, "{}", None)]);
    let client = Client::new(config(&collector).flush_interval(Duration::from_millis(10))).unwrap();
    client.track(Event::new("bg")).unwrap();
    assert!(wait_until(Duration::from_secs(3), || collector.count() == 1));
    std::thread::sleep(Duration::from_millis(150));
    assert_eq!(collector.count(), 1, "geri çekilme sırasında yeniden deneme olmamalı");
    assert_eq!(client.queued(), 1);
    client.set_consent(Consent::default());
    client.close(Duration::from_secs(1));
}

#[test]
fn close_flushes_and_blocks_track() {
    let collector = Arc::new(FakeCollector::default());
    let client = client(&collector);
    for _ in 0..3 {
        client.track(Event::new("e")).unwrap();
    }
    let result = client.close(Duration::from_secs(5));
    assert!(result.ok());
    assert_eq!(collector.count(), 1);
    assert_eq!(collector.request(0).event_ids().len(), 3);
    assert_eq!(client.queued(), 0);
    assert!(client.status().closed);
    assert!(matches!(client.track(Event::new("late")), Err(Error::ClientClosed)));
    assert!(matches!(client.flush(), Err(Error::ClientClosed)));
    assert!(client.close(Duration::from_secs(1)).ok(), "ikinci close hatasız olmalı");
}

#[test]
fn close_reports_undelivered() {
    let collector = FakeCollector::with(vec![Step::Respond(503, "{}", None)]);
    let client = client(&collector);
    client.track(Event::new("e")).unwrap();
    let result = client.close(Duration::from_secs(1));
    assert!(matches!(result.error, Some(DeliveryError::Temporary { .. })));
    assert_eq!(result.retained, 1);
}

#[test]
fn concurrent_track() {
    let collector = Arc::new(FakeCollector::default());
    let client = Arc::new(Client::new(config(&collector).queue_limit(5000).batch_size(MAX_BATCH_SIZE)).unwrap());
    let mut handles = Vec::new();
    for _ in 0..8 {
        let client = Arc::clone(&client);
        handles.push(std::thread::spawn(move || {
            for _ in 0..100 {
                client.track(Event::new("c")).unwrap();
            }
        }));
    }
    for handle in handles {
        handle.join().unwrap();
    }
    assert_eq!(client.queued(), 800);
    let result = client.flush().unwrap();
    assert!(result.ok());
    assert_eq!((result.accepted, client.queued(), collector.count()), (800, 0, 2));
    let mut seen = HashSet::new();
    for index in 0..2 {
        for id in collector.request(index).event_ids() {
            assert!(seen.insert(id));
        }
    }
}

#[test]
fn occurred_at_uses_injected_clock() {
    let collector = Arc::new(FakeCollector::default());
    let fixed = UNIX_EPOCH + Duration::from_millis(1_793_703_600_123);
    let client = Client::new(config(&collector).clock(move || fixed)).unwrap();
    let event = client.track(Event::new("clock")).unwrap().unwrap();
    assert_eq!(event.payload["occurred_at"], "2026-11-03T11:00:00.123Z");
    let explicit: SystemTime = UNIX_EPOCH + Duration::from_secs(1_767_323_045);
    let event = client.track(Event::new("clock").occurred_at(explicit)).unwrap().unwrap();
    assert_eq!(event.payload["occurred_at"], "2026-01-02T03:04:05.000Z");
}

#[test]
fn drop_stops_background_thread_without_panic() {
    let collector = Arc::new(FakeCollector::default());
    let client = Client::new(config(&collector).flush_interval(Duration::from_secs(3600))).unwrap();
    drop(client);
    // Arka plan iş parçacığı Arc'ı bırakınca sayaç tek sahibe düşer.
    assert!(wait_until(Duration::from_secs(3), || Arc::strong_count(&collector) == 1));
}
