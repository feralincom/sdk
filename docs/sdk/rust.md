<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Rust: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/rust/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Rust |
| Paket | `feralin, tauri-plugin-feralin` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | REGISTRY_VERIFIED |
| Kaynak dizin | `sdks/rust` |
| Registry | crates.io: **PUBLISHED** (sonraki adım: crates.io hesabı (GitHub girişi, doğrulanmış e-posta); publish-new kapsamlı cio önekli API anahtarı (CARGO_REGISTRY_TOKEN); ad rezervasyonu yok, feralin ilk yayında alınır; trusted publishing yalnız ilk sürümden sonra) |
| Derleme | `cd sdks/rust && cargo build --workspace` |
| Test | `cd sdks/rust && cargo test --workspace` |

## Kurulum

```toml
[dependencies]
feralin = { path = "../sdks/rust" }
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız; gerçek toplayıcıyla sınandı) |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil; aynı içerik ve Idempotency-Key ile üstel geri çekilmeli tekrar) |
| consent | SUPPORTED (yayınsız; istemci düzeyinde, fr_click yalnız reklam izniyle) |
| identity | PARTIAL (identify; group → fr_group, set_user_properties → fr_user_properties cargo testli; reset ve global özellik yok) |
| attribution | N/A |
| deeplink | N/A |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; cargo test testli, gerçek toplayıcı e2e yok) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, yığın izi yok (frame_count 0); sınır ve örnekleme; cargo test testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS | feralin crate ve tauri-plugin-feralin; Cargo.lock depoda; cargo fmt --check ve cargo clippy --workspace --all-targets -D warnings temiz (Rust 1.100, Windows MSVC). |
| build | PASS | cargo build: feralin (ureq 3.5, rustls) ve tauri-plugin-feralin (Tauri 2.12) Windows'ta derlendi. Linux ve macOS'ta derlenmedi. |
| test | PASS | cargo test --workspace: 11 modül, 23 istemci, 4 gerçek HTTP testi ve 1 doküman testi geçti; Tauri eklentisinin kendi testi yok (0 test). |
| registry | PASS | crates.io'da yayımlandı: feralin 0.1.0 (19 Kasım 2026, git 074f400f, cargo publish; crates.io hesabı site sahibinin GitHub hesabıyla). Geri okuma: crates.io API max_version 0.1.0, .crate sha256 b859634db61ccdd4 yerel paketle aynı. |
| clean_install | PASS | scripts/sdk-e2e/targets/rust.mjs: crate kopyası boş tüketici crate'ine yerel yolla bağlanıp derlendi; crates.io'dan kurulum denenemez. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs rust: gerçek services/collect + PostgreSQL outbox; 202, fr_click yalnız reklam izniyle, izinsiz olay üretilmez ve toplayıcı reddeder, yanlış anahtar 401, yanıt kaybında aynı anahtarla tek outbox satırı. Tauri eklentisi gerçek pencerede koşmadı. |
| documentation | PASS | docs/sdk/rust.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
