# Feralin .NET MAUI

`Feralin.Sdk.Maui`: `Feralin.Sdk` için .NET MAUI bağdaştırıcısı. `MauiAppBuilder.UseFeralin` ile tekil `FeralinClient`, `ILogger` bağlantısı ve uygulama yaşam döngüsünde gönderim sağlar. Gönderim, izin ve idempotency kuralları `Feralin.Sdk` ile aynıdır.

> **Durum:** Yayınlanmadı. Android hedefi derlenir, ama gerçek Android cihazında veya emülatörde çalıştırılmadı. iOS, Mac Catalyst ve Windows hedefleri bu makinede iş yükü olmadığı için derlenmedi.

## Kurulum

NuGet yayını açılana kadar proje referansı veya yerel `dotnet pack` çıktısı:

```bash
dotnet pack sdks/dotnet/src/Feralin.Sdk/Feralin.Sdk.csproj -c Release -o ./paketler
dotnet pack sdks/maui/src/Feralin.Sdk.Maui/Feralin.Sdk.Maui.csproj -c Release -o ./paketler
```

Bütün platform hedeflerini üretmek için ilgili iş yükleriyle `-p:FeralinMauiAllPlatforms=true` verin. Android SDK yolu `ANDROID_HOME`, `AndroidSdkDirectory` veya varsayılan `%LOCALAPPDATA%\Android\Sdk` konumundan okunur.

## En kısa örnek

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

Aynı `FeralinClient` üzerinden kimlik, gelir, hata ve kurulum kodu:

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

Kurallar `sdks/dotnet` README'sindekiyle aynıdır: kişisel veriye benzeyen özellik ve `verified` düşer; hata gövdesinde ham yığın izi gitmez.

Geçersiz anahtar veya adres `builder.Build()` sırasında `ArgumentException` fırlatır, uygulama çalışırken düşürmez. Yalnız public `pk_` anahtarı kabul edilir.

## İzin

- `options.Consent` verilmezse `analytics=false` kabul edilir; `Track` olay üretmez, `null` döner.
- `SetConsent(new Consent(false))` veya `OptOut()` bekleyen kuyruğu da siler.
- `fr_click` yalnız `Advertising == true` iken gönderilir, aksi halde çıkarılır.
- Bağdaştırıcı cihaz kimliği, anonim kimlik veya parmak izi üretmez; `verified` gönderilmez. `UserId` için kendi kullanıcı kimliğinizi verin, e-posta veya telefon vermeyin.

## Yaşam döngüsü

| Platform | Arka plan | Ön plan | Sınanma |
|---|---|---|---|
| Android | `OnStop` | `OnStart` | Derlendi, cihazda koşmadı |
| iOS / Mac Catalyst | `DidEnterBackground` | `WillEnterForeground` | Derlenmedi |
| Windows | `OnVisibilityChanged`, `OnClosed` | `OnVisibilityChanged` | Derlenmedi |

Her iki olayda kuyruk bloklamadan gönderilir. `MauiApp` kapatılırsa `FeralinClient.Dispose` kalanı en çok 5 saniye içinde gönderir. `FeralinLifecycle` DI üzerinden alınıp elle de çağrılabilir.

## Desteklenmeyenler

- Olaylardaki `platform` değeri `dotnet`, `sdk.name` değeri `feralin-dotnet`'tir: UTP v1 şemasında `maui` yoktur ve çekirdek bu paketten değiştirilmez. MAUI ile sunucu .NET trafiği olay düzeyinde ayrılamaz.
- Kuyruk bellektedir: kalıcı değildir, uygulama öldürülürse gönderilmemiş olaylar kaybolur. Arka plana geçişte işletim sistemi süreci durdurursa istek tamamlanmayabilir.
- Play Install Referrer, AdServices/AAK, deep link, otomatik ekran izleme, otomatik kimlik, IAP doğrulaması ve yakalanmamış istisnaların otomatik bildirimi yok. Play Install Referrer için .NET Android bağlaması (`Xamarin.Google.Android.InstallReferrer`) projede referanslı değildir; eklenmesi yeni bağımlılık ve cihaz testi gerektirir.

## Test

```bash
dotnet test sdks/maui/tests/Feralin.Sdk.Maui.Tests
dotnet build sdks/maui/src/Feralin.Sdk.Maui -f net9.0-android -c Release
DATABASE_URL='postgres://...' COLLECT_ADDR=127.0.0.1:4714 node scripts/sdk-e2e/run.mjs maui
```

Uçtan uca test sade `net9.0` hedefinde çalışır: paket temiz kurulur ve gerçek toplayıcıya gönderir, ama platform yaşam döngüsü geri çağrıları tetiklenmez.
