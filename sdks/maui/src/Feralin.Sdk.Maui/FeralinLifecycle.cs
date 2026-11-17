using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.LifecycleEvents;

namespace Feralin.Maui;

/// <summary>Yaşam döngüsü olaylarının ortak işi. Kuyruk bellektedir; süreç durmadan önce gönderim burada denenir.</summary>
public sealed class FeralinLifecycle
{
    private readonly FeralinClient _client;

    /// <summary>Yaşam döngüsü yöneticisini oluşturur.</summary>
    public FeralinLifecycle(FeralinClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    /// <summary>Uygulama arka plana geçti. Bloklamaz, fırlatmaz.</summary>
    public void OnBackground() => FlushInBackground();

    /// <summary>Uygulama öne geldi: arka planda bekleyen olaylar denenir. Bloklamaz, fırlatmaz.</summary>
    public void OnForeground() => FlushInBackground();

    private void FlushInBackground()
    {
        // FlushAsync hatayı sonuç olarak döndürür; dönen görev ana iş parçacığını bekletmesin diye izlenmez.
        _ = Task.Run(() => _client.FlushAsync());
    }
}

internal static class FeralinPlatformLifecycle
{
    /// <summary>Platform geri çağrısı uygulamayı düşüremez: servis yoksa veya istemci kapatılmışsa sessizce geçilir.</summary>
    internal static void Dispatch(Action<FeralinLifecycle> action)
    {
        try
        {
            var lifecycle = IPlatformApplication.Current?.Services.GetService<FeralinLifecycle>();
            if (lifecycle is not null)
            {
                action(lifecycle);
            }
        }
        catch (ObjectDisposedException)
        {
            // Uygulama kapanırken konteyner çoktan kapatılmış olabilir; kuyruğu Dispose göndermiştir.
        }
    }

#if ANDROID
    internal static void Register(ILifecycleBuilder events) =>
        events.AddAndroid(android => android
            .OnStop(_ => Dispatch(lifecycle => lifecycle.OnBackground()))
            .OnStart(_ => Dispatch(lifecycle => lifecycle.OnForeground())));
#elif IOS || MACCATALYST
    internal static void Register(ILifecycleBuilder events) =>
        events.AddiOS(ios => ios
            .DidEnterBackground(_ => Dispatch(lifecycle => lifecycle.OnBackground()))
            .WillEnterForeground(_ => Dispatch(lifecycle => lifecycle.OnForeground())));
#elif WINDOWS
    internal static void Register(ILifecycleBuilder events) =>
        events.AddWindows(windows => windows
            .OnVisibilityChanged((_, args) => Dispatch(lifecycle =>
            {
                if (args.Visible)
                {
                    lifecycle.OnForeground();
                }
                else
                {
                    lifecycle.OnBackground();
                }
            }))
            .OnClosed((_, _) => Dispatch(lifecycle => lifecycle.OnBackground())));
#else
    // Sade net9.0 hedefinde platform olayı yoktur; kapanışta gönderimi konteynerin Dispose çağrısı yapar.
    internal static void Register(ILifecycleBuilder events)
    {
        _ = events;
    }
#endif
}
