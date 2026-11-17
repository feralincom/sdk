# @feralin/tauri

Tauri uygulamasının JS tarafı. Web görünümünde `@feralin/web` çalışır, olaylar web görünümünden gönderilir. **Rust eklentisi bu pakette yoktur** ve ayrı işte yazılacaktır.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (vitest, jsdom, window'suz yükleme) | Geçiyor |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs tauri` ile geçti (jsdom, Tauri işareti elle konur) |
| Gerçek Tauri penceresi | **Çalıştırılmadı.** WebView, CSP ve `tauri://` kökeni sınanmadı |
| npm yayını | `BLOCKED_EXTERNAL`: `@feralin` organizasyonu yok |

## Kurulum

```bash
pnpm --filter @feralin/web build
cd packages/sdk-web && npm pack
cd ../../sdks/tauri && npm pack
npm install ./feralin-web-0.1.0.tgz ./feralin-tauri-0.1.0.tgz
```

## Kullanım

```ts
import { createFeralinTauri } from "@feralin/tauri";

const feralin = createFeralinTauri({ projectKey: "pk_live_…", collectUrl: "https://collect.example.com", consent: { analytics: true } });
feralin.page();
feralin.track("project_opened");
```

`tauri.conf.json` içindeki CSP varsa `connect-src` toplayıcı adresini içermelidir. Tauri dışında (tarayıcıda `vite dev`) boş yüzey döner; olay istiyorsanız `allowOutsideTauri: true` verin. `autoTrack` varsayılanı kapalıdır, ekran değişiminde `page()` çağırın.

## Gelir, hata ve derin bağlantı

```ts
import { captureErrors } from "@feralin/web/errors";
import { getCurrent, onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { createFeralinTauri } from "@feralin/tauri";

const feralin = createFeralinTauri({
  projectKey: "pk_live_…",
  collectUrl: "https://collect.example.com",
  errors: { captureErrors, appVersion: "1.4.0" },
  deepLinks: { schemes: ["myapp"], onOpenUrl, getCurrent },
});
feralin.trackRevenue({ transactionId: "ord_1", amountMinor: 4999, currency: "TRY" });
try { kaydet(); } catch (error) { feralin.captureError(error); }
```

- `trackRevenue` `feralin_purchase` istemci beyanıdır; `verified` gönderilmez.
- `errors` verilmezse hata dinlenmez, `captureError` `false` döner. Kurallar `@feralin/web/errors` ile aynıdır (sınır, örnekleme, PII temizliği).
- `deepLinks.schemes`, `tauri.conf.json` içindeki `plugins.deep-link.desktop.schemes` ile aynı olmalıdır. Windows ve Linux'ta uygulama zaten açıkken gelen adres ikinci örneğe gider: `tauri-plugin-single-instance` eklentisini `deep-link` özelliğiyle kurun, adres `onOpenUrl` dinleyicisine iletilir. macOS adresi doğrudan `onOpenUrl`'e verir (Mac'te sınanmadı).
- Her izinli adres `deep_link_opened` olayıdır. Sorgudan yalnız `fr_click` ve `utm_*` okunur ve yalnız `advertising: true` iken olaya yazılır (`attribution_source: "app_link"`); izin yoksa `attribution_source: "none"`. Analitik izni yokken gelen adres sayılmaz, bellekte de tutulmaz. Ham adres ve sorgu saklanmaz.
- `stop()` hata dinleyicilerini ve derin bağlantı aboneliğini kaldırır.

## İzin

`consent` verilmezse olay üretilmez; `feralin.setConsent({ analytics: true, advertising: false })` çağırın. Reklam izni yoksa `fr_click` çıkarılır. Yalnız public anahtar (`pk_`) kabul edilir; `sk_` ve başka önekler sunucuda ve tarayıcıda reddedilir, boşluklar kırpılır.

## Desteklenmeyenler

- Rust tarafı, uygulama kapanışında yerel gönderim, şifreli kuyruk yoktur. Derin bağlantı yalnız `deepLinks` ile ve web görünümü açıkken işlenir. Kuyruk web görünümünün `localStorage` alanındadır.
- Olaylarda `platform` değeri `web`tir; UTP şemasında masaüstü değeri yoktur.
- Replay yoktur. Derin bağlantı olayında `page_url` bağlamı yoktur: çekirdek sayfa adresini pencereden alır.
- Çekirdekten gelen sınırlar: üstel geri çekilme yok; yanıt kaybolduktan sonra araya olay girerse `Idempotency-Key` değişir ve kaybolan olay outbox'a ikinci kez yazılır.
