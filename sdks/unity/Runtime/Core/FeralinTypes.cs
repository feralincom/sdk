using System;
using System.Collections.Generic;

namespace Feralin.Unity
{
    /// <summary>UTP v1 izin nesnesi. Karar oyundan gelir; SDK izni kendisi varsaymaz ve saklamaz.</summary>
    public sealed class Consent
    {
        /// <summary>Hiçbir izin verilmemiş durum (varsayılan).</summary>
        public static readonly Consent None = new Consent(false);

        /// <summary>İzin nesnesi oluşturur.</summary>
        public Consent(bool analytics, bool advertising = false, bool personalization = false, bool sessionReplay = false)
        {
            Analytics = analytics;
            Advertising = advertising;
            Personalization = personalization;
            SessionReplay = sessionReplay;
        }

        /// <summary>Olay üretimi için zorunlu.</summary>
        public bool Analytics { get; }
        /// <summary><c>fr_click</c> yalnız bu değer <c>true</c> iken gönderilir.</summary>
        public bool Advertising { get; }
        /// <summary>Kişiselleştirme izni.</summary>
        public bool Personalization { get; }
        /// <summary>Oturum kaydı izni; bu SDK oturum kaydı yapmaz, değer yalnız aktarılır.</summary>
        public bool SessionReplay { get; }
    }

    /// <summary>Olay bağlamı. Parmak izi üretebilecek alanlar (ekran, donanım, cihaz kimliği) bilerek yoktur.</summary>
    public sealed class EventContext
    {
        /// <summary>Yerel ayar (en çok 16 karakter).</summary>
        public string Locale { get; set; }
        /// <summary>Saat dilimi (en çok 64 karakter).</summary>
        public string Timezone { get; set; }
        /// <summary>Oyun sürümü (en çok 32 karakter).</summary>
        public string AppVersion { get; set; }
        /// <summary>Oyun derlemesi (en çok 32 karakter).</summary>
        public string AppBuild { get; set; }
    }

    /// <summary>Tek olaya özgü alanlar.</summary>
    public sealed class TrackOptions
    {
        /// <summary>Oyunun kendi oyuncu kimliği (en çok 128 karakter). E-posta veya telefon vermeyin.</summary>
        public string UserId { get; set; }
        /// <summary>Anonim kimlik; verilmezse istemcinin varsayılanı.</summary>
        public string AnonymousId { get; set; }
        /// <summary>Oturum kimliği; verilmezse istemcinin varsayılanı.</summary>
        public string SessionId { get; set; }
        /// <summary>Olay zamanı; verilmezse şimdi.</summary>
        public DateTimeOffset? OccurredAt { get; set; }
        /// <summary>Bağlam; verilmezse istemcinin varsayılanı.</summary>
        public EventContext Context { get; set; }
    }

    /// <summary>Kuyruğa alınan olayın özeti.</summary>
    public sealed class TrackedEvent
    {
        internal TrackedEvent(string eventId, string eventName, IReadOnlyDictionary<string, object> properties)
        {
            EventId = eventId;
            EventName = eventName;
            Properties = properties;
        }

        /// <summary>ULID olay kimliği.</summary>
        public string EventId { get; }
        /// <summary>Olay adı.</summary>
        public string EventName { get; }
        /// <summary>Süzülmüş özellikler (gönderilecek hâli).</summary>
        public IReadOnlyDictionary<string, object> Properties { get; }
    }

    /// <summary>Gönderim sonucu; hata fırlatılmaz, durum buradan okunur.</summary>
    public sealed class FlushResult
    {
        /// <summary>Bu çağrıda toplayıcıya iletilmeye çalışılan olay sayısı.</summary>
        public int Sent { get; internal set; }
        /// <summary>Toplayıcının kabul ettiği olay sayısı; idempotent tekrarda 0 olabilir.</summary>
        public int Accepted { get; internal set; }
        /// <summary>Toplayıcının reddettiği veya kalıcı 4xx ile atılan olay sayısı.</summary>
        public int Rejected { get; internal set; }
        /// <summary>Son HTTP durumu; istek yapılmadıysa veya ağ hatasıysa 0.</summary>
        public int Status { get; internal set; }
        /// <summary>Bu çağrı bittiğinde kuyrukta kalan olay sayısı.</summary>
        public int Retained { get; internal set; }
        /// <summary>Son başarılı batch'in sunucu kimliği.</summary>
        public string BatchId { get; internal set; }
    }

    /// <summary>Anlık durum (tanı amaçlı); anahtar içermez.</summary>
    public sealed class FeralinStatus
    {
        internal FeralinStatus(int queued, long dropped, Consent consent, bool closed, TimeSpan backoff, string endpoint, bool persistent = false, string queueProtection = null, long errorsSuppressed = 0)
        {
            Persistent = persistent;
            QueueProtection = queueProtection;
            ErrorsSuppressed = errorsSuppressed;
            Queued = queued;
            Dropped = dropped;
            Consent = consent;
            Closed = closed;
            Backoff = backoff;
            Endpoint = endpoint;
        }

        /// <summary>Paket adı.</summary>
        public string Sdk => FeralinClient.SdkName;
        /// <summary>Paket sürümü.</summary>
        public string Version => FeralinClient.SdkVersion;
        /// <summary>Kuyruktaki olay sayısı.</summary>
        public int Queued { get; }
        /// <summary>Kuyruk sınırı yüzünden atılan olay sayısı.</summary>
        public long Dropped { get; }
        /// <summary>Geçerli izin.</summary>
        public Consent Consent { get; }
        /// <summary>İstemci kapatıldı mı.</summary>
        public bool Closed { get; }
        /// <summary>Sonraki otomatik denemeye kalan süre.</summary>
        public TimeSpan Backoff { get; }
        /// <summary>Gönderim adresi.</summary>
        public string Endpoint { get; }
        /// <summary>Kuyruk diske yazılıyor mu.</summary>
        public bool Persistent { get; }
        /// <summary>Kuyruk anahtarının koruma düzeyi (<c>android_keystore</c>, <c>ios_keychain</c>, <c>windows_dpapi</c>, <c>local_file</c>); şifreli kuyruk yoksa <c>null</c>.</summary>
        public string QueueProtection { get; }
        /// <summary>Hız sınırı yüzünden gönderilmeyen hata olayı sayısı.</summary>
        public long ErrorsSuppressed { get; }
    }

    /// <summary>SDK günlük düzeyi.</summary>
    public enum FeralinLogLevel
    {
        /// <summary>Tanı bilgisi.</summary>
        Debug,
        /// <summary>Olay kaybı veya yapılandırma sorunu.</summary>
        Warning,
    }

    /// <summary>Taşıyıcıya verilen tek HTTP isteği.</summary>
    public sealed class TransportRequest
    {
        internal TransportRequest(string url, byte[] body, IReadOnlyDictionary<string, string> headers, TimeSpan timeout)
        {
            Url = url;
            Body = body;
            Headers = headers;
            Timeout = timeout;
        }

        /// <summary>POST adresi.</summary>
        public string Url { get; }
        /// <summary>UTF-8 JSON gövde.</summary>
        public byte[] Body { get; }
        /// <summary>İstek başlıkları. Proje anahtarını içerdiği için loglanmamalıdır.</summary>
        public IReadOnlyDictionary<string, string> Headers { get; }
        /// <summary>İstek zaman aşımı.</summary>
        public TimeSpan Timeout { get; }
    }

    /// <summary>Taşıyıcının ürettiği yanıt. <c>Status == 0</c> ağ hatası veya sonucu bilinmeyen istek demektir.</summary>
    public sealed class TransportResponse
    {
        /// <summary>Yanıt oluşturur.</summary>
        public TransportResponse(int status, string body = null, string retryAfter = null)
        {
            Status = status;
            Body = body ?? "";
            RetryAfter = retryAfter;
        }

        /// <summary>Ağ hatası yanıtı: olaylar kuyrukta kalır, aynı anahtarla yeniden denenir.</summary>
        public static TransportResponse NetworkError => new TransportResponse(0);

        /// <summary>HTTP durum kodu.</summary>
        public int Status { get; }
        /// <summary>Yanıt gövdesi.</summary>
        public string Body { get; }
        /// <summary>Retry-After başlığı ham değeri.</summary>
        public string RetryAfter { get; }
    }

    /// <summary>
    /// HTTP taşıyıcısı. Çekirdek ağ bilmez: oyunda <c>UnityWebRequestTransport</c>, testte sahte taşıyıcı kullanılır.
    /// Geri çağrı tam bir kez, eşzamanlı veya sonradan çağrılabilir.
    /// </summary>
    public interface IFeralinTransport
    {
        /// <summary>İsteği gönderir; sonucu <paramref name="onComplete"/> ile bildirir.</summary>
        void Send(TransportRequest request, Action<TransportResponse> onComplete);
    }

    /// <summary>
    /// Kalıcı <c>anonymous_id</c> deposu. Verilirse kimliğin yaşam döngüsünü istemci yönetir: analitik izninde okur veya üretir,
    /// izin geri çekilince ve <see cref="FeralinClient.Reset"/> çağrısında siler. Oyunda PlayerPrefs kullanılır.
    /// </summary>
    public interface IAnonymousIdStore
    {
        /// <summary>Saklı kimlik; yoksa boş.</summary>
        string Load();
        /// <summary>Kimliği saklar.</summary>
        void Save(string anonymousId);
        /// <summary>Saklı kimliği siler.</summary>
        void Clear();
    }

    /// <summary>İstemci yapılandırması.</summary>
    public sealed class FeralinOptions
    {
        /// <summary>Public proje anahtarı (<c>pk_…</c>); <c>sk_</c> reddedilir.</summary>
        public string ProjectKey { get; set; } = "";
        /// <summary>Toplayıcı kökü; <c>/v1/batch</c> yolunu SDK ekler.</summary>
        public string CollectUrl { get; set; } = "";
        /// <summary>Taşıyıcı (zorunlu).</summary>
        public IFeralinTransport Transport { get; set; }
        /// <summary>Başlangıç izni. Verilmezse hiçbir izin yok kabul edilir (consent-first).</summary>
        public Consent Consent { get; set; }
        /// <summary><see cref="FeralinClient.Tick"/> çağrılarında otomatik gönderim aralığı; sıfır kapatır.</summary>
        public TimeSpan FlushInterval { get; set; } = TimeSpan.FromSeconds(2);
        /// <summary>Tek istekteki en fazla olay (1…500).</summary>
        public int BatchSize { get; set; } = 100;
        /// <summary>Kuyruk üst sınırı (bellek ve disk); aşılınca en eski olay atılır. Diğer SDK'larla aynı kural.</summary>
        public int QueueLimit { get; set; } = 1000;
        /// <summary>İstek zaman aşımı.</summary>
        public TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(10);
        /// <summary>
        /// Kalıcı kuyruk deposu (genellikle şifreli <see cref="EncryptedEventStore"/>). Verilmezse kuyruk yalnız bellektedir ve ilk açılış
        /// atıf işaretleri tutulamaz. Kalıcı olay, kimliğiyle birlikte saklanır; yeniden gönderimde aynı <c>event_id</c> korunur.
        /// </summary>
        public IEventStore Store { get; set; }
        /// <summary>Kuyruk anahtarının koruma düzeyi (yalnız tanı amaçlı, <see cref="FeralinStatus.QueueProtection"/>).</summary>
        public string QueueProtection { get; set; }
        /// <summary>
        /// Arka planda bu süre geçerse sonraki ön plana çıkışta yeni <c>session_id</c> üretilir (Android ve Flutter ile aynı, 30 dakika).
        /// Sıfır otomatik oturumu kapatır.
        /// </summary>
        public TimeSpan SessionTimeout { get; set; } = TimeSpan.FromMinutes(30);
        /// <summary>Attribution uçlarının kökü (<c>BindInstall</c> için), ör. <c>https://api.feralin.com</c>.</summary>
        public string AttributionApiUrl { get; set; }
        /// <summary>Proje kimliği (<c>BindInstall</c> yolundaki <c>{id}</c>).</summary>
        public string ProjectId { get; set; }
        /// <summary>iOS ATT durumu; reddedilmiş ya da kısıtlıysa reklam kanıtı (fr_click, referrer, AdServices) kullanılmaz. Verilmezse kısıtlama yok.</summary>
        public Func<TrackingStatus> TrackingStatusProvider { get; set; }
        /// <summary>Hata yakalama sınırları.</summary>
        public ErrorOptions Errors { get; set; }
        /// <summary>Kalıcı anonim kimlik deposu; verilmezse kimlik yalnız <see cref="FeralinClient.SetAnonymousId"/> ile gelir.</summary>
        public IAnonymousIdStore AnonymousIdStore { get; set; }
        /// <summary>Her olaya eklenen varsayılan bağlam.</summary>
        public EventContext Context { get; set; }
        /// <summary>Günlük. Anahtar, özellik değeri ve kimlik yazılmaz; yalnız sayaç ve durum kodu gelir.</summary>
        public Action<FeralinLogLevel, string> Log { get; set; }
        /// <summary>Saat; test için değiştirilebilir.</summary>
        public Func<DateTimeOffset> Clock { get; set; }
        /// <summary>[0,1) rastgele kaynak (geri çekilme payı); test için değiştirilebilir.</summary>
        public Func<double> Random { get; set; }
        /// <summary>
        /// Kurulum eşleştirme kodu: panelin "Kurulumu doğrula" ekranında üretilen tek kullanımlık kod. İzin verildikten sonra kuyruğa giren
        /// ilk olaya <c>fr_install_code</c> olarak eklenir; sunucu kurulumu projeye bağlar. Biçimi geçersizse yok sayılır (Android SDK ile aynı kural).
        /// </summary>
        public string InstallCode { get; set; }
    }
}
