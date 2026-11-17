namespace Feralin;

/// <summary>UTP v1 izin nesnesi. Karar müşteri uygulamasından geçirilir (consent passthrough).</summary>
/// <param name="Analytics">Olay üretimi için zorunlu.</param>
/// <param name="Advertising"><c>fr_click</c> yalnız bu değer <c>true</c> iken gönderilir.</param>
/// <param name="Personalization">Kişiselleştirme izni; verilmediyse gönderilmez.</param>
/// <param name="SessionReplay">Oturum kaydı izni; verilmediyse gönderilmez.</param>
public sealed record Consent(bool Analytics, bool? Advertising = null, bool? Personalization = null, bool? SessionReplay = null);

/// <summary>Olay bağlamı. Sorgu ve parça gönderilmez; <c>utm_*</c> değerleri özelliklere taşınır.</summary>
public sealed record EventContext
{
    /// <summary>Sayfa adresi; yalnız scheme, host ve path gönderilir.</summary>
    public string? PageUrl { get; init; }
    /// <summary>Sayfa başlığı (en çok 512 karakter).</summary>
    public string? PageTitle { get; init; }
    /// <summary>Yönlendiren adres; yalnız origin gönderilir.</summary>
    public string? Referrer { get; init; }
    /// <summary>Yerel ayar (en çok 16 karakter).</summary>
    public string? Locale { get; init; }
    /// <summary>Saat dilimi (en çok 64 karakter).</summary>
    public string? Timezone { get; init; }
    /// <summary>Uygulama sürümü (en çok 32 karakter).</summary>
    public string? AppVersion { get; init; }
    /// <summary>Uygulama derlemesi (en çok 32 karakter).</summary>
    public string? AppBuild { get; init; }
}

/// <summary>Tek olaya özgü alanlar. Sunucu birden çok son kullanıcıyı işlediği için kimlik ve izin olay başına verilebilir.</summary>
public sealed record TrackOptions
{
    /// <summary>Müşteri uygulamasının kendi kullanıcı kimliği (en çok 128 karakter). E-posta veya telefon vermeyin.</summary>
    public string? UserId { get; init; }
    /// <summary>İstemciden aktarılan anonim kimlik.</summary>
    public string? AnonymousId { get; init; }
    /// <summary>İstemci oturum kimliği.</summary>
    public string? SessionId { get; init; }
    /// <summary>Olay zamanı; verilmezse şimdi.</summary>
    public DateTimeOffset? OccurredAt { get; init; }
    /// <summary>İsteğe bağlı bağlam.</summary>
    public EventContext? Context { get; init; }
    /// <summary>O olayın son kullanıcısına ait izin; verilmezse istemcinin varsayılanı.</summary>
    public Consent? Consent { get; init; }
}

/// <summary>Kuyruğa alınan olayın özeti.</summary>
public sealed record TrackedEvent(string EventId, string EventName, IReadOnlyDictionary<string, object?> Properties);

/// <summary>Gönderim sonucu; hata fırlatılmaz, durum buradan okunur.</summary>
public sealed record FlushResult
{
    /// <summary>Bu çağrıda toplayıcıya iletilmeye çalışılan olay sayısı.</summary>
    public int Sent { get; init; }
    /// <summary>Toplayıcının kabul ettiği olay sayısı; idempotent tekrarda 0 olabilir.</summary>
    public int Accepted { get; init; }
    /// <summary>Reddedilen veya kalıcı 4xx ile atılan olay sayısı.</summary>
    public int Rejected { get; init; }
    /// <summary>Son HTTP durumu; istek yapılmadıysa veya ağ hatasıysa 0.</summary>
    public int Status { get; init; }
    /// <summary>Geçici hata sonrası kuyrukta kalan olay sayısı.</summary>
    public int Retained { get; init; }
    /// <summary>Son başarılı batch'in sunucu kimliği.</summary>
    public string? BatchId { get; init; }
}

/// <summary>Anlık durum (tanı amaçlı); anahtar içermez.</summary>
public sealed record FeralinStatus(string Sdk, string Version, int Queued, long Dropped, Consent Consent, bool OptedOut, bool Closed, TimeSpan Backoff, string Endpoint);

/// <summary>SDK günlük düzeyi.</summary>
public enum FeralinLogLevel
{
    /// <summary>Tanı bilgisi.</summary>
    Debug,
    /// <summary>Olay kaybı veya yapılandırma sorunu.</summary>
    Warning,
}

/// <summary>SDK yapılandırması.</summary>
public sealed class FeralinOptions
{
    /// <summary>Public proje anahtarı (<c>pk_…</c>). Yalnız <c>x-feralin-project-key</c> başlığında taşınır; <c>sk_</c> reddedilir.</summary>
    public string ProjectKey { get; set; } = "";
    /// <summary>Toplayıcı kökü, ör. <c>https://collect.example.com</c>; <c>/v1/batch</c> yolunu SDK ekler.</summary>
    public string CollectUrl { get; set; } = "";
    /// <summary>Varsayılan izin. Verilmezse <c>analytics=false</c> kabul edilir (consent-first).</summary>
    public Consent? Consent { get; set; }
    /// <summary>Arka plan gönderim aralığı; sıfır kapatır (yalnız Flush ve Close).</summary>
    public TimeSpan FlushInterval { get; set; } = TimeSpan.FromSeconds(2);
    /// <summary>Tek istekteki en fazla olay (1…500).</summary>
    public int BatchSize { get; set; } = 100;
    /// <summary>Bellek içi kuyruk üst sınırı; aşılınca en eski olay atılır.</summary>
    public int QueueLimit { get; set; } = 1000;
    /// <summary>İstek zaman aşımı.</summary>
    public TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(10);
    /// <summary>Proxy, özel TLS veya test için HTTP işleyicisi. SDK bunu dispose etmez.</summary>
    public HttpMessageHandler? HttpHandler { get; set; }
    /// <summary>Günlük. Anahtar, özellik değeri ve kimlik yazılmaz; yalnız olay adı, sayaç ve durum kodu gelir.</summary>
    public Action<FeralinLogLevel, string>? Log { get; set; }
    /// <summary>Uygulama sürümü (en çok 32 karakter); yalnız <c>fr_error</c> olaylarının <c>app_version</c> alanına girer.</summary>
    public string? AppVersion { get; set; }
    /// <summary><c>fr_error</c> örnekleme oranı (0…1, varsayılan 1). Sınırlar ayrıca uygulanır: süreç başına 20, parmak izi başına 3 olay.</summary>
    public double ErrorSampleRate { get; set; } = 1.0;
    /// <summary>
    /// Kurulum eşleştirme kodu (Feralin kurulum ekranındaki kısa kod). Kırpılmış değer
    /// <c>^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$</c> desenine uyarsa ilk olaya <c>fr_install_code</c> olarak bir kez eklenir; uymazsa yok sayılır.
    /// </summary>
    public string? InstallCode { get; set; }
}
