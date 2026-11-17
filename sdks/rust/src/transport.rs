use std::fmt;
use std::time::Duration;

const MAX_RESPONSE_BODY: u64 = 64 * 1024;

/// HTTP yanıtı. Hata kodları da normal yanıttır.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
    /// `Retry-After` başlığı; varsa.
    pub retry_after: Option<String>,
}

/// Ağ veya zaman aşımı hatası: olaylar kuyrukta kalır.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportError {
    pub message: String,
}

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for TransportError {}

/// Testler ve özel ağ yığınları için değiştirilebilir taşıma.
pub trait Transport: Send + Sync {
    fn post(&self, url: &str, body: &[u8], headers: &[(&str, &str)], timeout: Duration) -> Result<Response, TransportError>;
}

/// `ureq` + rustls ile bloklayan taşıma.
pub struct UreqTransport {
    agent: ureq::Agent,
}

impl Default for UreqTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl UreqTransport {
    pub fn new() -> Self {
        // 4xx ve 5xx hata değildir; kuyruk kararını istemci verir.
        let config = ureq::Agent::config_builder().http_status_as_error(false).build();
        Self { agent: ureq::Agent::new_with_config(config) }
    }
}

impl Transport for UreqTransport {
    fn post(&self, url: &str, body: &[u8], headers: &[(&str, &str)], timeout: Duration) -> Result<Response, TransportError> {
        let mut request = self.agent.post(url);
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        let mut response = request
            .config()
            .timeout_global(Some(timeout))
            .build()
            .send(body)
            .map_err(|error| TransportError { message: format!("ağ hatası: {error}") })?;

        let status = response.status().as_u16();
        let retry_after = response.headers().get("retry-after").and_then(|value| value.to_str().ok()).map(str::to_string);
        // Gövde okunamazsa yanıt yine geçerlidir; durum kodu karar için yeterli.
        let body = response.body_mut().with_config().limit(MAX_RESPONSE_BODY).read_to_vec().unwrap_or_default();
        Ok(Response { status, body, retry_after })
    }
}
