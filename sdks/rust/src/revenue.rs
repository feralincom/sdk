//! `track_revenue` sözleşmesi (F5-E04-T01): olay adı `feralin_purchase`; tutar küçük birimde tam sayı (kuruş, cent), para birimi
//! ISO 4217. Kurallar Web (`buildRevenueProperties`), Node, Go ve .NET SDK'larıyla aynıdır. İstemci beyanıdır: sunucu satırı yalnız
//! makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` alanı istemciden hiçbir zaman gönderilmez.

use std::time::SystemTime;

use serde_json::{json, Map, Value};

use crate::client::Client;
use crate::error::Error;
use crate::event::{Context, Event, TrackedEvent};

/// Gelir olayının tek adı; defter yalnız bu olaydan beslenir.
pub const REVENUE_EVENT_NAME: &str = "feralin_purchase";
/// Küçük birimde tutarın üst sınırı (JS güvenli tam sayı, 2^53-1); sunucu bigint taşır.
pub const MAX_AMOUNT_MINOR: i64 = (1 << 53) - 1;
/// Adet üst sınırı.
pub const MAX_QUANTITY: i64 = 100_000;
const MAX_TRANSACTION_ID_LENGTH: usize = 128;
const MAX_PRODUCT_ID_LENGTH: usize = 128;
const MAX_RECEIPT_TOKEN_LENGTH: usize = 8192;

/// İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
const REVENUE_RESERVED_KEYS: [&str; 6] =
    ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"];

/// Satın alma türü; verilmezse `purchase`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PurchaseType {
    #[default]
    Purchase,
    SubscriptionStart,
    SubscriptionRenew,
    /// Abonelik iptali para taşımaz: tutar 0 olmalıdır.
    SubscriptionCancel,
}

impl PurchaseType {
    pub fn as_str(self) -> &'static str {
        match self {
            PurchaseType::Purchase => "purchase",
            PurchaseType::SubscriptionStart => "subscription_start",
            PurchaseType::SubscriptionRenew => "subscription_renew",
            PurchaseType::SubscriptionCancel => "subscription_cancel",
        }
    }
}

/// Makbuz sağlayıcısı.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReceiptProvider {
    Apple,
    Google,
    Stripe,
}

impl ReceiptProvider {
    pub fn as_str(self) -> &'static str {
        match self {
            ReceiptProvider::Apple => "apple",
            ReceiptProvider::Google => "google",
            ReceiptProvider::Stripe => "stripe",
        }
    }
}

/// İsteğe bağlı ham makbuz; toplayıcı yalnız sağlayıcı adını ve belirtecin özetini saklar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Receipt {
    pub provider: ReceiptProvider,
    /// Sağlayıcının verdiği makbuz ya da satın alma belirteci (1..8192 karakter).
    pub token: String,
}

/// `Client::track_revenue` girdisi.
#[derive(Debug, Clone)]
pub struct Revenue {
    transaction_id: String,
    amount_minor: i64,
    currency: String,
    product_id: Option<String>,
    quantity: Option<i64>,
    purchase_type: PurchaseType,
    receipt: Option<Receipt>,
    properties: Map<String, Value>,
    user_id: Option<String>,
    anonymous_id: Option<String>,
    session_id: Option<String>,
    occurred_at: Option<SystemTime>,
    context: Option<Context>,
}

impl Revenue {
    /// `transaction_id`: mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz (sunucu aynı işlemi ikinci kez saymaz).
    /// `amount_minor`: küçük birimde satır toplamı (49,99 TL için 4999); adetle çarpılmaz. `currency`: ISO 4217, üç büyük harf.
    pub fn new(transaction_id: impl Into<String>, amount_minor: i64, currency: impl Into<String>) -> Self {
        Self {
            transaction_id: transaction_id.into(),
            amount_minor,
            currency: currency.into(),
            product_id: None,
            quantity: None,
            purchase_type: PurchaseType::Purchase,
            receipt: None,
            properties: Map::new(),
            user_id: None,
            anonymous_id: None,
            session_id: None,
            occurred_at: None,
            context: None,
        }
    }

    pub fn product_id(mut self, value: impl Into<String>) -> Self {
        self.product_id = Some(value.into());
        self
    }

    /// Bilgi amaçlı adet (0..100000); verilmezse 1.
    pub fn quantity(mut self, value: i64) -> Self {
        self.quantity = Some(value);
        self
    }

    pub fn purchase_type(mut self, value: PurchaseType) -> Self {
        self.purchase_type = value;
        self
    }

    pub fn receipt(mut self, provider: ReceiptProvider, token: impl Into<String>) -> Self {
        self.receipt = Some(Receipt { provider, token: token.into() });
        self
    }

    /// Ek özellik; doğrulama alanları (`verified` vb.) düşürülür.
    pub fn property(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.properties.insert(key.into(), value.into());
        self
    }

    pub fn properties(mut self, properties: Map<String, Value>) -> Self {
        self.properties.extend(properties);
        self
    }

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

fn invalid() -> Error {
    Error::InvalidEvent(
        "gelir girdisi geçersiz (transaction_id 1..128, amount_minor küçük birimde 0..2^53-1 tam sayı, currency ISO 4217, quantity 0..100000)"
            .to_string(),
    )
}

/// Gelir girdisini sözleşme özelliklerine çevirir; geçersiz girdide `Error::InvalidEvent` döner. Tüm SDK'larda aynı kurallar:
/// transaction_id 1..128, amount_minor 0..2^53-1, currency `^[A-Z]{3}$`, product_id 1..128, quantity 0..100000, abonelik iptalinde
/// tutar 0, makbuz belirteci 1..8192.
pub fn revenue_properties(revenue: &Revenue) -> Result<Map<String, Value>, Error> {
    let transaction_length = revenue.transaction_id.chars().count();
    if transaction_length == 0 || transaction_length > MAX_TRANSACTION_ID_LENGTH {
        return Err(invalid());
    }
    if !(0..=MAX_AMOUNT_MINOR).contains(&revenue.amount_minor) {
        return Err(invalid());
    }
    let currency = revenue.currency.as_bytes();
    if currency.len() != 3 || !currency.iter().all(u8::is_ascii_uppercase) {
        return Err(invalid());
    }
    if let Some(product_id) = &revenue.product_id {
        let length = product_id.chars().count();
        if length == 0 || length > MAX_PRODUCT_ID_LENGTH {
            return Err(invalid());
        }
    }
    let quantity = revenue.quantity.unwrap_or(1);
    if !(0..=MAX_QUANTITY).contains(&quantity) {
        return Err(invalid());
    }
    // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
    if revenue.purchase_type == PurchaseType::SubscriptionCancel && revenue.amount_minor != 0 {
        return Err(invalid());
    }
    if let Some(receipt) = &revenue.receipt {
        let length = receipt.token.chars().count();
        if length == 0 || length > MAX_RECEIPT_TOKEN_LENGTH {
            return Err(invalid());
        }
    }

    let mut props = revenue.properties.clone();
    for key in REVENUE_RESERVED_KEYS {
        props.remove(key);
    }
    props.insert("transaction_id".to_string(), Value::from(revenue.transaction_id.as_str()));
    props.insert("amount_minor".to_string(), Value::from(revenue.amount_minor));
    props.insert("currency".to_string(), Value::from(revenue.currency.as_str()));
    props.insert("quantity".to_string(), Value::from(quantity));
    props.insert("purchase_type".to_string(), Value::from(revenue.purchase_type.as_str()));
    if let Some(product_id) = &revenue.product_id {
        props.insert("product_id".to_string(), Value::from(product_id.as_str()));
    }
    if let Some(receipt) = &revenue.receipt {
        props.insert("receipt".to_string(), json!({ "provider": receipt.provider.as_str(), "token": receipt.token }));
    }
    Ok(props)
}

impl Client {
    /// Satın alma ya da abonelik beyanını `feralin_purchase` olayı olarak kuyruğa ekler. `track` ile aynı izin ve kuyruk kurallarına
    /// tabidir (`analytics` izni yoksa `Ok(None)`); sözleşme dışı girdide `Error::InvalidEvent` döner ve olay üretilmez.
    pub fn track_revenue(&self, revenue: Revenue) -> Result<Option<TrackedEvent>, Error> {
        let properties = revenue_properties(&revenue)?;
        let mut event = Event::new(REVENUE_EVENT_NAME).properties(properties);
        event.user_id = revenue.user_id;
        event.anonymous_id = revenue.anonymous_id;
        event.session_id = revenue.session_id;
        event.occurred_at = revenue.occurred_at;
        event.context = revenue.context;
        self.track(event)
    }
}
