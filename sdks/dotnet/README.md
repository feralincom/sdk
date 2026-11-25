# Feralin .NET SDK

`Feralin.Sdk`, sunucu tarafından `POST /v1/batch` ucuna UTP v1 olayı gönderir. Çalışma zamanı bağımlılığı yoktur. `Feralin.Sdk.AspNetCore` DI kaydı ve kapanışta gönderim ekler, yalnız ASP.NET Core çerçevesine bağlıdır. `net8.0` ve `net9.0` hedeflenir.

## Durum

| Konu | Durum |
|---|---|
| Kod, birim testleri, `dotnet pack` | Geçiyor |
| Gerçek `services/collect` + PostgreSQL, `.nupkg` temiz kurulum, QA-C yerel | `scripts/sdk-e2e/run.mjs dotnet` ile doğrulandı |
| NuGet yayını | Yayında: `Feralin.Sdk` ve `Feralin.Sdk.AspNetCore` 0.1.0 (19 Kasım 2026); `dotnet add package Feralin.Sdk` |
| Gelir doğrulaması (QA-C F5 kısmı) | Kısmi: `TrackRevenue` `feralin_purchase` istemci beyanı üretir; `verified` yalnız sunucu makbuz doğrulayıcısıyla (adaptör BLOCKED_EXTERNAL) |

## Kurulum

nuget.org'dan: `dotnet add package Feralin.Sdk` (ASP.NET Core için `Feralin.Sdk.AspNetCore`). Yerel paket kaynağıyla geliştirme:

```bash
dotnet pack src/Feralin.Sdk/Feralin.Sdk.csproj -c Release -o ./paketler
dotnet pack src/Feralin.Sdk.AspNetCore/Feralin.Sdk.AspNetCore.csproj -c Release -o ./paketler
dotnet add package Feralin.Sdk.AspNetCore --version 0.1.0 --source ./paketler
```

## Kullanım

```csharp
builder.Services.AddFeralin(o =>
{
    o.ProjectKey = builder.Configuration["Feralin:ProjectKey"]!; // pk_… anahtarı; kaynak koda yazmayın
    o.CollectUrl = "https://collect.example.com";
});

app.MapPost("/orders", (OrderRequest order, FeralinClient feralin) =>
{
    // İzin kararı son kullanıcınındır; uygulamadan olay başına geçirilir.
    feralin.Track(
        "order_completed",
        new Dictionary<string, object?> { ["order_id"] = order.Id, ["fr_click"] = order.ClickId },
        new TrackOptions { UserId = order.UserId, Consent = new Consent(order.Analytics, order.Advertising) });
    return Results.Accepted();
});
```

DI olmadan: `await using var client = new FeralinClient(new FeralinOptions { ... });`

## Kurallar

| Konu | Davranış |
|---|---|
| İzin | Varsayılan `analytics=false`. İzin yoksa `Track` `null` döner, olay üretilmez, istek yapılmaz |
| Açık ret | `SetConsent(new Consent(false))` veya `OptOut()` kuyruğu siler, olay bazlı izin de geçersiz olur |
| `fr_click` | Yalnız `Advertising == true` iken gönderilir, aksi halde çıkarılır |
| Anahtar | Yalnız `x-feralin-project-key` başlığında. `sk_` kurucuda reddedilir. Log ve durum çıktısında yoktur |
| Idempotency | Sıralı tüm `event_id` değerlerinin FNV-1a 64 özeti + sayı; Web, Node, Android ile aynı |
| Yeniden deneme | `202` ve kalıcı `4xx` kuyruktan siler. `429`, `5xx`, ağ hatası aynı içerik ve anahtarla denenir. Üstel 1 sn ile 30 sn, yarım jitter, `Retry-After` uyumlu |
| Hata | Yapılandırma hatası kurucuda fırlar (Web SDK ile aynı). Çalışma zamanında hiçbir metot fırlatmaz |
| URL | `page_url` sorgusuz, `referrer` yalnız origin. `utm_*` özelliklere taşınır |
| Kuyruk | Bellek içi, en çok 1000 olay, aşılınca en eski atılır. Süreç ölürse kaybolur; kapanışta `CloseAsync` çağırın. DI kaydı bunu otomatik yapar |

## Kimlik yöntemleri (UTP §8.2)

```csharp
client.SetGlobalProperties(new Dictionary<string, object?> { ["app_release"] = "2.4.0" });  // fr_ ile başlamayan her olaya eklenir
client.SetUserProperties(new Dictionary<string, object?> { ["plan"] = "pro", ["seats"] = 12 }, new TrackOptions { UserId = "user_42" });
client.Group("acme-team", new Dictionary<string, object?> { ["plan"] = "team" }, new TrackOptions { UserId = "user_42" });
```

- `SetUserProperties` → `fr_user_properties`, `Group` → `fr_group` (`group_id` + özellikler). Kimlik olay başına `TrackOptions` ile verilir.
- Anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, çağrı başına en çok 50 özellik; değer dizge (≤256 karakter, e-posta biçimi değil), sonlu sayı ya da mantıksal. Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) ve `verified` gibi doğrulama alanları istemcide düşer; geçerli özellik kalmazsa olay üretilmez.
- `group_id` 1-128 karakter, `@` ve kontrol karakteri içermez; uymazsa olay üretilmez (`null`).
- Global özellik: `null` değer anahtarı siler, `ClearGlobalProperties` hepsini siler, toplam en çok 50 anahtar. Olayın kendi özelliği aynı anahtarda kazanır. Sunucu SDK'sında bütün kullanıcılara ortaktır; `Reset` silmez.
- Toplayıcı yalnız projenin özellik izin listesindeki anahtarları saklar; liste boşsa olay sayılır ama özellik saklanmaz.

## Hata yakalama (`fr_error`)

```csharp
var client = new FeralinClient(new FeralinOptions { ProjectKey = "pk_live_…", CollectUrl = "https://collect.example.com", AppVersion = "2.4.0", ErrorSampleRate = 1.0 });
try { Charge(); }
catch (Exception ex) { client.CaptureError(ex, options: new TrackOptions { UserId = "user_42" }); }   // origin varsayılanı "handled"
AppDomain.CurrentDomain.UnhandledException += (_, e) => client.CaptureError((Exception)e.ExceptionObject, ErrorOrigin.UncaughtException, fatal: true);
```

Gövde Android, React Native ve Web SDK ile aynı sözleşmedir: `error_type` (paketsiz tür adı, ≤64), temizlenmiş `message` (URL, e-posta, UUID, rakam içeren uzun belirteç ve en az 7 haneli sayı etiketlenir, ≤200), `fingerprint` (tür ve ilk beş çerçevenin FNV-1a 64 özeti, 16 onaltılı; çerçeve yoksa rakamsız mesaj), `top_frame`, `frame_count`, `app_version` (verildiyse, ≤32), `handled`, `fatal`, `origin` (`handled`, `manual`, `uncaught_exception`). Ham yığın izi, dosya yolu ve satır numarası gitmez. Süreç başına en çok 20, aynı parmak izi için en çok 3 olay; izin yoksa olay üretilmez. Çerçeveler `Ad.Alanı.Tür.Yöntem` biçimindedir (async durum makinesi ve lambda adları özgün yönteme indirgenir); uygulama çerçevesi varsa `System.*`, `Microsoft.*` ve SDK çerçeveleri atılır. Fırlatılmamış istisnada çerçeve yoktur.

## Kurulum eşleştirme kodu

`FeralinOptions.InstallCode` (Feralin kurulum ekranındaki kısa kod) kırpılmış hâli `^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$` desenine uyarsa ilk kuyruğa giren olaya `fr_install_code` olarak bir kez eklenir; uymazsa yok sayılır. Web SDK ve toplayıcıyla aynı kural; asıl kullanım yeri MAUI ve masaüstü uygulamalarıdır.

## Bilinçli eksikler

OTel yoktur; `trackRevenue` `feralin_purchase` istemci beyanı üretir, doğrulama sunucudadır. Diskte kalıcı kuyruk yoktur.

## Geliştirme

```bash
cd sdks/dotnet
dotnet test Feralin.sln
DATABASE_URL='postgres://kullanici:parola@127.0.0.1:5432/test_db?sslmode=disable' node ../../scripts/sdk-e2e/run.mjs dotnet
```

İkinci komut `services/collect`'i derleyip başlatır, paketleri boş dizine kurar, gerçek olay gönderir ve testin kendi `batch_id` ile `event_id` değerlerini `collect_outbox` üzerinde doğrular. Yalnız test veritabanı kullanın.
