# Feralin Go SDK (`feralin-go`) — UTP v1 server client

Feralin toplayıcısına (`services/collect`, `POST /v1/batch`) **sunucu tarafından** olay gönderen resmî Go SDK'sı.
Yalnız standart kütüphane (`net/http`, `crypto/rand`, `log/slog`); dış bağımlılık yok. Go 1.26.

## Durum (dürüst)

| Konu | Durum |
|---|---|
| Kod: `NewClient`, `Track`, `Identify`, `SetConsent`, `Flush`, `Close`, `Status` | `TESTING` — `httptest` ile 24 test geçti |
| Yayın: `go get feralin.dev/sdks/go` | **Henüz yayımlanmadı — `BLOCKED_EXTERNAL`.** Modül yolu geçicidir; kalıcı yol (ör. `github.com/feralin/feralin-go`) ve Git tag namespace sahipliği doğrulanınca belirlenir. Yaşam döngüsü `PROPOSED → … → PUBLISHED → REGISTRY_VERIFIED → INSTALL_VERIFIED → SUPPORTED`: `docs/sdk/capability-matrix.md` §0 ve §4 |
| Gerçek `collect` ile uçtan uca | `scripts/sdk-e2e/run.mjs go` ile doğrulandı: 202, outbox satırı, izinsiz red, yanlış anahtar 401, idempotency |
| İmzalı server event (`verified`), OTel tracing | Yok — F3/F5 (`verified` alanı istemciden **asla** gönderilmez; `TrackRevenue` `feralin_purchase` istemci beyanı üretir, doğrulama sunucuda) |

## Kurulum

Monorepo içinde `replace` ile kullanın (yayın öncesi tek yol):

```go
// go.mod
require feralin.dev/sdks/go v0.1.0
replace feralin.dev/sdks/go => ../../sdks/go
```

Yayın sonrası (henüz çalışmaz): `go get feralin.dev/sdks/go`.

## Kullanım

```go
import feralin "feralin.dev/sdks/go"

client, err := feralin.NewClient("pk_live_…", "https://collect.example.com",
    feralin.WithConsent(feralin.Consent{Analytics: true}), // consent-first: varsayılan analytics=false
    feralin.WithFlushInterval(2*time.Second),              // 0 → arka plan gönderici kapalı
    feralin.WithBatchSize(100),                            // ≤ 500
    feralin.WithQueueLimit(1000),                          // aşılırsa en eski olay atılır
    feralin.WithHTTPClient(&http.Client{Timeout: 10 * time.Second}),
    feralin.WithLogger(slog.Default()),
)
if err != nil { /* ErrSecretKey, ErrInvalidProjectKey, ErrInvalidCollectURL */ }
defer client.Close() // kalan olayları en fazla 5 sn içinde gönderir

ev, err := client.Track(ctx, feralin.Event{
    Name:       "order_completed",                  // snake_case, ≤100
    UserID:     "user_42",                          // müşteri uygulamasının kimliği; PII değil
    Properties: map[string]any{"order_id": "ord_1", "amount": 249.9}, // ≤100 anahtar, ^[a-zA-Z][a-zA-Z0-9_]{0,63}$
    Context:    &feralin.Context{Locale: "tr-TR", Timezone: "Europe/Istanbul"},
})
// consent.analytics=false → ev == nil && err == nil (olay üretilmez; Web SDK ile tutarlı)
// doğrulama hatası     → errors.Is(err, feralin.ErrInvalidEventName | ErrInvalidPropertyKey | ErrTooManyProperties | ErrInvalidIdentifier)

res, err := client.Flush(ctx)
// 202              → err == nil; res.Accepted/Rejected/BatchID
// 4xx (429 hariç)  → errors.Is(err, feralin.ErrRejected); olaylar atıldı
// 5xx / 429 / ağ   → errors.Is(err, feralin.ErrTemporary); olaylar kuyrukta, backoff 1 sn → 30 sn (Retry-After'a uyar)
```

Örnek: `FERALIN_PROJECT_KEY=pk_live_… FERALIN_COLLECT_URL=http://127.0.0.1:8081 go run ./examples/basic`
(yerel `collect` için anahtar `COLLECT_PROJECT_KEYS="pk_live_…=tenant_dev:proj_dev"` ile tanımlanmalı; SDK `pk_` dışındaki anahtarı reddeder).

### Kimlik yöntemleri (UTP §8.2)

```go
client.SetGlobalProperties(map[string]any{"app_release": "2.4.0"}) // adı fr_ ile başlamayan her olaya eklenir; nil anahtarı siler
who := feralin.Identity{UserID: "user_42"}
client.SetUserProperties(ctx, map[string]any{"plan": "pro"}, who)   // fr_user_properties; geçerli özellik yoksa (nil, nil)
client.Group(ctx, "acme-team", map[string]any{"plan": "team"}, who) // fr_group; geçersiz group_id → (nil, nil)
client.ClearGlobalProperties()
```

### Hata yakalama (`fr_error`)

```go
client, _ := feralin.NewClient(key, url, feralin.WithAppVersion("2.4.0"), feralin.WithErrorSampleRate(1))
if err := charge(ctx); err != nil {
    client.CaptureError(ctx, err, feralin.ErrorOptions{Identity: who}) // varsayılan origin "handled"
}
defer func() {
    if r := recover(); r != nil {
        client.CaptureError(ctx, fmt.Errorf("%v", r), feralin.ErrorOptions{Origin: feralin.ErrorOriginUncaught, Fatal: true})
        panic(r)
    }
}()
```

Gövde Android, React Native ve Web SDK ile aynı sözleşmedir: `error_type` (paketsiz tür adı, ≤64), temizlenmiş `message` (URL, e-posta, UUID, rakam içeren uzun belirteç ve en az 7 haneli sayı etiketlenir, ≤200), `fingerprint` (tür ve ilk beş çerçevenin FNV-1a 64 özeti, 16 onaltılı; çerçeve yoksa rakamsız mesaj), `top_frame`, `frame_count`, `app_version` (verildiyse, ≤32), `handled`, `fatal`, `origin` (`handled`, `manual`, `uncaught_exception`). Ham yığın izi, dosya yolu ve satır numarası gitmez. Süreç başına en çok 20, aynı parmak izi için en çok 3 olay; izin yoksa olay üretilmez. Go hatası yığın taşımadığı için çerçeveler `CaptureError` çağrısının yığınından alınır (`paket.İşlev`; uygulama çerçevesi varsa standart kütüphane atılır), bu yüzden aynı işlevde yakalanan aynı türden hatalar tek parmak izinde toplanır. `fmt.Errorf` ve `errors.New` sarmalayıcılarında zincirdeki ilk uygulama türü `error_type` olur.

Kurallar bütün SDK'larda ve toplayıcıda aynıdır: anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, çağrı başına en çok 50 özellik; değer yalnız dizge (≤256 karakter, kontrol karakteri yok, e-posta biçiminde değil), sonlu sayı ya da mantıksal. Doğrulama alanları (`verified`, `receipt` vb.) ve kişisel veriye benzeyen anahtarlar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) istemcide düşer. Toplayıcı ayrıca projenin özellik izin listesini uygular: listede olmayan anahtar saklanmaz, liste boşsa olay sayılır ama hiçbir özellik saklanmaz. Olayın kendi özelliği aynı anahtardaki globali ezer; global en çok 50 anahtar tutar ve eşzamanlı kullanım güvenlidir. `group_id` 1-128 karakterdir, `@` ve kontrol karakteri içeremez.

## Sözleşme

- Tel biçimi `packages/schemas/utp/v1/event.schema.json` ile birebir: `platform="go"`, `schema_version=1`,
  `sdk={name:"feralin-go",version:"0.1.0"}`, `occurred_at` UTC RFC3339 ms, `event_id` monotonik ULID.
- `tenant_id`, `project_id`, `verified` **gönderilmez**; sunucu `X-Feralin-Project-Key` bağlamından çözer.
- `Idempotency-Key`, Web SDK ile aynıdır: sıralı tüm `event_id` değerlerinin FNV-1a 64 özeti ve olay sayısı. Sonucu bilinmeyen batch aynı içerik ve aynı anahtarla yeniden denenir (toplayıcı tekrarı `202 accepted:0` ile yutar); araya giren olaylar sonraki batch'e kalır.
- `fr_click` yalnız `consent.Advertising == true` iken gönderilir, aksi halde olaydan çıkarılır.
- Aynı anda tek gönderici; `Track` eşzamanlı çağrılabilir. Kuyruk bellek içidir (süreç ölürse kaybolur; kalıcı kuyruk F3 kararı).
- Anahtar ve ham olay içeriği loglanmaz.

## Geliştirme

```bash
cd sdks/go
gofmt -l . && go vet ./... && go test -race ./...
```
