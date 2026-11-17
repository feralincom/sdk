//! Tauri 2 eklentisi: webview ve Rust tarafı aynı `feralin::Client` üzerinden olay gönderir.
//!
//! ```ignore
//! use feralin::{Config, Consent};
//!
//! let plugin = tauri_plugin_feralin::init::<tauri::Wry>(
//!     Config::new("pk_live_...", "https://collect.example.com").consent(Consent::default()),
//! )?;
//! tauri::Builder::default().plugin(plugin);
//! ```

use std::time::Duration;

use feralin::{Client, Config, Consent, Event, FlushResult};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tauri::plugin::{Builder, TauriPlugin};
use tauri::{AppHandle, Manager, Runtime, State};

/// Eklentinin paylaşılan durumu. Rust tarafından `app.feralin()` ile erişilir.
pub struct Feralin {
    client: Client,
}

impl Feralin {
    pub fn client(&self) -> &Client {
        &self.client
    }
}

/// `AppHandle`, `App` ve `Window` üzerinde `feralin()` kısayolu.
pub trait FeralinExt<R: Runtime> {
    fn feralin(&self) -> &Feralin;
}

impl<R: Runtime, T: Manager<R>> FeralinExt<R> for T {
    fn feralin(&self) -> &Feralin {
        self.state::<Feralin>().inner()
    }
}

/// Webview'den gelen izin. Eksik alan kapalı sayılır.
#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct ConsentInput {
    analytics: bool,
    advertising: bool,
    personalization: bool,
    session_replay: bool,
}

impl From<ConsentInput> for Consent {
    fn from(input: ConsentInput) -> Self {
        Consent {
            analytics: input.analytics,
            advertising: input.advertising,
            personalization: input.personalization,
            session_replay: input.session_replay,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FlushOutput {
    ok: bool,
    sent: usize,
    accepted: usize,
    rejected: usize,
    batch_id: Option<String>,
    status: u16,
    retained: usize,
    error: Option<String>,
}

impl From<FlushResult> for FlushOutput {
    fn from(result: FlushResult) -> Self {
        Self {
            ok: result.ok(),
            sent: result.sent,
            accepted: result.accepted,
            rejected: result.rejected,
            batch_id: result.batch_id,
            status: result.status,
            retained: result.retained,
            error: result.error.map(|error| error.to_string()),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusOutput {
    sdk: &'static str,
    version: &'static str,
    queued: usize,
    dropped: u64,
    closed: bool,
}

/// İzin yoksa `null` döner; doğrulama hatası dizge olarak döner, uygulama düşmez.
#[tauri::command]
fn track(
    state: State<'_, Feralin>,
    name: String,
    properties: Option<Map<String, Value>>,
    user_id: Option<String>,
    anonymous_id: Option<String>,
    session_id: Option<String>,
) -> Result<Option<String>, String> {
    let mut event = Event::new(name);
    if let Some(properties) = properties {
        event = event.properties(properties);
    }
    if let Some(value) = user_id {
        event = event.user_id(value);
    }
    if let Some(value) = anonymous_id {
        event = event.anonymous_id(value);
    }
    if let Some(value) = session_id {
        event = event.session_id(value);
    }
    let tracked = state.client.track(event).map_err(|error| error.to_string())?;
    Ok(tracked.map(|event| event.event_id))
}

#[tauri::command]
fn identify(state: State<'_, Feralin>, user_id: Option<String>) -> Result<(), String> {
    state.client.identify(user_id).map_err(|error| error.to_string())
}

#[tauri::command]
fn set_consent(state: State<'_, Feralin>, consent: ConsentInput) {
    state.client.set_consent(consent.into());
}

/// `flush` bloklayan ağ çağrısı yapar; arayüz ve async çalışma zamanı beklemesin diye ayrı iş parçacığında koşar.
#[tauri::command]
async fn flush<R: Runtime>(app: AppHandle<R>) -> Result<FlushOutput, String> {
    let joined = tauri::async_runtime::spawn_blocking(move || app.feralin().client().flush()).await;
    match joined {
        Ok(result) => result.map(FlushOutput::from).map_err(|error| error.to_string()),
        Err(error) => Err(error.to_string()),
    }
}

#[tauri::command]
fn status(state: State<'_, Feralin>) -> StatusOutput {
    let status = state.client.status();
    StatusOutput { sdk: status.sdk, version: status.version, queued: status.queued, dropped: status.dropped, closed: status.closed }
}

/// Eklentiyi kurar. Geçersiz yapılandırma burada `Err` olur; proje anahtarı `pk_` ile başlamalıdır.
pub fn init<R: Runtime>(config: Config) -> Result<TauriPlugin<R>, feralin::Error> {
    let client = Client::new(config)?;
    Ok(Builder::<R, ()>::new("feralin")
        .invoke_handler(tauri::generate_handler![track, identify, set_consent, flush, status])
        .setup(move |app, _api| {
            app.manage(Feralin { client });
            Ok(())
        })
        .on_event(|app, event| {
            // Çıkışta kuyruk en fazla 2 sn içinde boşaltılır; kalan olaylar bellek içi olduğundan kaybolur.
            if let tauri::RunEvent::Exit = event {
                if let Some(state) = app.try_state::<Feralin>() {
                    state.client().close(Duration::from_secs(2));
                }
            }
        })
        .build())
}
