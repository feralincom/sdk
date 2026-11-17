<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Go: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/go/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Go |
| Paket | `feralin.dev/sdks/go` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/go` |
| Registry | Go modules: **BLOCKED_EXTERNAL** (gereken: Public Git deposu, kalıcı modül yolu ve Git tag) |
| Derleme | `cd sdks/go && go build ./...` |
| Test | `cd sdks/go && go test -count=1 ./...` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `Go modules` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```go
// go.mod
require feralin.dev/sdks/go v0.1.0
replace feralin.dev/sdks/go => ../../sdks/go
```

## İlk kullanım

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

```go
client.SetGlobalProperties(map[string]any{"app_release": "2.4.0"}) // adı fr_ ile başlamayan her olaya eklenir; nil anahtarı siler
who := feralin.Identity{UserID: "user_42"}
client.SetUserProperties(ctx, map[string]any{"plan": "pro"}, who)   // fr_user_properties; geçerli özellik yoksa (nil, nil)
client.Group(ctx, "acme-team", map[string]any{"plan": "team"}, who) // fr_group; geçersiz group_id → (nil, nil)
client.ClearGlobalProperties()
```

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız) |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil) |
| consent | SUPPORTED (yayınsız; istemci düzeyinde) |
| identity | SUPPORTED (yayınsız; Identify ve olay başına kimlik, Group → fr_group, SetUserProperties → fr_user_properties, SetGlobalProperties/ClearGlobalProperties eşzamanlı güvenli; istemcide anahtar, değer ve kişisel veri süzgeci; toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar; birim, race testli ve gerçek collect e2e ile sınandı) |
| attribution | N/A |
| deeplink | N/A |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; go test testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS |  |
| registry | BLOCKED_EXTERNAL | Uzak depo private; herkese açık kalıcı modül yolu kararı yok, modül yolu geçici. |
| clean_install | PARTIAL | Boş modül yerel kaynağa replace ile bağlandı; go get denenemez. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs go: 202, outbox satırı, izinsiz red, 401, idempotency. |
| documentation | PASS | docs/sdk/go.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
