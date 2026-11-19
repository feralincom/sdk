#if UNITY_5_3_OR_NEWER
using System;
using UnityEngine;

namespace Feralin.Unity
{
    /// <summary>
    /// Sahne bileşeni: istemciyi kurar, oyun döngüsünden <see cref="FeralinClient.Tick"/> çağırır, arka plana geçişte kuyruğu
    /// gönderir. Sahnelere yerleştirilebilir veya <see cref="Initialize"/> ile koddan oluşturulabilir. İzin kaydetmez: oyun her
    /// açılışta kendi izin kararını <see cref="SetConsent"/> ile bildirir; karar verilene kadar olay üretilmez ve diskteki kuyruk
    /// yüklenmez ya da silinmez. Kuyruk diskte şifreli tutulur (<see cref="UnityPersistence"/>), oturum 30 dakikalık arka plan
    /// süresiyle yenilenir, Android'de Play Install Referrer okunur, uygulama bağlantıları <c>fr_click</c>'e bağlanır ve (açıksa)
    /// yakalanmamış hatalar <c>fr_error</c> olarak gönderilir.
    /// </summary>
    [DisallowMultipleComponent]
    [AddComponentMenu("Feralin/Feralin")]
    public sealed class FeralinBehaviour : MonoBehaviour
    {
        private const string AnonymousIdKey = "feralin.anonymous_id";

        private sealed class PlayerPrefsAnonymousIdStore : IAnonymousIdStore
        {
            public string Load() => PlayerPrefs.GetString(AnonymousIdKey, "");

            public void Save(string anonymousId)
            {
                PlayerPrefs.SetString(AnonymousIdKey, anonymousId);
                PlayerPrefs.Save();
            }

            public void Clear()
            {
                if (PlayerPrefs.HasKey(AnonymousIdKey))
                {
                    PlayerPrefs.DeleteKey(AnonymousIdKey);
                    PlayerPrefs.Save();
                }
            }
        }

        [SerializeField, Tooltip("Public proje anahtarı (pk_…). Gizli anahtar (sk_) reddedilir.")]
        private string projectKey = "";

        [SerializeField, Tooltip("Toplayıcı kökü, ör. https://feralin.com/collect")]
        private string collectUrl = "";

        [SerializeField, Min(0f), Tooltip("Otomatik gönderim aralığı (saniye); 0 kapatır.")]
        private float flushIntervalSeconds = 2f;

        [SerializeField, Range(1, 500)]
        private int batchSize = 100;

        [SerializeField, Min(1)]
        private int queueLimit = 1000;

        [SerializeField, Min(1), Tooltip("İstek zaman aşımı (saniye).")]
        private int timeoutSeconds = 10;

        [SerializeField, Tooltip("Tanı günlüklerini Console'a yazar. Anahtar ve kimlik yazılmaz.")]
        private bool verboseLogging;

        [SerializeField, Tooltip("Çevrimdışı kuyruğu cihazda şifreli saklar (Application.persistentDataPath). WebGL'de her zaman kapalıdır.")]
        private bool persistQueue = true;

        [SerializeField, Min(0f), Tooltip("Arka planda bu kadar dakika kalınırsa yeni oturum başlar; 0 otomatik oturumu kapatır.")]
        private float sessionTimeoutMinutes = 30f;

        [SerializeField, Tooltip("İlk açılış (app_first_open), Android Play Install Referrer ve uygulama bağlantısı (deep_link_opened) atfı.")]
        private bool autoAttribution = true;

        [SerializeField, Tooltip("Facebook uygulama kimliği (Meta App ID). Android'de Meta reklamından gelen kurulumun kampanyası okunur (Meta Install Referrer).")]
        private string metaAppId = "";

        [SerializeField, Tooltip("SDK imza anahtarı kimliği (sgn_…). Değerle birlikte verilirse ilk açılış ve bağlantı açılışı olayları imzalanır (fr_sig).")]
        private string signingKeyId = "";

        [SerializeField, Tooltip("SDK imza anahtarı değeri (fsk_…). Uygulamaya gömülür; sürüm başına ayrı anahtar üretip eskisini panelden iptal edebilirsiniz.")]
        private string signingKeySecret = "";

        [SerializeField, Tooltip("Attribution API kökü (BindInstall için), ör. https://api.feralin.com. Boşsa BindInstall not_configured döner.")]
        private string apiUrl = "";

        [SerializeField, Tooltip("Proje kimliği (BindInstall yolundaki {id}).")]
        private string projectId = "";

        [SerializeField, Tooltip("Yakalanmamış istisnaları PII temizliği, örnekleme ve hız sınırıyla fr_error olarak gönderir.")]
        private bool captureErrors = true;

        [SerializeField, Tooltip("Debug.LogError ve assert kayıtlarını da fr_error olarak alır (gürültülü olabilir).")]
        private bool captureErrorLogs;

        [SerializeField, Range(0f, 1f), Tooltip("Hata olayı örnekleme oranı; 1 hepsini alır.")]
        private float errorSampleRate = 1f;

        [SerializeField, Min(0), Tooltip("Dakikada gönderilecek en çok hata olayı.")]
        private int errorsPerMinute = 10;

        private UnityErrorHooks _errorHooks;
        private bool _deepLinkSubscribed;

        /// <summary>Etkin bileşen; yoksa <c>null</c>.</summary>
        public static FeralinBehaviour Instance { get; private set; }

        /// <summary>Çekirdek istemci; yapılandırılmadıysa <c>null</c>.</summary>
        public FeralinClient Client { get; private set; }

        /// <summary>
        /// Koddan kurulum: sahneler arası kalıcı bir GameObject oluşturur. Zaten etkin bir bileşen varsa onu döndürür.
        /// Geçersiz anahtar veya adres oyunu düşürmez; hata Console'a yazılır, <see cref="Client"/> <c>null</c> kalır.
        /// </summary>
        public static FeralinBehaviour Initialize(string projectKey, string collectUrl, Consent consent = null, string attributionApiUrl = null, string projectId = null, SigningKey signingKey = null)
        {
            if (Instance != null)
            {
                return Instance;
            }
            var host = new GameObject("Feralin");
            var behaviour = host.AddComponent<FeralinBehaviour>();
            behaviour.projectKey = projectKey;
            behaviour.collectUrl = collectUrl;
            behaviour.apiUrl = attributionApiUrl ?? "";
            behaviour.projectId = projectId ?? "";
            behaviour.signingKeyId = signingKey?.Id ?? "";
            behaviour.signingKeySecret = signingKey?.Secret ?? "";
            behaviour.Configure(consent);
            return behaviour;
        }

        private void Awake()
        {
            if (Instance != null && Instance != this)
            {
                Destroy(gameObject);
                return;
            }
            Instance = this;
            DontDestroyOnLoad(gameObject);
            // Initialize yolunda alanlar AddComponent sonrasında dolar; sahne yolunda burada doludur.
            if (!string.IsNullOrEmpty(projectKey))
            {
                Configure(null);
            }
        }

        private void Configure(Consent consent)
        {
            try
            {
                string protection = null;
                var store = persistQueue ? UnityPersistence.CreateEncryptedStore(message => WriteLog(FeralinLogLevel.Warning, message), out protection) : null;
                Client = new FeralinClient(new FeralinOptions
                {
                    ProjectKey = projectKey,
                    CollectUrl = collectUrl,
                    Transport = new UnityWebRequestTransport(),
                    FlushInterval = TimeSpan.FromSeconds(flushIntervalSeconds),
                    BatchSize = batchSize,
                    QueueLimit = queueLimit,
                    Timeout = TimeSpan.FromSeconds(timeoutSeconds),
                    Context = new EventContext { AppVersion = Application.version },
                    AnonymousIdStore = new PlayerPrefsAnonymousIdStore(),
                    Log = WriteLog,
                    Store = store,
                    QueueProtection = protection,
                    SessionTimeout = TimeSpan.FromMinutes(sessionTimeoutMinutes),
                    AttributionApiUrl = apiUrl,
                    ProjectId = projectId,
                    TrackingStatusProvider = UnityAttribution.ReadTrackingStatus,
                    MetaAppId = metaAppId,
                    MetaReferrerSource = UnityAttribution.CreateMetaReferrerSource(),
                    InstallStoreSource = UnityAttribution.CreateInstallStoreSource(),
                    // İki alan da boşsa imza kapalıdır; yalnız biri doluysa kurucu yapılandırma hatası verir.
                    SigningKey = string.IsNullOrEmpty(signingKeyId) && string.IsNullOrEmpty(signingKeySecret) ? null : new SigningKey(signingKeyId, signingKeySecret),
                    EmulatorSource = UnityAttribution.CreateEmulatorSource(),
                    HuaweiReferrerSource = UnityAttribution.CreateHuaweiReferrerSource(),
                    // Kısa link çözümlemesinde yalnız cihaz sınıfı bildirilir; model ve sürüm gönderilmez.
                    ShortLinkDevice = Application.platform == RuntimePlatform.IPhonePlayer ? "ios"
                        : Application.platform == RuntimePlatform.Android ? "android" : "desktop",
                    Errors = new ErrorOptions { SampleRate = errorSampleRate, MaxPerMinute = errorsPerMinute },
                });
                if (captureErrors)
                {
                    _errorHooks = new UnityErrorHooks(Client, captureErrorLogs);
                }
                // Karar verilmediyse (consent null) hiçbir şey çağrılmaz: istemci "izin kararı yok" durumunda kalır ve diskteki
                // kuyruk dokunulmadan bekler. Oyun izni kullanıcıdan alınca SetConsent çağırır.
                if (consent != null)
                {
                    SetConsent(consent);
                }
                if (autoAttribution)
                {
                    Client.StartAttribution(UnityAttribution.CreateInstallReferrerSource());
                    SubscribeDeepLinks();
                }
            }
            catch (ArgumentException ex)
            {
                Debug.LogError(ex.Message);
            }
        }

        /// <summary>
        /// İzni günceller. Analitik izniyle rastgele bir <c>anonymous_id</c> üretilip PlayerPrefs'te tutulur (cihaz kimliği değildir);
        /// izin geri çekilince ve <see cref="FeralinClient.Reset"/> çağrısında silinir, sonraki izinde yenisi üretilir.
        /// </summary>
        public void SetConsent(Consent consent)
        {
            if (Client == null || consent == null)
            {
                return;
            }
            Client.SetConsent(consent);
        }

        private void SubscribeDeepLinks()
        {
            if (_deepLinkSubscribed)
            {
                return;
            }
            _deepLinkSubscribed = true;
            Application.deepLinkActivated += OnDeepLink;
            // Uygulama bir bağlantıyla soğuk açıldıysa olay önceden tetiklenmiştir; adres burada okunur.
            if (!string.IsNullOrEmpty(Application.absoluteURL))
            {
                OnDeepLink(Application.absoluteURL);
            }
        }

        private void OnDeepLink(string url)
        {
            Client?.HandleDeepLink(url);
        }

        /// <summary>
        /// iOS: AdServices token'ını kurulum kimliğiyle gönderir ve kimliği döndürür (ADR-0007). <c>apiUrl</c> ve <c>projectId</c> gerekir.
        /// iOS dışında <c>unsupported</c> döner. Geri çağrı ana iş parçacığında gelir; kimliği kendi sunucunuza iletin.
        /// </summary>
        public void BindInstall(Action<InstallBinding> onComplete)
        {
            if (onComplete == null)
            {
                return;
            }
            if (Client == null)
            {
                onComplete(new InstallBinding(InstallBindingStatus.NotConfigured, null));
                return;
            }
            Client.BindInstall(UnityAttribution.CreateAdServicesTokenSource(), onComplete);
        }

        private void Update()
        {
            Client?.Tick();
        }

        // Mobilde arka plana geçişte süreç her an durabilir; kuyruk bellekte olduğundan gönderim burada denenir.
        private void OnApplicationPause(bool paused)
        {
            if (paused)
            {
                Client?.NotifyBackground();
                Client?.Flush();
            }
            else
            {
                Client?.NotifyForeground();
            }
        }

        private void OnApplicationFocus(bool focused)
        {
            if (!focused)
            {
                Client?.NotifyBackground();
                Client?.Flush();
            }
            else
            {
                Client?.NotifyForeground();
            }
        }

        private void OnApplicationQuit()
        {
            Client?.Close();
        }

        private void OnDestroy()
        {
            if (Instance == this)
            {
                _errorHooks?.Dispose();
                if (_deepLinkSubscribed)
                {
                    Application.deepLinkActivated -= OnDeepLink;
                }
                Client?.Close();
                Instance = null;
            }
        }

        private void WriteLog(FeralinLogLevel level, string message)
        {
            if (level == FeralinLogLevel.Warning)
            {
                Debug.LogWarning("[Feralin] " + message);
            }
            else if (verboseLogging)
            {
                Debug.Log("[Feralin] " + message);
            }
        }
    }
}
#endif
