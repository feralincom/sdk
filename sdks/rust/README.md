# Feralin Rust SDK (`feralin`)

Sunucu, CLI ve masaüstü için UTP v1 istemcisi. Olaylar `POST /v1/batch` üzerinden gider. Tauri 2 eklentisi `tauri-plugin-feralin/` altındadır.

## Durum

| Konu | Durum |
|---|---|
| Kod ve testler | Rust 1.100 (Windows, MSVC) ile derlendi; `lifecycle: INTEGRATION_TESTED` |
| `cargo build`, `cargo test` | `PASS` (16 Kasım 2026): 15 modül, 23 istemci, 9 gelir/kimlik/hata sözleşmesi, 4 gerçek HTTP testi ve 1 doküman testi; `cargo fmt --check` ve `cargo clippy --all-targets -D warnings` temiz (Tauri eklentisi bu turda yeniden derlenmedi) |
| Gerçek `services/collect` | `PASS`: `node scripts/sdk-e2e/run.mjs rust` (crate kopyası boş tüketiciye yerel yolla bağlanır; 202 + outbox, fr_click izin kuralı, izinsiz red, 401, aynı anahtarla idempotent tekrar) |
| Tauri eklentisi | `cargo build -p tauri-plugin-feralin` Tauri 2.12 ile derlendi; eklentinin kendi testi yok, gerçek Tauri uygulamasında ve pencerede denenmedi |
| crates.io yayını | Yayında: `feralin` 0.1.0 (19 Kasım 2026); `cargo add feralin` |

`Cargo.lock` depodadır (yeniden üretilebilir yerel koşu için; crate yayınında kullanılmaz). Yerel doğrulama: `scripts/ci-local.sh --only sdk-rust`.

## HTTP kararı: `ureq`

`ureq` 3 + `rustls` seçildi, yalnız std + rustls ya da `reqwest` değil:

- **Yalnız std + rustls değil:** std'de HTTP yok. HTTP/1.1, parçalı gövde, zaman aşımı ve yönlendirmeyi elle yazmak gizli hata yüzeyi açar; bu SDK'nın işi değildir.
- **`reqwest` değil:** tokio ister. SDK kendi iş parçacığıyla gönderir, async zorunlu değildir ve Tauri ya da CLI uygulamasına çalışma zamanı dayatılmamalıdır.
- **`rustls`:** OpenSSL gerektirmez, çapraz derleme kolaydır. `ureq`'in `rustls` özelliği `ring` kullanır; bazı hedeflerde C derleyicisi gerekir.
- `default-features = false`: gzip açılmaz, çünkü toplayıcı yanıtı küçük JSON'dur.

Başka ağ yığını kullanmak için `Config::transport` ile `Transport` verilir. En düşük Rust sürümü 1.85.

## Kurulum

Yayın olmadığından yerel yolla:

```toml
[dependencies]
feralin = { path = "../sdks/rust" }
```

## En kısa örnek

```rust
use std::time::Duration;
use feralin::{Client, Config, Consent, Event};

let client = Client::new(
    Config::new("pk_live_...", "https://collect.example.com")
        .consent(Consent { analytics: true, ..Consent::default() }),
)?;

client.track(Event::new("order_completed").property("order_id", "ord_1").user_id("user_42"))?;
let sonuc = client.flush()?;            // ağ hatasında Err vermez, sonuç sonuc.error içinde
client.close(Duration::from_secs(5));   // çıkmadan önce çağırın
# Ok::<(), feralin::Error>(())
```

`sk_` ile başlayan gizli anahtar reddedilir. `Drop` ağ çağrısı yapmaz: `close` çağrılmadan düşen istemcinin kuyruğu kaybolur.

## İzin

Varsayılan izin hepsi kapalıdır. Karar uygulamanındır; `Config::consent` ve `Client::set_consent` ile verilir.

- `analytics` yoksa olay üretilmez, `track` `Ok(None)` döner. Geri çekilince kuyruk atılır.
- `advertising` yoksa `fr_click` çıkarılır.
- 401 ve 403 kuyruğu atar, uygulama düşmez. Ağ hatası, 5xx ve 429 kuyrukta tutar, aynı `Idempotency-Key` ile 1 sn → 30 sn geri çekilmeyle yeniden dener.

Anahtar loglanmaz; SDK log yazmaz. PII toplanmaz, parmak izi yok, `verified` gönderilmez. `Status` anahtar içermez.

## Gelir, kimlik ve hata

```rust
use feralin::{ErrorReport, Identity, PurchaseType, ReceiptProvider, Revenue};
use serde_json::{json, Map};

// Satın alma beyanı: `feralin_purchase`. Tutar küçük birimde tam sayı (49,99 TL = 4999), para birimi ISO 4217.
client.track_revenue(
    Revenue::new("ord_1", 4999, "TRY")
        .product_id("pro")
        .purchase_type(PurchaseType::SubscriptionStart)
        .receipt(ReceiptProvider::Stripe, "tok_..."),
)?;

// Grup ve kullanıcı özellikleri: `fr_group`, `fr_user_properties`.
let mut traits = Map::new();
traits.insert("plan".into(), json!("pro"));
client.group("acct_1", traits.clone(), Identity { user_id: Some("user_42".into()), ..Identity::default() })?;
client.set_user_properties(traits, Identity::default())?;

// Yakalanan hata: `fr_error`.
if let Err(error) = "x".parse::<i32>() {
    client.capture_error(&error)?;
}
client.capture_error_report(ErrorReport::new("CheckoutTimeout", "ödeme 30 sn içinde yanıt vermedi"))?;
# Ok::<(), feralin::Error>(())
```

- **`track_revenue`** istemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır. `verified`, `verification`, `receipt_digest` gibi alanlar çağıranın özelliklerinden düşürülür. Kurallar Web SDK `buildRevenueProperties` ile aynıdır: `transaction_id` 1..128, `amount_minor` 0..2^53-1, `currency` `^[A-Z]{3}$`, `quantity` 0..100000 (varsayılan 1), abonelik iptalinde tutar 0, makbuz belirteci 1..8192. Geçersiz girdi `Error::InvalidEvent` döner.
- **`group` / `set_user_properties`**: anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, çağrı başına en çok 50 özellik (sözlük sırası); değer dizge (≤256, kontrol karakteri yok, e-posta biçiminde değil), sayı ya da bool. Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad, adres, kimlik no, parola, doğum tarihi) ve doğrulama alanı düşer. Geçersiz grup kimliği (`@`, kontrol karakteri, boş, >128) `Error::InvalidEvent`; geçerli özellik kalmazsa `set_user_properties` `Ok(None)` döner. Toplayıcı yalnız projenin izin listesindeki anahtarları saklar.
- **`capture_error` / `capture_error_report`**: `error_type` (türün kısa adı, ≤64), temizlenmiş `message` (URL, e-posta, UUID, rakamlı uzun belirteç ve 7+ rakamlı sayı etiketlenir; ≤200), `fingerprint` (FNV-1a 64, `tür|rakamsız mesaj`), `frame_count`, `handled`, `fatal`, `origin` ve `Config::app_version` verildiyse `app_version` (≤32). Rust hataları yığın izi taşımaz: çerçeve listesi boştur, `top_frame` gitmez; ham yığın izi ve dosya yolu hiçbir zaman gitmez. Süreç başına en çok 20 olay, aynı parmak izi için 3; `Config::error_sample_rate` ile örnekleme. İzin yoksa sayaç tüketilmez.

## Desteklenmeyenler

- Kalıcı kuyruk yok: bellek içidir, süreç ölünce kaybolur.
- `reset`, `page`, `screen`, global özellikler, yakalanmamış panik kancası, makbuz doğrulama (sunucuda, `BLOCKED_EXTERNAL`) ve OTel yok.
- Async API yok. Bloklayan çağrı `flush` ve `close`'dur; `track` ağ çağrısı yapmaz. Tokio içinde `spawn_blocking` ile çağırın.
- `property` ile verilen `NaN` ve sonsuz değer `serde_json` tarafından `null` yapılır, hata dönmez. Python SDK bunları reddeder.
- Attribution ve deep link uygulanamaz: masaüstü ve sunucu.

## Geliştirme

```bash
cd sdks/rust
cargo build
cargo test
cargo build -p tauri-plugin-feralin   # masaüstü sistem kütüphaneleri ister
DATABASE_URL='postgres://KULLANICI:PAROLA@127.0.0.1:5432/TEST_VERITABANI?sslmode=disable' node ../../scripts/sdk-e2e/run.mjs rust
```
