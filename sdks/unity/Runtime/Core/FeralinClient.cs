using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Threading;

namespace Feralin.Unity
{
    /// <summary>
    /// UTP v1 toplayıcısına olay gönderen çekirdek. Motor bağımlılığı yoktur ve arka plan iş parçacığı açmaz: otomatik gönderim
    /// <see cref="Tick"/> ile oyun döngüsünden sürülür, böylece WebGL'de de aynı davranır. Yapılandırma hatası kurucuda fırlar;
    /// çalışma zamanındaki hiçbir metot oyuna hata fırlatmaz.
    /// </summary>
    public sealed partial class FeralinClient
    {
        /// <summary>Olaylardaki <c>sdk.name</c> değeri.</summary>
        public const string SdkName = "feralin-unity";
        /// <summary>Olaylardaki <c>sdk.version</c> değeri.</summary>
        public const string SdkVersion = "0.2.0";
        /// <summary>Olaylardaki <c>platform</c> değeri.</summary>
        public const string Platform = "unity";

        private const int MaxBatchEvents = 500;
        // Toplayıcı gövdeyi 1 MiB ile sınırlar; zarf için pay bırakılır.
        private const int MaxBodyBytes = 900 * 1024;
        // Tek olay üst sınırı, Android ve Flutter SDK'larıyla aynı (karakter).
        private const int MaxEventChars = 256 * 1024;
        private static readonly TimeSpan MinBackoff = TimeSpan.FromSeconds(1);
        private static readonly TimeSpan MaxBackoff = TimeSpan.FromSeconds(30);
        private static readonly TimeSpan MaxRetryAfter = TimeSpan.FromMinutes(5);

        private sealed class Queued
        {
            public Queued(string id, string json, int bytes)
            {
                Id = id;
                Json = json;
                Bytes = bytes;
            }

            public string Id { get; }
            public string Json { get; }
            public int Bytes { get; }
        }

        private readonly string _projectKey;
        private readonly string _endpoint;
        private readonly IFeralinTransport _transport;
        private readonly int _batchSize;
        private readonly int _queueLimit;
        private readonly TimeSpan _timeout;
        private readonly TimeSpan _flushInterval;
        private readonly EventContext _defaultContext;
        private readonly IAnonymousIdStore _anonymousIdStore;
        private readonly Action<FeralinLogLevel, string> _log;
        private readonly Func<DateTimeOffset> _now;
        private readonly Func<double> _random;
        private readonly IEventStore _store;
        private readonly string _queueProtection;
        private readonly TimeSpan _sessionTimeout;
        private readonly string _attributionApi;
        private readonly string _projectId;
        private readonly Func<TrackingStatus> _trackingStatus;
        private readonly ErrorOptions _errors;

        // _gate aşağıdaki tüm alanları korur. Geri çağrılar ve taşıyıcı çağrıları kilit dışında yapılır.
        private readonly object _gate = new object();
        private readonly List<Queued> _queue = new List<Queued>();
        // Sonucu bilinmeyen batch aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda kaybolduysa
        // araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
        private List<Queued> _pinned;
        private Consent _consent;
        // Kurulum eşleştirme kodu: yalnız ilk olaya eklenir; olay kuyruğa girmezse geri konur.
        private string _pendingInstallCode;
        private const string InstallCodeProperty = "fr_install_code";
        private static readonly System.Text.RegularExpressions.Regex InstallCodePattern = new System.Text.RegularExpressions.Regex("^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);
        private string _userId;
        private string _anonymousId;
        private string _sessionId;
        private bool _closed;
        private long _dropped;
        private int _failures;
        private DateTimeOffset _notBefore;
        private DateTimeOffset _serverNotBefore;
        private DateTimeOffset _nextTick;
        // İzin kararı verildi mi: karar yokken kalıcı kuyruk yüklenmez ve silinmez, olay üretilmez.
        private bool _consentDecided;
        private bool _storeLoaded;
        private DateTimeOffset? _lastBackground;

        // Aynı anda tek gönderim turu; tur sürerken gelen Flush bir sonraki tura bağlanır.
        private bool _draining;
        private bool _drainAgain;
        private bool _forceNext;
        private List<Action<FlushResult>> _waiters = new List<Action<FlushResult>>();

        /// <summary>İstemciyi oluşturur.</summary>
        /// <exception cref="ArgumentException">Anahtar, adres veya taşıyıcı geçersizse.</exception>
        public FeralinClient(FeralinOptions options)
        {
            if (options == null)
            {
                throw new ArgumentNullException(nameof(options));
            }
            var key = (options.ProjectKey ?? "").Trim();
            if (key.StartsWith("sk_", StringComparison.Ordinal))
            {
                throw new ArgumentException("feralin: gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin", nameof(options));
            }
            if (!key.StartsWith("pk_", StringComparison.Ordinal) || key.Length < 8)
            {
                throw new ArgumentException("feralin: ProjectKey pk_ ile başlamalı", nameof(options));
            }
            if (!Uri.TryCreate((options.CollectUrl ?? "").Trim(), UriKind.Absolute, out var collect)
                || (collect.Scheme != "http" && collect.Scheme != "https")
                || string.IsNullOrEmpty(collect.Host))
            {
                throw new ArgumentException("feralin: CollectUrl http veya https şemalı mutlak adres olmalı", nameof(options));
            }
            if (options.Transport == null)
            {
                throw new ArgumentException("feralin: Transport zorunlu", nameof(options));
            }

            _projectKey = key;
            _endpoint = collect.GetLeftPart(UriPartial.Path).TrimEnd('/') + "/v1/batch";
            _transport = options.Transport;
            _batchSize = Math.Max(1, Math.Min(options.BatchSize, MaxBatchEvents));
            _queueLimit = Math.Max(1, options.QueueLimit);
            _timeout = options.Timeout > TimeSpan.Zero ? options.Timeout : TimeSpan.FromSeconds(10);
            _flushInterval = options.FlushInterval;
            _defaultContext = options.Context;
            _anonymousIdStore = options.AnonymousIdStore;
            _log = options.Log;
            _now = options.Clock ?? (() => DateTimeOffset.UtcNow);
            var shared = new Random();
            _random = options.Random ?? (() =>
            {
                lock (shared)
                {
                    return shared.NextDouble();
                }
            });
            _store = options.Store;
            _queueProtection = options.QueueProtection;
            _sessionTimeout = options.SessionTimeout;
            _attributionApi = NormalizeApiRoot(options.AttributionApiUrl);
            _projectId = string.IsNullOrWhiteSpace(options.ProjectId) ? null : options.ProjectId.Trim();
            _trackingStatus = options.TrackingStatusProvider;
            _errors = options.Errors ?? new ErrorOptions();
            _consent = options.Consent ?? Consent.None;
            var installCode = options.InstallCode?.Trim();
            _pendingInstallCode = !string.IsNullOrEmpty(installCode) && InstallCodePattern.IsMatch(installCode) ? installCode : null;
            _consentDecided = options.Consent != null;
            _nextTick = _now() + _flushInterval;
            if (_sessionTimeout > TimeSpan.Zero)
            {
                _sessionId = Ulid.New(_now());
            }
            if (_consentDecided)
            {
                lock (_gate)
                {
                    ApplyStoreConsentLocked(_consent.Analytics);
                }
            }
            if (_consent.Analytics)
            {
                SyncStoredAnonymousId(true, false);
            }
        }

        private static string NormalizeApiRoot(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || !Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri) || (uri.Scheme != "http" && uri.Scheme != "https") || string.IsNullOrEmpty(uri.Host))
            {
                return null;
            }
            return uri.GetLeftPart(UriPartial.Path).TrimEnd('/');
        }

        /// <summary>
        /// İzni günceller. <c>analytics=false</c>: bekleyen olaylar ve anonim kimlik silinir, yeni olay üretilmez; izin yeniden
        /// verilince yeni kimlik üretilir.
        /// </summary>
        public void SetConsent(Consent consent)
        {
            if (consent == null)
            {
                Warn("consent boş olamaz, izin değişmedi");
                return;
            }
            lock (_gate)
            {
                _consent = consent;
                _consentDecided = true;
                ApplyStoreConsentLocked(consent.Analytics);
                if (!consent.Analytics)
                {
                    ClearQueueLocked();
                    _anonymousId = null;
                }
            }
            SyncStoredAnonymousId(consent.Analytics, false);
            OnConsentApplied();
        }

        // Karar analitiğe izinse kalıcı kuyruk belleğe alınır; ret ise diskteki olaylar ve kimlik işaretleri silinir.
        private void ApplyStoreConsentLocked(bool analytics)
        {
            if (_store == null)
            {
                return;
            }
            if (analytics)
            {
                LoadPersistedLocked();
                return;
            }
            StoreCall(() => _store.Clear());
            StoreCall(() => _store.RemoveMarker(MarkerInstallId));
            StoreCall(() => _store.RemoveMarker(MarkerDeferredDeepLink));
            _storeLoaded = false;
        }

        private void LoadPersistedLocked()
        {
            if (_store == null || _storeLoaded)
            {
                return;
            }
            _storeLoaded = true;
            IReadOnlyList<StoredEvent> rows = null;
            StoreCall(() => rows = _store.Load());
            if (rows == null || rows.Count == 0)
            {
                return;
            }
            var known = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in _queue)
            {
                known.Add(item.Id);
            }
            if (_pinned != null)
            {
                foreach (var item in _pinned)
                {
                    known.Add(item.Id);
                }
            }
            var restored = new List<Queued>(rows.Count);
            var invalid = new List<string>();
            foreach (var row in rows)
            {
                if (row.Payload == null || row.Payload.Length > MaxEventChars)
                {
                    invalid.Add(row.Id);
                    continue;
                }
                if (known.Add(row.Id))
                {
                    restored.Add(new Queued(row.Id, row.Payload, Encoding.UTF8.GetByteCount(row.Payload)));
                }
            }
            _queue.InsertRange(0, restored);
            var over = QueuedLocked() - _queueLimit;
            if (over > 0)
            {
                var drop = Math.Min(over, _queue.Count);
                var ids = new List<string>(drop);
                for (var i = 0; i < drop; i++)
                {
                    ids.Add(_queue[i].Id);
                }
                _queue.RemoveRange(0, drop);
                _dropped += drop;
                invalid.AddRange(ids);
            }
            if (invalid.Count > 0)
            {
                StoreCall(() => _store.Remove(invalid));
            }
        }

        // Depo hatası oyuna yansımaz; kuyruk bellekte çalışmaya devam eder.
        private void StoreCall(Action action)
        {
            try
            {
                action();
            }
            catch (Exception ex)
            {
                Warn("kalıcı kuyruk işlemi başarısız: " + ex.GetType().Name);
            }
        }

        /// <summary>Tüm izinleri geri alır ve kuyruğu siler.</summary>
        public void OptOut() => SetConsent(Consent.None);

        /// <summary>Varsayılan <c>user_id</c>; boş değer varsayılanı kaldırır. E-posta veya telefon vermeyin.</summary>
        public void Identify(string userId)
        {
            if (!EventRules.ValidIdentifier(userId))
            {
                Warn("geçersiz user_id yok sayıldı");
                return;
            }
            lock (_gate)
            {
                _userId = string.IsNullOrEmpty(userId) ? null : userId;
            }
        }

        /// <summary>Varsayılan <c>anonymous_id</c>; boş değer kaldırır.</summary>
        public void SetAnonymousId(string anonymousId)
        {
            if (!EventRules.ValidIdentifier(anonymousId))
            {
                Warn("geçersiz anonymous_id yok sayıldı");
                return;
            }
            lock (_gate)
            {
                _anonymousId = string.IsNullOrEmpty(anonymousId) ? null : anonymousId;
            }
        }

        /// <summary>Varsayılan <c>session_id</c>; boş değer kaldırır.</summary>
        public void SetSessionId(string sessionId)
        {
            if (!EventRules.ValidIdentifier(sessionId))
            {
                Warn("geçersiz session_id yok sayıldı");
                return;
            }
            lock (_gate)
            {
                _sessionId = string.IsNullOrEmpty(sessionId) ? null : sessionId;
            }
        }

        /// <summary>
        /// Çıkış: varsayılan kimlikler ve kuyruk silinir. Depo varsa saklı <c>anonymous_id</c> da silinir ve analitik izni
        /// sürüyorsa yenisi üretilir; ortak cihazda iki hesap aynı kimlikle bağlanmaz.
        /// </summary>
        public void Reset()
        {
            bool analytics;
            lock (_gate)
            {
                _userId = null;
                _anonymousId = null;
                // Çıkışta oturum da yenilenir: sonraki hesap önceki oturumla bağlanmaz.
                _sessionId = _sessionTimeout > TimeSpan.Zero ? Ulid.New(_now()) : null;
                _lastBackground = null;
                ClearQueueLocked();
                if (_store != null)
                {
                    StoreCall(() => _store.RemoveMarker(MarkerInstallId));
                }
                analytics = _consent.Analytics;
            }
            SyncStoredAnonymousId(analytics, true);
        }

        // Depo çağrıları kilit dışındadır; PlayerPrefs ana iş parçacığı dışında fırlatır, oyuna yansımaz.
        private void SyncStoredAnonymousId(bool analytics, bool rotate)
        {
            if (_anonymousIdStore == null)
            {
                return;
            }
            string id = null;
            try
            {
                if (!analytics || rotate)
                {
                    _anonymousIdStore.Clear();
                }
                if (analytics)
                {
                    id = _anonymousIdStore.Load();
                    if (string.IsNullOrEmpty(id) || !EventRules.ValidIdentifier(id))
                    {
                        id = NewId();
                        _anonymousIdStore.Save(id);
                    }
                }
            }
            catch (Exception ex)
            {
                Warn("anonim kimlik deposuna erişilemedi: " + ex.GetType().Name);
                // Silinemeyen eski kimlik yeniden kullanılmaz; yeni kimlik yalnız bellekte kalır.
                if (id == null && analytics && rotate)
                {
                    id = NewId();
                }
            }
            lock (_gate)
            {
                _anonymousId = id;
            }
        }

        /// <summary>Yeni ULID üretir (anonim kimlik veya oturum kimliği için).</summary>
        public string NewId() => Ulid.New(_now());

        /// <summary>
        /// Olayı doğrular ve kuyruğa ekler; ağ çağrısı yapmaz. İzin yoksa veya girdi geçersizse <c>null</c> döner, fırlatmaz.
        /// <c>fr_click</c> yalnız reklam izniyle gönderilir; <c>verified</c> hiçbir zaman gönderilmez.
        /// </summary>
        public TrackedEvent Track(string eventName, IEnumerable<KeyValuePair<string, object>> properties = null, TrackOptions options = null)
        {
            try
            {
                return BuildAndEnqueue(eventName, properties, options, null);
            }
            catch (Exception ex)
            {
                // JSON'a dönüştürülemeyen değer (döngü, NaN) dahil hiçbir girdi oyunu düşürmez.
                Warn("olay üretilemedi: " + ex.GetType().Name);
                return null;
            }
        }

        /// <summary>Olay kuyruğa girmediyse eşleştirme kodu bir sonraki olaya kalır.</summary>
        private void RestoreInstallCode(string installCode)
        {
            if (installCode == null)
            {
                return;
            }
            lock (_gate)
            {
                if (_pendingInstallCode == null)
                {
                    _pendingInstallCode = installCode;
                }
            }
        }

        private TrackedEvent BuildAndEnqueue(string eventName, IEnumerable<KeyValuePair<string, object>> properties, TrackOptions options, string pageUrl)
        {
            Consent consent;
            string userId, anonymousId, sessionId;
            lock (_gate)
            {
                if (_closed)
                {
                    return null;
                }
                consent = _consent;
                userId = options?.UserId ?? _userId;
                anonymousId = options?.AnonymousId ?? _anonymousId;
                sessionId = options?.SessionId ?? _sessionId;
            }
            if (!consent.Analytics)
            {
                WriteDebug("izin yok, olay üretilmedi");
                return null;
            }
            if (!EventRules.ValidEventName(eventName))
            {
                Warn("geçersiz olay adı");
                return null;
            }
            if (!EventRules.ValidIdentifier(userId) || !EventRules.ValidIdentifier(anonymousId) || !EventRules.ValidIdentifier(sessionId))
            {
                Warn("geçersiz kimlik alanı, olay üretilmedi");
                return null;
            }

            var props = EventRules.SanitizeProperties(properties, out var removed);
            if (removed > 0)
            {
                Warn("geçersiz veya sunucuya ait " + removed.ToString(CultureInfo.InvariantCulture) + " özellik çıkarıldı");
            }
            var advertising = EffectiveAdvertising(consent);
            if (!advertising)
            {
                props.Remove(EventRules.ClickProperty);
            }
            string installCode;
            lock (_gate)
            {
                installCode = _pendingInstallCode;
                _pendingInstallCode = null;
            }
            if (installCode != null)
            {
                props[InstallCodeProperty] = installCode;
            }

            var now = _now();
            var eventId = Ulid.New(now);
            var wire = new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["event_id"] = eventId,
                ["event_name"] = eventName,
                ["occurred_at"] = MiniJson.FormatTime(options?.OccurredAt ?? now),
                ["platform"] = Platform,
                ["schema_version"] = 1,
                ["sdk"] = new Dictionary<string, object> { ["name"] = SdkName, ["version"] = SdkVersion },
                ["consent"] = new Dictionary<string, object>
                {
                    ["analytics"] = consent.Analytics,
                    ["advertising"] = advertising,
                    ["personalization"] = consent.Personalization,
                    ["session_replay"] = consent.SessionReplay,
                },
            };
            if (!string.IsNullOrEmpty(anonymousId))
            {
                wire["anonymous_id"] = anonymousId;
            }
            if (!string.IsNullOrEmpty(userId))
            {
                wire["user_id"] = userId;
            }
            if (!string.IsNullOrEmpty(sessionId))
            {
                wire["session_id"] = sessionId;
            }
            if (props.Count > 0)
            {
                wire["properties"] = props;
            }
            var context = EventRules.ContextToWire(options?.Context ?? _defaultContext);
            // page_url şemada bağlamın (context) içindedir; temizlenmiş bağlantı adresi yalnız şema, host ve yoldur.
            if (!string.IsNullOrEmpty(pageUrl))
            {
                context = context ?? new Dictionary<string, object>(StringComparer.Ordinal);
                context["page_url"] = pageUrl;
            }
            if (context != null)
            {
                wire["context"] = context;
            }

            // Serileştirme kuyruktan önce yapılır; bozuk bir olay batch'i zehirleyemez.
            var json = MiniJson.Write(wire);
            var bytes = Encoding.UTF8.GetByteCount(json);
            if (json.Length > MaxEventChars || bytes > MaxBodyBytes)
            {
                Warn("olay boyut sınırını aşıyor, atıldı: " + bytes.ToString(CultureInfo.InvariantCulture) + " bayt");
                RestoreInstallCode(installCode);
                return null;
            }

            int droppedNow = 0;
            lock (_gate)
            {
                // İzin bu arada geri çekildiyse olay kuyruğa girmez.
                if (_closed || !_consent.Analytics)
                {
                    if (installCode != null && _pendingInstallCode == null)
                    {
                        _pendingInstallCode = installCode;
                    }
                    return null;
                }
                _queue.Add(new Queued(eventId, json, bytes));
                if (_store != null)
                {
                    StoreCall(() => _store.Add(new StoredEvent(eventId, json)));
                }
                var over = QueuedLocked() - _queueLimit;
                if (over > 0)
                {
                    droppedNow = Math.Min(over, _queue.Count);
                    if (_store != null)
                    {
                        var ids = new List<string>(droppedNow);
                        for (var i = 0; i < droppedNow; i++)
                        {
                            ids.Add(_queue[i].Id);
                        }
                        StoreCall(() => _store.Remove(ids));
                    }
                    _queue.RemoveRange(0, droppedNow);
                    _dropped += droppedNow;
                }
            }
            if (droppedNow > 0)
            {
                Warn("kuyruk sınırı aşıldı, en eski " + droppedNow.ToString(CultureInfo.InvariantCulture) + " olay atıldı");
            }
            return new TrackedEvent(eventId, eventName, props);
        }

        /// <summary>
        /// Oyun döngüsünden çağrılır (<c>FeralinBehaviour.Update</c> bunu yapar). Aralık dolduğunda veya kuyruk batch boyutuna
        /// ulaştığında, geri çekilme süresine uyarak gönderir. Kuyruk boşsa maliyeti yalnız bir kilit ve karşılaştırmadır.
        /// </summary>
        public void Tick()
        {
            lock (_gate)
            {
                if (_closed || _draining || _flushInterval <= TimeSpan.Zero || QueuedLocked() == 0)
                {
                    return;
                }
                var now = _now();
                if (now < _notBefore || now < _serverNotBefore)
                {
                    return;
                }
                if (now < _nextTick && _queue.Count < _batchSize)
                {
                    return;
                }
                _nextTick = now + _flushInterval;
            }
            StartDrain(null, force: false);
        }

        /// <summary>
        /// Kuyruğu gönderir; fırlatmaz. Sonuç <paramref name="onComplete"/> ile bildirilir. 202 → silinir; 401/403 → kuyruk atılır;
        /// diğer 4xx (429 hariç) → batch atılır; 429, 5xx ve ağ hatası → aynı içerik ve aynı anahtarla sonra denenir.
        /// Üstel geri çekilmeyi beklemez (açık çağrı niyet sayılır), ama sunucunun Retry-After süresi dolmadan istek yapmaz.
        /// </summary>
        public void Flush(Action<FlushResult> onComplete = null)
        {
            bool closed;
            int retained;
            lock (_gate)
            {
                closed = _closed;
                retained = QueuedLocked();
            }
            if (closed)
            {
                SafeInvoke(onComplete, new FlushResult { Retained = retained });
                return;
            }
            StartDrain(onComplete, force: false);
        }

        /// <summary>
        /// İstemciyi kapatır ve kalanı Retry-After beklemeden son kez göndermeyi dener. Sonraki <see cref="Track"/> çağrıları
        /// olay üretmez. Birden çok çağrı güvenlidir.
        /// </summary>
        public void Close(Action<FlushResult> onComplete = null)
        {
            bool alreadyClosed;
            int retained;
            lock (_gate)
            {
                alreadyClosed = _closed;
                retained = QueuedLocked();
                _closed = true;
            }
            if (alreadyClosed)
            {
                SafeInvoke(onComplete, new FlushResult { Retained = retained });
                return;
            }
            StartDrain(onComplete, force: true);
        }

        /// <summary>Anlık durum (tanı amaçlı); anahtar döndürülmez.</summary>
        public FeralinStatus GetStatus()
        {
            lock (_gate)
            {
                var until = _notBefore > _serverNotBefore ? _notBefore : _serverNotBefore;
                var backoff = until - _now();
                return new FeralinStatus(QueuedLocked(), _dropped, _consent, _closed, backoff > TimeSpan.Zero ? backoff : TimeSpan.Zero, _endpoint, _store != null, _queueProtection, _errorsSuppressed);
            }
        }

        private void StartDrain(Action<FlushResult> onComplete, bool force)
        {
            List<Action<FlushResult>> waiters;
            lock (_gate)
            {
                if (onComplete != null)
                {
                    _waiters.Add(onComplete);
                }
                if (_draining)
                {
                    _drainAgain = true;
                    _forceNext |= force;
                    return;
                }
                _draining = true;
                force |= _forceNext;
                _forceNext = false;
                waiters = _waiters;
                _waiters = new List<Action<FlushResult>>();
            }
            RunDrain(new Drain(waiters, force, (_queueLimit / _batchSize) + 2));
        }

        private sealed class Drain
        {
            public Drain(List<Action<FlushResult>> waiters, bool force, int rounds)
            {
                Waiters = waiters;
                Force = force;
                Rounds = rounds;
            }

            public List<Action<FlushResult>> Waiters { get; }
            public bool Force { get; }
            public int Rounds { get; set; }
            public int Sent { get; set; }
            public int Accepted { get; set; }
            public int Rejected { get; set; }
            public int Status { get; set; }
            public string BatchId { get; set; }
        }

        // Taşıyıcı eşzamanlı tamamlanırsa yığın büyümesin diye özyineleme yerine döngü: geri çağrı hâlâ Send içindeyse döngü devam eder.
        private void RunDrain(Drain drain)
        {
            while (true)
            {
                var batch = NextBatch(drain);
                if (batch == null)
                {
                    FinishDrain(drain);
                    return;
                }
                // 0: Send sürüyor; 1: Send döndü, yanıt bekleniyor; 2: yanıt Send içinde geldi, devam; 3: yanıt Send içinde geldi, bitti.
                var state = 0;
                var answered = 0;
                Dispatch(batch, response =>
                {
                    // Hatalı taşıyıcının ikinci çağrısı batch'i iki kez işleyemez.
                    if (Interlocked.Exchange(ref answered, 1) != 0)
                    {
                        return;
                    }
                    var more = Absorb(drain, batch, response);
                    if (Interlocked.CompareExchange(ref state, more ? 2 : 3, 0) == 0)
                    {
                        return;
                    }
                    if (more)
                    {
                        RunDrain(drain);
                    }
                    else
                    {
                        FinishDrain(drain);
                    }
                });
                var seen = Interlocked.CompareExchange(ref state, 1, 0);
                if (seen == 0)
                {
                    return;
                }
                if (seen == 3)
                {
                    FinishDrain(drain);
                    return;
                }
            }
        }

        private List<Queued> NextBatch(Drain drain)
        {
            lock (_gate)
            {
                if (!drain.Force && _now() < _serverNotBefore)
                {
                    return null;
                }
                if (drain.Rounds <= 0)
                {
                    return null;
                }
                drain.Rounds--;
                if (_pinned != null)
                {
                    return _pinned;
                }
                if (_queue.Count == 0)
                {
                    return null;
                }
                var count = 0;
                var bytes = 0;
                foreach (var item in _queue)
                {
                    if (count >= _batchSize || (count > 0 && bytes + item.Bytes > MaxBodyBytes))
                    {
                        break;
                    }
                    count++;
                    bytes += item.Bytes + 1;
                }
                _pinned = _queue.GetRange(0, count);
                _queue.RemoveRange(0, count);
                return _pinned;
            }
        }

        private void Dispatch(List<Queued> batch, Action<TransportResponse> onResponse)
        {
            var body = new StringBuilder(256);
            body.Append("{\"sent_at\":\"").Append(MiniJson.FormatTime(_now())).Append("\",\"events\":[");
            var ids = new List<string>(batch.Count);
            for (var i = 0; i < batch.Count; i++)
            {
                if (i > 0)
                {
                    body.Append(',');
                }
                body.Append(batch[i].Json);
                ids.Add(batch[i].Id);
            }
            body.Append("]}");
            var headers = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json, application/problem+json",
                ["X-Feralin-Project-Key"] = _projectKey,
                ["Idempotency-Key"] = Idempotency.KeyFor(ids),
                ["User-Agent"] = SdkName + "/" + SdkVersion,
            };
            try
            {
                _transport.Send(new TransportRequest(_endpoint, Encoding.UTF8.GetBytes(body.ToString()), headers, _timeout), onResponse);
            }
            catch (Exception ex)
            {
                // Taşıyıcı hatası oyuna geçmez; sonuç bilinmediğinden batch aynı anahtarla denenir.
                WriteDebug("taşıyıcı hatası: " + ex.GetType().Name);
                onResponse(TransportResponse.NetworkError);
            }
        }

        /// <summary>Yanıtı işler; aynı turda başka batch gönderilecekse <c>true</c> döner.</summary>
        private bool Absorb(Drain drain, List<Queued> batch, TransportResponse response)
        {
            var size = batch.Count;
            var status = response?.Status ?? 0;
            drain.Sent += size;
            drain.Status = status;
            if (status == 202)
            {
                ParseAck(response.Body, size, out var accepted, out var rejected, out var batchId);
                lock (_gate)
                {
                    ReleaseLocked(batch);
                    _failures = 0;
                    _notBefore = default(DateTimeOffset);
                    _serverNotBefore = default(DateTimeOffset);
                }
                drain.Accepted += accepted;
                drain.Rejected += rejected;
                drain.BatchId = batchId ?? drain.BatchId;
                WriteDebug("batch kabul edildi: accepted=" + accepted.ToString(CultureInfo.InvariantCulture) + " rejected=" + rejected.ToString(CultureInfo.InvariantCulture));
                return true;
            }
            if (status == 401 || status == 403)
            {
                // Anahtar geçersizse sıradaki olaylar da aynı yanıtı alır; kuyruk atılır, oyun etkilenmez.
                int discarded;
                lock (_gate)
                {
                    ReleaseLocked(batch);
                    discarded = _queue.Count;
                    _queue.Clear();
                    if (_store != null)
                    {
                        StoreCall(() => _store.Clear());
                    }
                }
                drain.Rejected += size + discarded;
                Warn("anahtar reddedildi: HTTP " + status.ToString(CultureInfo.InvariantCulture) + ", " + (size + discarded).ToString(CultureInfo.InvariantCulture) + " olay atıldı");
                return false;
            }
            if (status >= 400 && status < 500 && status != 429)
            {
                lock (_gate)
                {
                    ReleaseLocked(batch);
                }
                drain.Rejected += size;
                Warn("batch kalıcı olarak reddedildi: HTTP " + status.ToString(CultureInfo.InvariantCulture) + ", " + size.ToString(CultureInfo.InvariantCulture) + " olay atıldı, " + ProblemTitle(response.Body));
                return true;
            }
            NoteFailure(ReadRetryAfter(response?.RetryAfter));
            WriteDebug("geçici hata: HTTP " + status.ToString(CultureInfo.InvariantCulture) + ", " + size.ToString(CultureInfo.InvariantCulture) + " olay kuyrukta");
            return false;
        }

        /// <summary>İstek sürerken izin geri çekildiyse kuyruk çoktan boşaltılmıştır; yeni batch'e dokunulmaz.</summary>
        private void ReleaseLocked(List<Queued> batch)
        {
            if (ReferenceEquals(_pinned, batch))
            {
                _pinned = null;
            }
            if (_store != null)
            {
                var ids = new List<string>(batch.Count);
                foreach (var item in batch)
                {
                    ids.Add(item.Id);
                }
                StoreCall(() => _store.Remove(ids));
            }
        }

        private void FinishDrain(Drain drain)
        {
            bool again;
            int retained;
            lock (_gate)
            {
                again = _drainAgain;
                _drainAgain = false;
                retained = QueuedLocked();
                _draining = false;
            }
            var result = new FlushResult
            {
                Sent = drain.Sent,
                Accepted = drain.Accepted,
                Rejected = drain.Rejected,
                Status = drain.Status,
                Retained = retained,
                BatchId = drain.BatchId,
            };
            foreach (var waiter in drain.Waiters)
            {
                SafeInvoke(waiter, result);
            }
            if (again)
            {
                StartDrain(null, force: false);
            }
        }

        private void SafeInvoke(Action<FlushResult> callback, FlushResult result)
        {
            if (callback == null)
            {
                return;
            }
            try
            {
                callback(result);
            }
            catch (Exception ex)
            {
                // Oyunun geri çağrısındaki hata gönderim akışını kesmez.
                Warn("geri çağrı hatası: " + ex.GetType().Name);
            }
        }

        private TimeSpan? ReadRetryAfter(string header)
        {
            if (string.IsNullOrWhiteSpace(header))
            {
                return null;
            }
            if (int.TryParse(header.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds))
            {
                return TimeSpan.FromSeconds(seconds);
            }
            if (DateTimeOffset.TryParse(header, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date))
            {
                return date - _now();
            }
            return null;
        }

        private void NoteFailure(TimeSpan? retryAfter)
        {
            lock (_gate)
            {
                _failures++;
                var ceiling = Math.Min(MaxBackoff.TotalMilliseconds, MinBackoff.TotalMilliseconds * Math.Pow(2, Math.Min(_failures - 1, 10)));
                // Yarım jitter: aynı anda yeniden başlayan oyunlar toplayıcıya birlikte yüklenmez.
                _notBefore = _now() + TimeSpan.FromMilliseconds(Math.Round(ceiling * (0.5 + (_random() * 0.5))));
                if (retryAfter.HasValue && retryAfter.Value > TimeSpan.Zero)
                {
                    _serverNotBefore = _now() + (retryAfter.Value < MaxRetryAfter ? retryAfter.Value : MaxRetryAfter);
                }
            }
        }

        private static void ParseAck(string text, int size, out int accepted, out int rejected, out string batchId)
        {
            accepted = size;
            rejected = 0;
            batchId = null;
            try
            {
                if (MiniJson.Parse(text) is Dictionary<string, object> root)
                {
                    if (root.TryGetValue("accepted", out var a) && a is double acceptedValue)
                    {
                        accepted = (int)acceptedValue;
                    }
                    if (root.TryGetValue("rejected", out var r) && r is double rejectedValue)
                    {
                        rejected = (int)rejectedValue;
                    }
                    if (root.TryGetValue("batch_id", out var b) && b is string batch)
                    {
                        batchId = batch;
                    }
                }
            }
            catch (FormatException)
            {
                // Kabul edildi ama gövde okunamadı: olaylar gönderilmiş sayılır.
            }
        }

        /// <summary>Ham gövde loga yazılmaz; yalnız RFC 7807 başlığı.</summary>
        private static string ProblemTitle(string text)
        {
            try
            {
                if (MiniJson.Parse(text) is Dictionary<string, object> root && root.TryGetValue("title", out var title) && title is string value)
                {
                    return value.Length > 120 ? value.Substring(0, 120) : value;
                }
            }
            catch (FormatException)
            {
                // Gövde JSON değilse başlık yoktur.
            }
            return "problem+json yok";
        }

        private int QueuedLocked() => _queue.Count + (_pinned?.Count ?? 0);

        private void ClearQueueLocked()
        {
            _queue.Clear();
            _pinned = null;
            if (_store != null)
            {
                StoreCall(() => _store.Clear());
            }
            _failures = 0;
            _notBefore = default(DateTimeOffset);
            _serverNotBefore = default(DateTimeOffset);
        }

        private void WriteDebug(string message) => Write(FeralinLogLevel.Debug, message);

        internal void Warn(string message) => Write(FeralinLogLevel.Warning, message);

        private void Write(FeralinLogLevel level, string message)
        {
            try
            {
                _log?.Invoke(level, message);
            }
            catch (Exception)
            {
                // Oyunun log hatası SDK akışını kesmez.
            }
        }
    }
}
