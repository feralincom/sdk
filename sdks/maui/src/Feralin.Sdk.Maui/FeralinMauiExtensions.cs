using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.LifecycleEvents;

namespace Feralin.Maui;

/// <summary>.NET MAUI kaydı: tekil <see cref="FeralinClient"/>, açılışta yapılandırma denetimi ve yaşam döngüsünde gönderim.</summary>
public static class FeralinMauiExtensions
{
    /// <summary>
    /// <see cref="FeralinClient"/> tekil olarak eklenir; <c>ILogger</c> günlüğe bağlanır, uygulama arka plana geçerken ve geri
    /// dönerken kuyruk gönderilir. Geçersiz anahtar veya adres <c>builder.Build()</c> sırasında fırlar, uygulama çalışırken değil.
    /// İzin verilmezse olay üretilmez (consent-first). Birden çok çağrıda ilk kayıt geçerlidir.
    /// </summary>
    public static MauiAppBuilder UseFeralin(this MauiAppBuilder builder, Action<FeralinOptions> configure)
    {
        ArgumentNullException.ThrowIfNull(builder);
        ArgumentNullException.ThrowIfNull(configure);
        if (builder.Services.Any(descriptor => descriptor.ServiceType == typeof(FeralinLifecycle)))
        {
            return builder;
        }
        builder.Services.TryAddSingleton(provider =>
        {
            var options = new FeralinOptions();
            configure(options);
            options.AppVersion ??= PlatformAppVersion();
            if (options.Log is null)
            {
                var logger = provider.GetService<ILoggerFactory>()?.CreateLogger("Feralin");
                if (logger is not null)
                {
                    options.Log = (level, message) => logger.Log(level == FeralinLogLevel.Warning ? LogLevel.Warning : LogLevel.Debug, "{FeralinMessage}", message);
                }
            }
            return new FeralinClient(options);
        });
        builder.Services.AddSingleton<FeralinLifecycle>();
        builder.Services.AddTransient<IMauiInitializeService, FeralinInitializer>();
        builder.ConfigureLifecycleEvents(events => FeralinPlatformLifecycle.Register(events));
        return builder;
    }

    /// <summary>
    /// <c>fr_error</c> olaylarının <c>app_version</c> alanı için platformun bildirdiği sürüm. Sade net9.0 hedefinde ve testte platform
    /// uygulaması yoktur; o zaman alan boş kalır (uygulama <see cref="FeralinOptions.AppVersion"/> ile verebilir).
    /// </summary>
    private static string? PlatformAppVersion()
    {
        try
        {
            var version = Microsoft.Maui.ApplicationModel.AppInfo.Current.VersionString;
            return string.IsNullOrEmpty(version) ? null : version;
        }
        catch (Exception)
        {
            // NotImplementedInReferenceAssemblyException: platform dışı hedef. Sürüm yalnız tanı alanıdır, kurulum durdurulmaz.
            return null;
        }
    }

    // MAUI bu servisi Build() içinde çalıştırır: yapılandırma hatası yaşam döngüsü geri çağrısına kadar ertelenmez.
    private sealed class FeralinInitializer : IMauiInitializeService
    {
        public void Initialize(IServiceProvider services) => services.GetRequiredService<FeralinLifecycle>();
    }
}
