use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime};

use serde_json::{json, Map, Value};

use crate::capture::ErrorLimiter;
use crate::error::{DeliveryError, Error};
use crate::event::{
    idempotency_key_for, validate_event_name, validate_identifier, validate_properties, Consent, Event, FlushResult, TrackedEvent,
    ATTRIBUTION_CLICK_PROPERTY,
};
use crate::time::{epoch_millis, format_time};
use crate::transport::{Transport, UreqTransport};
use crate::ulid::UlidGenerator;

pub const SDK_NAME: &str = "feralin-rust";
pub const SDK_VERSION: &str = "0.1.0";
pub const PLATFORM: &str = "rust";
pub const SCHEMA_VERSION: u32 = 1;
pub const MAX_BATCH_SIZE: usize = 500;
pub const DEFAULT_BATCH_SIZE: usize = 100;
pub const DEFAULT_QUEUE_LIMIT: usize = 1000;
pub const DEFAULT_FLUSH_INTERVAL: Duration = Duration::from_secs(2);
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);
pub const CLOSE_TIMEOUT: Duration = Duration::from_secs(5);

const MIN_BACKOFF: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(30);

type Clock = Arc<dyn Fn() -> SystemTime + Send + Sync>;

/// `Client` ayarları. Varsayılan izin hepsi kapalıdır.
pub struct Config {
    project_key: String,
    collect_url: String,
    consent: Consent,
    flush_interval: Duration,
    batch_size: usize,
    queue_limit: usize,
    timeout: Duration,
    transport: Option<Arc<dyn Transport>>,
    clock: Option<Clock>,
    app_version: Option<String>,
    error_sample_rate: f64,
}

impl Config {
    pub fn new(project_key: impl Into<String>, collect_url: impl Into<String>) -> Self {
        Self {
            project_key: project_key.into(),
            collect_url: collect_url.into(),
            consent: Consent::default(),
            flush_interval: DEFAULT_FLUSH_INTERVAL,
            batch_size: DEFAULT_BATCH_SIZE,
            queue_limit: DEFAULT_QUEUE_LIMIT,
            timeout: DEFAULT_TIMEOUT,
            transport: None,
            clock: None,
            app_version: None,
            error_sample_rate: 1.0,
        }
    }

    pub fn consent(mut self, value: Consent) -> Self {
        self.consent = value;
        self
    }

    /// Sıfır ise arka plan gönderici başlatılmaz.
    pub fn flush_interval(mut self, value: Duration) -> Self {
        self.flush_interval = value;
        self
    }

    /// 1 ile 500 arasına çekilir.
    pub fn batch_size(mut self, value: usize) -> Self {
        self.batch_size = value;
        self
    }

    pub fn queue_limit(mut self, value: usize) -> Self {
        self.queue_limit = value;
        self
    }

    pub fn timeout(mut self, value: Duration) -> Self {
        self.timeout = value;
        self
    }

    pub fn transport(mut self, value: Arc<dyn Transport>) -> Self {
        self.transport = Some(value);
        self
    }

    /// Uygulama sürümü; yalnız `fr_error` olaylarının `app_version` alanına yazılır. Boş ya da 32 karakterden uzunsa gönderilmez.
    pub fn app_version(mut self, value: impl Into<String>) -> Self {
        self.app_version = Some(value.into());
        self
    }

    /// `capture_error` örnekleme oranı 0..1 (varsayılan 1). Yalnız kayıp kabul edilen yüksek hacimde düşürün.
    pub fn error_sample_rate(mut self, value: f64) -> Self {
        self.error_sample_rate = value;
        self
    }

    /// Saat enjeksiyonu; `occurred_at` ve ULID zamanı buradan gelir.
    pub fn clock(mut self, value: impl Fn() -> SystemTime + Send + Sync + 'static) -> Self {
        self.clock = Some(Arc::new(value));
        self
    }
}

/// Anlık durum (debug ve sağlık amaçlı). Anahtar yoktur.
#[derive(Debug, Clone, PartialEq)]
pub struct Status {
    pub sdk: &'static str,
    pub version: &'static str,
    pub queued: usize,
    pub dropped: u64,
    pub consent: Consent,
    pub user_id: Option<String>,
    pub closed: bool,
    pub backoff: Duration,
    pub endpoint: String,
}

#[derive(Clone)]
struct Queued {
    id: String,
    raw: String,
}

struct State {
    consent: Consent,
    queue: Vec<Queued>,
    // Sonucu bilinmeyen batch aynı içerik ve aynı anahtarla yeniden denenir; sunucu yanıtı yolda kaybolduysa
    // araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
    pinned: Option<Vec<Queued>>,
    user_id: Option<String>,
    closed: bool,
    dropped: u64,
    backoff: Duration,
    backoff_until: Option<Instant>,
    stop: bool,
    wake: bool,
}

struct Shared {
    project_key: String,
    endpoint: String,
    batch_size: usize,
    queue_limit: usize,
    timeout: Duration,
    transport: Arc<dyn Transport>,
    clock: Clock,
    ulid: UlidGenerator,
    app_version: Option<String>,
    error_limiter: Mutex<ErrorLimiter>,
    state: Mutex<State>,
    // Aynı anda tek gönderici: sabit Idempotency-Key için.
    send_lock: Mutex<()>,
    signal: Condvar,
}

/// UTP v1 toplayıcısına (`POST /v1/batch`) olay gönderen, iş parçacığı güvenli istemci.
///
/// Çıkmadan önce `close` çağrılmalıdır. `Drop` ağ çağrısı yapmaz: yalnız arka plan göndericiyi durdurur, kuyruktaki olaylar kaybolur.
pub struct Client {
    shared: Arc<Shared>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

impl Client {
    pub fn new(config: Config) -> Result<Self, Error> {
        let key = config.project_key.trim().to_string();
        if key.starts_with("sk_") {
            return Err(Error::Configuration("gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin".to_string()));
        }
        if !key.starts_with("pk_") || key.len() < 8 {
            return Err(Error::Configuration("proje anahtarı pk_ ile başlamalı".to_string()));
        }
        let root = config.collect_url.trim().trim_end_matches('/').to_string();
        if !is_absolute_http_url(&root) {
            return Err(Error::Configuration("collect_url http veya https şemalı mutlak adres olmalı".to_string()));
        }
        if config.timeout.is_zero() {
            return Err(Error::Configuration("timeout pozitif olmalı".to_string()));
        }

        let transport: Arc<dyn Transport> = match config.transport {
            Some(transport) => transport,
            None => Arc::new(UreqTransport::new()),
        };
        let clock: Clock = match config.clock {
            Some(clock) => clock,
            None => Arc::new(SystemTime::now),
        };

        let shared = Arc::new(Shared {
            project_key: key,
            endpoint: format!("{root}/v1/batch"),
            batch_size: config.batch_size.clamp(1, MAX_BATCH_SIZE),
            queue_limit: config.queue_limit.max(1),
            timeout: config.timeout,
            transport,
            clock,
            ulid: UlidGenerator::new(),
            app_version: config
                .app_version
                .map(|version| version.trim().to_string())
                .filter(|version| !version.is_empty() && version.chars().count() <= 32),
            error_limiter: Mutex::new(ErrorLimiter::new(config.error_sample_rate)),
            state: Mutex::new(State {
                consent: config.consent,
                queue: Vec::new(),
                pinned: None,
                user_id: None,
                closed: false,
                dropped: 0,
                backoff: Duration::ZERO,
                backoff_until: None,
                stop: false,
                wake: false,
            }),
            send_lock: Mutex::new(()),
            signal: Condvar::new(),
        });

        let worker = if config.flush_interval.is_zero() {
            None
        } else {
            let background = Arc::clone(&shared);
            let interval = config.flush_interval;
            let handle = thread::Builder::new()
                .name("feralin-flush".to_string())
                .spawn(move || background.run(interval))
                .map_err(|error| Error::Configuration(format!("arka plan iş parçacığı başlatılamadı: {error}")))?;
            Some(handle)
        };
        Ok(Self { shared, worker: Mutex::new(worker) })
    }

    /// İzin durumunu günceller. `analytics` false ise bekleyen olaylar atılır ve yeni olay üretilmez.
    pub fn set_consent(&self, consent: Consent) {
        let mut state = self.shared.lock_state();
        state.consent = consent;
        if !consent.analytics {
            state.queue.clear();
            state.pinned = None;
        }
    }

    /// Sonraki olaylar için varsayılan `user_id`. `None` varsayılanı kaldırır.
    pub fn identify(&self, user_id: Option<String>) -> Result<(), Error> {
        let value = validate_identifier(user_id, "user_id")?;
        self.shared.lock_state().user_id = value;
        Ok(())
    }

    /// Olayı doğrular, UTP v1 biçimine çevirir ve kuyruğa ekler; ağ çağrısı yapmaz.
    /// `analytics` izni yoksa olay üretilmez ve `Ok(None)` döner.
    pub fn track(&self, event: Event) -> Result<Option<TrackedEvent>, Error> {
        let (closed, consent, default_user) = {
            let state = self.shared.lock_state();
            (state.closed, state.consent, state.user_id.clone())
        };
        if closed {
            return Err(Error::ClientClosed);
        }
        if !consent.analytics {
            return Ok(None);
        }

        validate_event_name(&event.name)?;
        validate_properties(&event.properties)?;
        let mut properties = event.properties;
        // fr_click yalnız açık reklam ölçümü izniyle gönderilir.
        if !consent.advertising {
            properties.remove(ATTRIBUTION_CLICK_PROPERTY);
        }
        let user_id = validate_identifier(event.user_id, "user_id")?.or(default_user);
        let anonymous_id = validate_identifier(event.anonymous_id, "anonymous_id")?;
        let session_id = validate_identifier(event.session_id, "session_id")?;

        let now = (self.shared.clock)();
        let event_id = self.shared.ulid.at(epoch_millis(now));
        let mut wire = Map::new();
        wire.insert("event_id".to_string(), Value::from(event_id.as_str()));
        wire.insert("event_name".to_string(), Value::from(event.name));
        wire.insert("occurred_at".to_string(), Value::from(format_time(event.occurred_at.unwrap_or(now))));
        wire.insert("platform".to_string(), Value::from(PLATFORM));
        wire.insert("schema_version".to_string(), Value::from(SCHEMA_VERSION));
        wire.insert("sdk".to_string(), json!({ "name": SDK_NAME, "version": SDK_VERSION }));
        wire.insert("consent".to_string(), consent.to_json());
        if let Some(value) = anonymous_id {
            wire.insert("anonymous_id".to_string(), Value::from(value));
        }
        if let Some(value) = user_id {
            wire.insert("user_id".to_string(), Value::from(value));
        }
        if let Some(value) = session_id {
            wire.insert("session_id".to_string(), Value::from(value));
        }
        if !properties.is_empty() {
            wire.insert("properties".to_string(), Value::Object(properties));
        }
        if let Some(context) = event.context {
            let context = context.to_json();
            if !context.is_empty() {
                wire.insert("context".to_string(), Value::Object(context));
            }
        }

        let payload = Value::Object(wire);
        let raw = payload.to_string();

        let mut state = self.shared.lock_state();
        if state.closed {
            return Err(Error::ClientClosed);
        }
        // Serileştirme sürerken izin geri çekildiyse olay kuyruğa girmez.
        if !state.consent.analytics {
            return Ok(None);
        }
        state.queue.push(Queued { id: event_id.clone(), raw });
        let over = state.queue.len().saturating_sub(self.shared.queue_limit);
        if over > 0 {
            state.queue.drain(..over);
            state.dropped += over as u64;
        }
        if state.queue.len() >= self.shared.batch_size {
            state.wake = true;
            self.shared.signal.notify_all();
        }
        Ok(Some(TrackedEvent { event_id, payload }))
    }

    /// Kuyruktaki tüm olayları batch'ler hâlinde gönderir; geri çekilme beklemez, çünkü açık çağrı niyet sayılır.
    /// Teslim hatası `Err` değildir, `FlushResult::error` içinde döner.
    pub fn flush(&self) -> Result<FlushResult, Error> {
        if self.shared.lock_state().closed {
            return Err(Error::ClientClosed);
        }
        Ok(self.shared.flush(None))
    }

    /// Arka plan göndericiyi durdurur ve kalan olayları en fazla `timeout` içinde göndermeyi dener. Birden çok çağrı güvenlidir.
    pub fn close(&self, timeout: Duration) -> FlushResult {
        {
            let mut state = self.shared.lock_state();
            if state.closed {
                return FlushResult::default();
            }
            state.closed = true;
            state.stop = true;
            self.shared.signal.notify_all();
        }
        let worker = self.worker.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
        if let Some(handle) = worker {
            // Gönderici en fazla bir istek süresince meşguldür; panik burada yutulur, kapanış sürer.
            let _ = handle.join();
        }
        self.shared.flush(Some(Instant::now() + timeout))
    }

    /// Olay üretilebilir mi: kapalı istemcide `Err`, `analytics` izni yoksa `false`.
    pub(crate) fn analytics_allowed(&self) -> Result<bool, Error> {
        let state = self.shared.lock_state();
        if state.closed {
            return Err(Error::ClientClosed);
        }
        Ok(state.consent.analytics)
    }

    pub(crate) fn app_version(&self) -> Option<&str> {
        self.shared.app_version.as_deref()
    }

    /// Hata fırtınası sınırı ve örnekleme; rastgele kaynak okunamazsa olay örneklemeden geçer.
    pub(crate) fn allow_error(&self, fingerprint: &str) -> bool {
        let mut limiter = self.shared.error_limiter.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        limiter.allow(fingerprint, || {
            let mut bytes = [0u8; 8];
            match getrandom::fill(&mut bytes) {
                Ok(()) => (u64::from_le_bytes(bytes) >> 11) as f64 / (1u64 << 53) as f64,
                Err(_) => 0.0,
            }
        })
    }

    pub fn queued(&self) -> usize {
        self.shared.lock_state().queue.len()
    }

    pub fn status(&self) -> Status {
        let state = self.shared.lock_state();
        Status {
            sdk: SDK_NAME,
            version: SDK_VERSION,
            queued: state.queue.len(),
            dropped: state.dropped,
            consent: state.consent,
            user_id: state.user_id.clone(),
            closed: state.closed,
            backoff: state.backoff,
            endpoint: self.shared.endpoint.clone(),
        }
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let mut state = self.shared.lock_state();
        state.stop = true;
        self.shared.signal.notify_all();
    }
}

impl Shared {
    // Kullanıcı iş parçacığı panik etse bile kuyruk tutarlıdır; zehirli kilit uygulamayı düşürmesin.
    fn lock_state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Arka plan gönderici: aralık dolunca ya da kuyruk batch boyutuna ulaşınca gönderir, geri çekilmeye uyar.
    fn run(&self, interval: Duration) {
        loop {
            {
                let state = self.lock_state();
                let (mut state, _) = self
                    .signal
                    .wait_timeout_while(state, interval, |state| !state.stop && !state.wake)
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if state.stop {
                    return;
                }
                state.wake = false;
                if state.backoff_until.is_some_and(|until| Instant::now() < until) {
                    continue;
                }
            }
            self.flush(None);
        }
    }

    fn flush(&self, deadline: Option<Instant>) -> FlushResult {
        let _sending = self.send_lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut total = FlushResult::default();
        // Üretici sürekli ekliyorsa döngü sonsuz olmasın: kuyruk sınırı kadar olay + bir tur.
        let max_rounds = self.queue_limit / self.batch_size + 2;
        for _ in 0..max_rounds {
            let batch = self.peek();
            if batch.is_empty() {
                break;
            }
            let mut timeout = self.timeout;
            if let Some(deadline) = deadline {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    total.error = Some(DeliveryError::Temporary {
                        status: 0,
                        message: "kapanış zaman aşımı; olaylar gönderilemedi".to_string(),
                    });
                    break;
                }
                timeout = timeout.min(remaining);
            }
            let result = self.send(batch, timeout);
            total.sent += result.sent;
            total.accepted += result.accepted;
            total.rejected += result.rejected;
            total.status = result.status;
            if result.batch_id.is_some() {
                total.batch_id = result.batch_id;
            }
            if result.error.is_some() {
                total.error = result.error;
                break;
            }
        }
        total.retained = self.lock_state().queue.len();
        total
    }

    fn peek(&self) -> Vec<Queued> {
        let state = self.lock_state();
        match &state.pinned {
            Some(pinned) => pinned.clone(),
            None => state.queue.iter().take(self.batch_size).cloned().collect(),
        }
    }

    fn acknowledge(&self, batch: &[Queued]) {
        let mut state = self.lock_state();
        state.pinned = None;
        state.queue.retain(|item| !batch.iter().any(|sent| sent.id == item.id));
    }

    /// İstek sürerken izin geri çekildiyse olaylar çoktan silinmiştir, sabitlenmez.
    fn pin(&self, batch: Vec<Queued>) {
        let mut state = self.lock_state();
        if state.consent.analytics {
            state.pinned = Some(batch);
        }
    }

    /// Üstel geri çekilme 1 sn → 30 sn; `Retry-After` verilmişse en az o kadar beklenir. Yarım jitter süreçleri ayrıştırır.
    fn note_failure(&self, retry_after: Option<&str>) {
        let mut state = self.lock_state();
        let mut next = (state.backoff * 2).max(MIN_BACKOFF);
        let mut floor = Duration::ZERO;
        if let Some(seconds) = retry_after.and_then(|value| value.trim().parse::<u64>().ok()) {
            if seconds > 0 {
                floor = Duration::from_secs(seconds).min(MAX_BACKOFF);
                next = next.max(Duration::from_secs(seconds));
            }
        }
        next = next.min(MAX_BACKOFF);
        state.backoff = next;
        // Rastgele kaynak okunamazsa tam süre beklenir: jitter teslimi engelleyecek bir koşul değildir.
        let mut byte = [255u8; 1];
        let _ = getrandom::fill(&mut byte);
        let wait = next.mul_f64(0.5 + f64::from(byte[0]) / 510.0).max(floor);
        state.backoff_until = Some(Instant::now() + wait);
    }

    fn note_success(&self) {
        let mut state = self.lock_state();
        state.backoff = Duration::ZERO;
        state.backoff_until = None;
    }

    fn send(&self, batch: Vec<Queued>, timeout: Duration) -> FlushResult {
        let count = batch.len();
        // Olaylar zaten serileştirilmiş; gövde metin birleştirme ile kurulur.
        let body = {
            let events: Vec<&str> = batch.iter().map(|item| item.raw.as_str()).collect();
            format!("{{\"sent_at\":\"{}\",\"events\":[{}]}}", format_time((self.clock)()), events.join(","))
        };
        let idempotency_key = {
            let ids: Vec<&str> = batch.iter().map(|item| item.id.as_str()).collect();
            idempotency_key_for(&ids)
        };
        let user_agent = format!("{SDK_NAME}/{SDK_VERSION}");
        let headers = [
            ("Content-Type", "application/json"),
            ("Accept", "application/json, application/problem+json"),
            ("X-Feralin-Project-Key", self.project_key.as_str()),
            ("Idempotency-Key", idempotency_key.as_str()),
            ("User-Agent", user_agent.as_str()),
        ];

        let mut result = FlushResult { sent: count, ..FlushResult::default() };
        let response = match self.transport.post(&self.endpoint, body.as_bytes(), &headers, timeout) {
            Ok(response) => response,
            Err(error) => {
                self.pin(batch);
                self.note_failure(None);
                result.retained = count;
                result.error = Some(DeliveryError::Temporary { status: 0, message: error.message });
                return result;
            }
        };

        result.status = response.status;
        if response.status == 202 {
            let ack: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
            self.acknowledge(&batch);
            self.note_success();
            result.accepted = ack.get("accepted").and_then(Value::as_u64).map_or(count, |value| value as usize);
            result.rejected = ack.get("rejected").and_then(Value::as_u64).map_or(0, |value| value as usize);
            result.batch_id = ack.get("batch_id").and_then(Value::as_str).map(str::to_string);
            return result;
        }
        if (400..500).contains(&response.status) && response.status != 429 {
            self.acknowledge(&batch);
            result.rejected = count;
            result.error = Some(DeliveryError::Rejected { status: response.status, detail: problem_summary(&response.body) });
            return result;
        }
        self.pin(batch);
        self.note_failure(response.retry_after.as_deref());
        result.retained = count;
        result.error = Some(DeliveryError::Temporary { status: response.status, message: "olaylar kuyrukta tutuldu".to_string() });
        result
    }
}

fn is_absolute_http_url(value: &str) -> bool {
    let rest = value.strip_prefix("https://").or_else(|| value.strip_prefix("http://"));
    rest.is_some_and(|rest| {
        let host = rest.split(['/', '?', '#']).next().unwrap_or("");
        !host.is_empty() && !host.contains(char::is_whitespace)
    })
}

/// RFC 7807 gövdesinden kısa, loglanabilir özet; ham gövde sızdırılmaz.
fn problem_summary(raw: &[u8]) -> String {
    let Ok(Value::Object(problem)) = serde_json::from_slice::<Value>(raw) else {
        return "problem+json yok".to_string();
    };
    let parts: Vec<&str> = ["title", "detail"]
        .iter()
        .filter_map(|key| problem.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .collect();
    if parts.is_empty() {
        "problem+json yok".to_string()
    } else {
        parts.join(" ").chars().take(200).collect()
    }
}
