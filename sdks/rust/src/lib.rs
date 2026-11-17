//! Feralin UTP v1 istemcisi.
//!
//! İlkeler (Web ve Python SDK'larıyla aynı):
//! - `consent.analytics` false ise olay üretilmez, `track` `Ok(None)` döner.
//! - `consent.advertising` false ise `fr_click` çıkarılır.
//! - 202 → onay; 4xx (429 hariç) → olaylar atılır; 5xx, 429 ve ağ hatası → kuyrukta kalır ve aynı içerik aynı
//!   `Idempotency-Key` ile 1 sn → 30 sn üstel geri çekilmeyle yeniden denenir.
//! - Yalnız proje public anahtarı (`pk_…`) kabul edilir. `tenant_id`, `project_id` ve `verified` gönderilmez.
//!
//! ```no_run
//! use feralin::{Client, Config, Consent, Event};
//!
//! let client = Client::new(
//!     Config::new("pk_live_...", "https://collect.example.com")
//!         .consent(Consent { analytics: true, ..Consent::default() }),
//! )?;
//! client.track(Event::new("order_completed").property("order_id", "ord_1").user_id("user_42"))?;
//! client.close(std::time::Duration::from_secs(5));
//! # Ok::<(), feralin::Error>(())
//! ```

mod capture;
mod client;
mod error;
mod event;
mod profile;
mod revenue;
mod time;
mod transport;
mod ulid;

pub use capture::{
    error_properties, fnv1a64_hex, scrub_error_message, ErrorOrigin, ErrorReport, ERROR_EVENT_NAME, ERROR_MAX_EVENTS, ERROR_MAX_MESSAGE,
    ERROR_MAX_PER_FINGERPRINT,
};
pub use client::{
    Client, Config, Status, CLOSE_TIMEOUT, DEFAULT_BATCH_SIZE, DEFAULT_FLUSH_INTERVAL, DEFAULT_QUEUE_LIMIT, DEFAULT_TIMEOUT,
    MAX_BATCH_SIZE, PLATFORM, SCHEMA_VERSION, SDK_NAME, SDK_VERSION,
};
pub use error::{DeliveryError, Error};
pub use event::{idempotency_key_for, AppInfo, Consent, Context, Event, FlushResult, Screen, TrackedEvent, ATTRIBUTION_CLICK_PROPERTY};
pub use profile::{
    is_pii_like_key, sanitize_profile_properties, valid_group_id, Identity, GROUP_EVENT_NAME, MAX_GROUP_ID_LENGTH, MAX_PROFILE_PROPERTIES,
    MAX_PROFILE_VALUE_LENGTH, USER_PROPERTIES_EVENT_NAME,
};
pub use revenue::{
    revenue_properties, PurchaseType, Receipt, ReceiptProvider, Revenue, MAX_AMOUNT_MINOR, MAX_QUANTITY, REVENUE_EVENT_NAME,
};
pub use transport::{Response, Transport, TransportError, UreqTransport};
pub use ulid::{is_ulid, UlidGenerator};
