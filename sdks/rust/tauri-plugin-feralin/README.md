# tauri-plugin-feralin

Tauri 2 eklentisi: webview ve Rust tarafı aynı `feralin::Client` üzerinden olay gönderir. `cargo build -p tauri-plugin-feralin` Tauri 2.12 ile Windows'ta derlendi ve clippy uyarısız (13 Kasım 2026). Eklentinin kendi testi yoktur; gerçek bir Tauri uygulamasında ve pencerede denenmedi.

## Kurulum

```toml
# src-tauri/Cargo.toml
[dependencies]
feralin = { path = "../sdks/rust" }
tauri-plugin-feralin = { path = "../sdks/rust/tauri-plugin-feralin" }
```

```rust
// src-tauri/src/main.rs
use feralin::{Config, Consent};

fn main() {
    let plugin = tauri_plugin_feralin::init(
        Config::new("pk_live_...", "https://collect.example.com").consent(Consent::default()),
    )
    .expect("Feralin yapılandırması geçersiz");

    tauri::Builder::default()
        .plugin(plugin)
        .run(tauri::generate_context!())
        .expect("uygulama çalışmadı");
}
```

Komutlar varsayılan olarak kapalıdır; yetenek dosyasında izin verin:

```json
{ "permissions": ["feralin:default"] }
```

## Webview

Bu sürümde npm bağlama paketi yoktur; `@tauri-apps/api` ile doğrudan çağrılır:

```ts
import { invoke } from "@tauri-apps/api/core";

await invoke("plugin:feralin|set_consent", { consent: { analytics: true } });
await invoke("plugin:feralin|track", { name: "order_completed", properties: { order_id: "ord_1" } });
const sonuc = await invoke("plugin:feralin|flush");
```

İzin yoksa `track` `null` döner. `fr_click` reklam izni olmadan çıkarılır. Deep link protokolü, replay ve masaüstü context toplama yoktur. Olaylar bellekte tutulur; uygulama çıkışında en fazla 2 sn içinde gönderilmeye çalışılır, kalanı kaybolur.
