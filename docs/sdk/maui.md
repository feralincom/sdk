<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# .NET MAUI: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/maui/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | C# |
| Paket | `Feralin.Sdk.Maui` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/maui` |
| Registry | NuGet: **BLOCKED_EXTERNAL** (gereken: nuget.org hesabı ve 2FA; Feralin önek rezervasyonu (account@nuget.org); Push kapsamlı, Feralin.* desenli API anahtarı (NUGET_API_KEY, .NET SDK 10.0.300+) ya da trusted publishing ilkesi) |
| Derleme | `cd sdks/maui && dotnet build src/Feralin.Sdk.Maui -c Release --nologo` |
| Test | `cd sdks/maui && dotnet test tests/Feralin.Sdk.Maui.Tests --nologo` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `NuGet` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
dotnet pack sdks/dotnet/src/Feralin.Sdk/Feralin.Sdk.csproj -c Release -o ./paketler
dotnet pack sdks/maui/src/Feralin.Sdk.Maui/Feralin.Sdk.Maui.csproj -c Release -o ./paketler
```

## İlk kullanım

```csharp
using Feralin;
using Feralin.Maui;

public static class MauiProgram
{
    public static MauiApp CreateMauiApp()
    {
        var builder = MauiApp.CreateBuilder();
        builder.UseMauiApp<App>().UseFeralin(options =>
        {
            options.ProjectKey = "pk_live_ORNEK";
            options.CollectUrl = "https://collect.ornek.com";
        });
        return builder.Build();
    }
}

// Sayfada veya servisde enjekte edin:
public sealed class HomeViewModel(FeralinClient feralin)
{
    public void OnConsentGiven() => feralin.SetConsent(new Consent(Analytics: true));
    public void OnOpened() => feralin.Track("screen_view", new Dictionary<string, object?> { ["screen"] = "home" });
}
```

```csharp
builder.UseFeralin(options =>
{
    options.ProjectKey = "pk_live_ORNEK";
    options.CollectUrl = "https://collect.ornek.com";
    options.InstallCode = kurulumKodu;   // Feralin kurulum ekranındaki kod; ilk olaya fr_install_code olarak bir kez eklenir
    // options.AppVersion verilmezse platformun AppInfo.VersionString değeri fr_error olaylarında kullanılır
});

feralin.Group("acme-team", new Dictionary<string, object?> { ["plan"] = "team" });          // fr_group
feralin.SetUserProperties(new Dictionary<string, object?> { ["plan"] = "pro" });            // fr_user_properties
feralin.TrackRevenue(new RevenueInput("ord_1", 4999, "TRY") { ProductId = "pro" });        // feralin_purchase (istemci beyanı)
try { Odeme(); } catch (Exception ex) { feralin.CaptureError(ex); }                        // fr_error
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | PARTIAL (net9.0 hedefinde sınandı; cihazda koşmadı, platform=dotnet) |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil; cihazda koşmadı) |
| consent | PARTIAL (net9.0 hedefinde sınandı; cihazda koşmadı) |
| identity | PARTIAL (identify, reset, Group → fr_group, SetUserProperties → fr_user_properties; dotnet test; cihazda koşmadı) |
| attribution | PARTIAL (InstallCode → fr_install_code ilk olayda; Play Install Referrer bağlaması yok, cihazda koşmadı) |
| deeplink | PLANNED |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; dotnet test testli, gerçek toplayıcı e2e yok) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; dotnet test testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PARTIAL | net9.0 ve net9.0-android derlendi (0 uyarı). iOS, Mac Catalyst, Windows derlenmedi: yalnız maui-android iş yükü kurulu, görev gereği kurulmadı. |
| test | PASS | 12 birim testi net9.0 hedefinde geçti. Platform yaşam döngüsü geri çağrıları birim testinde tetiklenmez. |
| registry | BLOCKED_EXTERNAL | nuget.org hesabı yok. |
| clean_install | PASS | dotnet pack çıktısı boş dizine ayrı NuGet önbelleğiyle kuruldu; tüketici sade net9.0. |
| event_receipt | PARTIAL | scripts/sdk-e2e/run.mjs maui: 202, outbox, izinsiz red, 401, idempotency, FeralinLifecycle ve Dispose gönderimi net9.0 üstünde gerçek toplayıcıyla geçti. İlk 3 koşudan biri kaldı: Dispose ile gönderilen son olay outboxta yoktu (makine yükü altında; Feralin.Sdk kapanış sınırı 5 sn). Yük kalkınca ve commit gecikmesi kapatılınca 5 koşunun 5i geçti; kök neden kanıtlanmadı. Android cihaz, emülatör ve gerçek yaşam döngüsü geri çağrısı KOŞMADI. platform=dotnet. |
| documentation | PASS | docs/sdk/maui.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
