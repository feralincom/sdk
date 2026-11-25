<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# C# / .NET / ASP.NET: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/dotnet/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | C# |
| Paket | `Feralin.Sdk, Feralin.Sdk.AspNetCore` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | REGISTRY_VERIFIED |
| Kaynak dizin | `sdks/dotnet` |
| Registry | NuGet: **PUBLISHED** (sonraki adım: nuget.org hesabı ve 2FA; Feralin önek rezervasyonu (account@nuget.org); Push kapsamlı, Feralin.* desenli API anahtarı (NUGET_API_KEY, .NET SDK 10.0.300+) ya da trusted publishing ilkesi) |
| Derleme | `cd sdks/dotnet && dotnet build Feralin.sln --nologo` |
| Test | `cd sdks/dotnet && dotnet test Feralin.sln --nologo` |

## Kurulum

```bash
dotnet pack src/Feralin.Sdk/Feralin.Sdk.csproj -c Release -o ./paketler
dotnet pack src/Feralin.Sdk.AspNetCore/Feralin.Sdk.AspNetCore.csproj -c Release -o ./paketler
dotnet add package Feralin.Sdk.AspNetCore --version 0.1.0 --source ./paketler
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız) |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil) |
| consent | SUPPORTED (yayınsız; olay başına passthrough) |
| identity | SUPPORTED (yayınsız; identify, reset, Group, SetUserProperties, SetGlobalProperties/ClearGlobalProperties; kimlik TrackOptions ile olay başına; toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar; birim testli ve gerçek collect e2e ile sınandı) |
| attribution | N/A |
| deeplink | N/A |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; dotnet test testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS |  |
| registry | PASS | NuGet'te yayımlandı: Feralin.Sdk 0.1.0 ve Feralin.Sdk.AspNetCore 0.1.0 (19 Kasım 2026, git 632a8825, dotnet nuget push, .NET SDK 10.0.404 NuGet 7.9; nuget.org hesabı pushizo, Feralin.* önek rezervasyonu yapılmadı). Geri okuma: flat container .nupkg girdileri (depo imzası hariç) CRC32 ve boyutuyla yerel paketle aynı. |
| clean_install | PASS | dotnet pack çıktısı boş dizine ayrı NuGet önbelleğiyle kuruldu. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs dotnet: 202, outbox, izinsiz red, 401, idempotency, QA-C yerel (ASP.NET Core DI). Gelir doğrulaması F5. |
| documentation | PASS | docs/sdk/dotnet.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
