using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Feralin;

/// <summary>
/// UTP v1 toplayıcısına olay gönderen, eşzamanlı kullanıma uygun istemci. Tekil (singleton) kullanılmalıdır.
/// İlkeler Web SDK ile aynıdır: izin yoksa olay üretilmez, at-least-once gönderim, tüm event_id'lerin özetinden
/// idempotency anahtarı, anahtar yalnız <c>x-feralin-project-key</c> başlığında. Yapılandırma hatası kurucuda fırlar;
/// çalışma zamanındaki hiçbir metot uygulamaya hata fırlatmaz.
/// </summary>
public sealed class FeralinClient : IAsyncDisposable, IDisposable
{
    /// <summary>Olaylardaki <c>sdk.name</c> değeri.</summary>
    public const string SdkName = "feralin-dotnet";
    /// <summary>Olaylardaki <c>sdk.version</c> değeri.</summary>
    public const string SdkVersion = "0.1.0";

    private const int MaxBatchEvents = 500;
    // Toplayıcı gövdeyi 1 MiB ile sınırlar; zarf için pay bırakılır.
    private const int MaxBodyBytes = 900 * 1024;
    private static readonly TimeSpan MinBackoff = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan MaxBackoff = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan MaxRetryAfter = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan DefaultCloseTimeout = TimeSpan.FromSeconds(5);

    private sealed record Queued(string Id, string Json, int Bytes);

    private readonly string _projectKey;
    private readonly string _endpoint;
    private readonly HttpClient _http;
    private readonly bool _ownsHttp;
    private readonly int _batchSize;
    private readonly int _queueLimit;
    private readonly TimeSpan _timeout;
    private readonly TimeSpan _flushInterval;
    private readonly Action<FeralinLogLevel, string>? _log;
    private readonly Func<DateTimeOffset> _now;
    private readonly Func<double> _random;
    // Yalnız fr_error olaylarının app_version alanı; sınırlayıcı hata fırtınasının toplayıcıyı doldurmasını önler.
    private readonly string? _appVersion;
    private readonly ErrorLimiter _errorLimiter;
    // Kurulum eşleştirme kodu: ilk kuyruğa giren olaya eklenir ve silinir (Web, Android ve Flutter SDK ile aynı kural).
    private string? _pendingInstallCode;

    // _gate kuyruk, izin, kimlik ve geri çekilme alanlarını korur.
    private readonly object _gate = new();
    private readonly List<Queued> _queue = new();
    // Sonucu bilinmeyen batch aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda kaybolduysa
    // araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
    private List<Queued>? _pinned;
    private Consent _consent;
    private bool _optedOut;
    private string? _userId;
    // Global özellikler: `fr_` ile başlamayan her olaya eklenir; olayın kendi özelliği aynı anahtarda kazanır.
    private readonly Dictionary<string, object?> _globals = new(StringComparer.Ordinal);
    private bool _closed;
    private long _dropped;
    private int _failures;
    private DateTimeOffset _notBefore;
    private DateTimeOffset _serverNotBefore;

    // Aynı anda tek gönderici: sabit Idempotency-Key ve sıra korunur.
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private readonly CancellationTokenSource _stop = new();
    private readonly SemaphoreSlim _wake = new(0, 1);
    private readonly Task? _loop;

    /// <summary>İstemciyi oluşturur.</summary>
    /// <exception cref="ArgumentException">Anahtar veya adres geçersizse.</exception>
    public FeralinClient(FeralinOptions options) : this(options, () => DateTimeOffset.UtcNow, Random.Shared.NextDouble)
    {
    }

    internal FeralinClient(FeralinOptions options, Func<DateTimeOffset> now, Func<double> random)
    {
        ArgumentNullException.ThrowIfNull(options);
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
            || collect.Scheme is not ("http" or "https")
            || string.IsNullOrEmpty(collect.Host))
        {
            throw new ArgumentException("feralin: CollectUrl http veya https şemalı mutlak adres olmalı", nameof(options));
        }

        _projectKey = key;
        _endpoint = collect.GetLeftPart(UriPartial.Path).TrimEnd('/') + "/v1/batch";
        _batchSize = Math.Clamp(options.BatchSize, 1, MaxBatchEvents);
        _queueLimit = Math.Max(1, options.QueueLimit);
        _timeout = options.Timeout > TimeSpan.Zero ? options.Timeout : TimeSpan.FromSeconds(10);
        _flushInterval = options.FlushInterval;
        _log = options.Log;
        _now = now;
        _random = random;
        _consent = options.Consent ?? new Consent(false);
        _appVersion = options.AppVersion;
        _errorLimiter = new ErrorLimiter(options.ErrorSampleRate, random);
        var installCode = (options.InstallCode ?? "").Trim();
        _pendingInstallCode = EventRules.ValidInstallCode(installCode) ? installCode : null;
        _ownsHttp = options.HttpHandler is null;
        _http = options.HttpHandler is null ? new HttpClient() : new HttpClient(options.HttpHandler, disposeHandler: false);
        // Zaman aşımı istek başına token ile uygulanır; sonsuz bırakmak işleyiciden bağımsız davranış sağlar.
        _http.Timeout = System.Threading.Timeout.InfiniteTimeSpan;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd($"{SdkName}/{SdkVersion}");

        if (_flushInterval > TimeSpan.Zero)
        {
            _loop = Task.Run(RunLoopAsync);
        }
    }

    /// <summary>Varsayılan izni günceller. <c>analytics=false</c>: bekleyen olaylar silinir, olay bazlı izin de geçersiz olur.</summary>
    public void SetConsent(Consent consent)
    {
        ArgumentNullException.ThrowIfNull(consent);
        lock (_gate)
        {
            _consent = consent;
            _optedOut = !consent.Analytics;
            if (_optedOut)
            {
                ClearQueueLocked();
            }
        }
    }

    /// <summary><c>SetConsent(new Consent(false))</c> ile aynıdır.</summary>
    public void OptOut() => SetConsent(new Consent(false));

    /// <summary>Varsayılan <c>user_id</c>; boş değer varsayılanı kaldırır. 128 karakteri aşan değer yok sayılır.</summary>
    public void Identify(string? userId)
    {
        if (userId is { Length: > EventRules.MaxIdentifierLength })
        {
            Warn("geçersiz user_id yok sayıldı");
            return;
        }
        lock (_gate)
        {
            _userId = string.IsNullOrEmpty(userId) ? null : userId;
        }
    }

    /// <summary>Çıkış: varsayılan kimlik ve kuyruk silinir.</summary>
    public void Reset()
    {
        lock (_gate)
        {
            _userId = null;
            ClearQueueLocked();
        }
    }

    /// <summary>
    /// Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: <c>fr_group</c> olayı, <c>group_id</c> ve temizlenmiş özellikler. Grup kimliği
    /// 1-128 karakter olmalı, <c>@</c> ve kontrol karakteri içermemelidir; uymazsa olay üretilmez ve <c>null</c> döner. Kimlik
    /// (<c>UserId</c>, <c>AnonymousId</c>) <paramref name="options"/> ile olay başına verilir. Toplayıcı yalnız projenin izin listesindeki
    /// özellikleri saklar.
    /// </summary>
    public TrackedEvent? Group(string groupId, IEnumerable<KeyValuePair<string, object?>>? traits = null, TrackOptions? options = null)
    {
        if (!ProfileRules.ValidGroupId(groupId))
        {
            Warn("fr_group: geçersiz group_id, olay üretilmedi");
            return null;
        }
        var props = ProfileRules.Sanitize(traits, out var dropped);
        if (dropped > 0)
        {
            Warn($"fr_group: {dropped} özellik sözleşmeye uymadığı için düştü");
        }
        props["group_id"] = groupId;
        return Track(ProfileRules.GroupEventName, props, options);
    }

    /// <summary>
    /// Kullanıcı özelliklerini bildirir: <c>fr_user_properties</c> olayı. Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad vb.),
    /// doğrulama alanı ve sözleşme dışı değer düşer; geçerli özellik kalmazsa olay üretilmez ve <c>null</c> döner. Toplayıcı yalnız projenin
    /// izin listesindeki anahtarları saklar (liste boşsa hiçbirini).
    /// </summary>
    public TrackedEvent? SetUserProperties(IEnumerable<KeyValuePair<string, object?>> properties, TrackOptions? options = null)
    {
        var props = ProfileRules.Sanitize(properties, out var dropped);
        if (dropped > 0)
        {
            Warn($"fr_user_properties: {dropped} özellik sözleşmeye uymadığı için düştü");
        }
        if (props.Count == 0)
        {
            Warn("fr_user_properties: geçerli özellik yok, olay üretilmedi");
            return null;
        }
        return Track(ProfileRules.UserPropertiesEventName, props, options);
    }

    /// <summary>
    /// Global özellikleri birleştirir: <c>fr_</c> ile başlamayan her olaya eklenir, olayın kendi özelliği aynı anahtarda kazanır. Değer
    /// <c>null</c> anahtarı siler. Kurallar <see cref="SetUserProperties"/> ile aynıdır; toplam en çok 50 anahtar tutulur, fazlası düşer.
    /// Sunucu SDK'sında bütün kullanıcılara ortaktır (ör. servis sürümü), <see cref="Reset"/> silmez; kişiye özgü değer koymayın.
    /// </summary>
    public void SetGlobalProperties(IEnumerable<KeyValuePair<string, object?>> properties)
    {
        var clean = ProfileRules.Sanitize(properties, out var dropped, allowNull: true);
        lock (_gate)
        {
            foreach (var (key, value) in clean)
            {
                if (value is null)
                {
                    _globals.Remove(key);
                }
                else if (_globals.ContainsKey(key) || _globals.Count < ProfileRules.MaxProperties)
                {
                    _globals[key] = value;
                }
                else
                {
                    dropped++;
                }
            }
        }
        if (dropped > 0)
        {
            Warn($"global özellik: {dropped} özellik sözleşmeye uymadığı ya da sınırı aştığı için düştü");
        }
    }

    /// <summary>Bütün global özellikleri siler.</summary>
    public void ClearGlobalProperties()
    {
        lock (_gate)
        {
            _globals.Clear();
        }
    }

    /// <summary>
    /// Satın alma ya da abonelik beyanı (<c>feralin_purchase</c>). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa
    /// REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; <c>verified</c> alanı hiçbir zaman gönderilmez. Geçersiz girdide <c>null</c> döner, fırlatmaz.
    /// </summary>
    public TrackedEvent? TrackRevenue(RevenueInput input, TrackOptions? options = null)
    {
        var props = RevenueRules.Build(input);
        if (props is null)
        {
            Warn("geçersiz gelir girdisi, olay üretilmedi");
            return null;
        }
        return Track(RevenueRules.EventName, props, options);
    }

    /// <summary>
    /// Yakalanan (<c>try/catch</c>) bir hatayı <c>fr_error</c> olarak bildirir. Ham yığın izi gitmez: hata sınıfı adı, temizlenmiş mesaj,
    /// <c>Ad.Alanı.Tür.Yöntem</c> çerçevelerinin özeti olan parmak izi ve en üst çerçeve gider. <paramref name="origin"/> bilinmeyen bir
    /// değerse <c>manual</c> sayılır. İzin yoksa, sınır (süreç başına 20, parmak izi başına 3) ya da örnekleme düşürürse <c>null</c> döner; fırlatmaz.
    /// </summary>
    public TrackedEvent? CaptureError(Exception error, string origin = ErrorOrigin.Handled, bool fatal = false, TrackOptions? options = null)
    {
        if (error is null)
        {
            return null;
        }
        try
        {
            var props = ErrorRules.Build(error, ErrorRules.ValidOrigin(origin) ? origin : ErrorOrigin.Manual, fatal, _appVersion);
            bool allowed;
            lock (_gate)
            {
                allowed = !_closed && !_optedOut && (options?.Consent ?? _consent).Analytics;
            }
            // İzin yokken sınır sayacı tüketilmez: izin sonradan gelirse hatalar yine raporlanabilsin.
            if (!allowed)
            {
                return null;
            }
            if (!_errorLimiter.Allow((string)props["fingerprint"]!))
            {
                Debug("fr_error sınırı ya da örnekleme, olay üretilmedi");
                return null;
            }
            return Track(ErrorRules.EventName, props, options);
        }
        catch (Exception ex)
        {
            Warn($"fr_error üretilemedi: {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>
    /// Olayı doğrular ve kuyruğa ekler; ağ çağrısı yapmaz. İzin yoksa veya girdi geçersizse <c>null</c> döner, fırlatmaz.
    /// <c>fr_click</c> yalnız <c>consent.advertising == true</c> iken gönderilir, aksi halde çıkarılır.
    /// </summary>
    public TrackedEvent? Track(string eventName, IEnumerable<KeyValuePair<string, object?>>? properties = null, TrackOptions? options = null)
    {
        try
        {
            return BuildAndEnqueue(eventName, properties, options);
        }
        catch (Exception ex)
        {
            // JSON'a dönüştürülemeyen değer (döngü, NaN) dahil hiçbir girdi uygulamayı düşürmez.
            Warn($"olay üretilemedi: {ex.GetType().Name}");
            return null;
        }
    }

    private TrackedEvent? BuildAndEnqueue(string eventName, IEnumerable<KeyValuePair<string, object?>>? properties, TrackOptions? options)
    {
        Consent consent;
        string? defaultUser;
        KeyValuePair<string, object?>[] globals;
        lock (_gate)
        {
            if (_closed)
            {
                return null;
            }
            if (_optedOut)
            {
                return null;
            }
            consent = options?.Consent ?? _consent;
            defaultUser = _userId;
            globals = _globals.Count > 0 && !ProfileRules.IsSystemEvent(eventName) ? _globals.ToArray() : Array.Empty<KeyValuePair<string, object?>>();
        }
        if (!consent.Analytics)
        {
            Debug("izin yok, olay üretilmedi");
            return null;
        }
        if (!EventRules.ValidEventName(eventName))
        {
            Warn("geçersiz olay adı");
            return null;
        }
        var userId = options?.UserId ?? defaultUser;
        foreach (var id in new[] { userId, options?.AnonymousId, options?.SessionId })
        {
            if (id is { Length: > EventRules.MaxIdentifierLength })
            {
                Warn("geçersiz kimlik alanı, olay üretilmedi");
                return null;
            }
        }

        var props = EventRules.SanitizeProperties(properties);
        foreach (var (key, value) in globals)
        {
            if (props.Count >= EventRules.MaxProperties)
            {
                break;
            }
            props.TryAdd(key, value);
        }
        var context = EventRules.NormalizeContext(options?.Context, props);
        if (consent.Advertising != true)
        {
            props.Remove(EventRules.ClickProperty);
        }

        // Eşleştirme kodu yalnız ilk olaya eklenir; özellik sınırı kodu dışarıda bırakmasın diye en sona yazılır. Kod burada alınır,
        // olay kuyruğa giremezse geri konur.
        var installCode = Interlocked.Exchange(ref _pendingInstallCode, null);
        if (installCode is not null)
        {
            props[EventRules.InstallCodeProperty] = installCode;
        }

        var now = _now();
        var eventId = Ulid.New(now);
        var wire = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["event_id"] = eventId,
            ["event_name"] = eventName,
            ["occurred_at"] = FormatTime(options?.OccurredAt ?? now),
            ["platform"] = "dotnet",
            ["schema_version"] = 1,
            ["sdk"] = new Dictionary<string, string> { ["name"] = SdkName, ["version"] = SdkVersion },
            ["consent"] = ConsentToWire(consent),
        };
        if (!string.IsNullOrEmpty(options?.AnonymousId))
        {
            wire["anonymous_id"] = options.AnonymousId;
        }
        if (!string.IsNullOrEmpty(userId))
        {
            wire["user_id"] = userId;
        }
        if (!string.IsNullOrEmpty(options?.SessionId))
        {
            wire["session_id"] = options.SessionId;
        }
        if (props.Count > 0)
        {
            wire["properties"] = props;
        }
        if (context is not null)
        {
            wire["context"] = context;
        }

        // Serileştirme kuyruktan önce yapılır; bozuk bir olay batch'i zehirleyemez.
        var json = JsonSerializer.Serialize(wire);
        var bytes = Encoding.UTF8.GetByteCount(json);
        if (bytes > MaxBodyBytes)
        {
            Warn($"olay boyut sınırını aşıyor, atıldı: {bytes} bayt");
            RestoreInstallCode(installCode);
            return null;
        }

        bool full;
        lock (_gate)
        {
            if (_closed || _optedOut)
            {
                RestoreInstallCode(installCode);
                return null;
            }
            _queue.Add(new Queued(eventId, json, bytes));
            var over = _queue.Count + (_pinned?.Count ?? 0) - _queueLimit;
            if (over > 0)
            {
                var removed = Math.Min(over, _queue.Count);
                _queue.RemoveRange(0, removed);
                _dropped += removed;
                Warn($"kuyruk sınırı aşıldı, en eski {removed} olay atıldı");
            }
            full = _queue.Count >= _batchSize;
        }
        if (full && _loop is not null)
        {
            Signal();
        }
        return new TrackedEvent(eventId, eventName, props);
    }

    private void RestoreInstallCode(string? installCode)
    {
        if (installCode is not null)
        {
            Interlocked.CompareExchange(ref _pendingInstallCode, installCode, null);
        }
    }

    private static string FormatTime(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    private static Dictionary<string, bool> ConsentToWire(Consent consent)
    {
        var wire = new Dictionary<string, bool>(StringComparer.Ordinal) { ["analytics"] = consent.Analytics };
        if (consent.Advertising is { } advertising)
        {
            wire["advertising"] = advertising;
        }
        if (consent.Personalization is { } personalization)
        {
            wire["personalization"] = personalization;
        }
        if (consent.SessionReplay is { } replay)
        {
            wire["session_replay"] = replay;
        }
        return wire;
    }

    /// <summary>
    /// Kuyruğu gönderir; fırlatmaz. 202 → silinir; 4xx (429 hariç) → atılır; 429, 5xx ve ağ hatası → aynı içerik ve aynı
    /// anahtarla sonra denenir. Sunucunun Retry-After süresi dolmadan açık çağrı da istek yapmaz.
    /// </summary>
    public Task<FlushResult> FlushAsync(CancellationToken cancellationToken = default) => DrainAsync(force: false, cancellationToken);

    private async Task<FlushResult> DrainAsync(bool force, CancellationToken cancellationToken)
    {
        try
        {
            await _sendLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException)
        {
            return new FlushResult { Retained = Queued_() };
        }
        try
        {
            if (!force)
            {
                lock (_gate)
                {
                    if (_now() < _serverNotBefore)
                    {
                        return new FlushResult { Retained = QueuedLocked() };
                    }
                }
            }
            int sent = 0, accepted = 0, rejected = 0, status = 0;
            string? batchId = null;
            // Üretici sürekli ekliyorsa döngü sonsuz olmasın.
            var rounds = (_queueLimit / _batchSize) + 2;
            for (var round = 0; round < rounds; round++)
            {
                var batch = NextBatch();
                if (batch is null)
                {
                    break;
                }
                var result = await SendAsync(batch, cancellationToken).ConfigureAwait(false);
                sent += result.Sent;
                accepted += result.Accepted;
                rejected += result.Rejected;
                status = result.Status;
                batchId = result.BatchId ?? batchId;
                if (result.Retained > 0)
                {
                    break;
                }
            }
            return new FlushResult { Sent = sent, Accepted = accepted, Rejected = rejected, Status = status, BatchId = batchId, Retained = Queued_() };
        }
        finally
        {
            _sendLock.Release();
        }
    }

    private List<Queued>? NextBatch()
    {
        lock (_gate)
        {
            if (_pinned is not null)
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

    private async Task<FlushResult> SendAsync(List<Queued> batch, CancellationToken cancellationToken)
    {
        var size = batch.Count;
        var body = new StringBuilder(batch.Sum(item => item.Bytes) + 64);
        body.Append("{\"sent_at\":\"").Append(FormatTime(_now())).Append("\",\"events\":[");
        for (var i = 0; i < size; i++)
        {
            if (i > 0)
            {
                body.Append(',');
            }
            body.Append(batch[i].Json);
        }
        body.Append("]}");

        using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint)
        {
            Content = new StringContent(body.ToString(), Encoding.UTF8, "application/json"),
        };
        request.Headers.TryAddWithoutValidation("x-feralin-project-key", _projectKey);
        request.Headers.TryAddWithoutValidation("Idempotency-Key", Idempotency.KeyFor(batch.Select(item => item.Id)));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/problem+json"));

        int status;
        string text;
        TimeSpan? retryAfter;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(_timeout);
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseContentRead, timeout.Token).ConfigureAwait(false);
            status = (int)response.StatusCode;
            text = await response.Content.ReadAsStringAsync(CancellationToken.None).ConfigureAwait(false);
            retryAfter = ReadRetryAfter(response.Headers.RetryAfter);
        }
        catch (Exception ex)
        {
            // Özel işleyici dahil hiçbir taşıma hatası uygulamaya geçmez; sonuç bilinmediğinden batch aynı anahtarla denenir.
            NoteFailure(null);
            Debug($"ağ hatası, {size} olay kuyrukta: {ex.GetType().Name}");
            return new FlushResult { Sent = size, Retained = size };
        }

        if (status == 202)
        {
            var (accepted, rejected, batchId) = ParseAck(text, size);
            lock (_gate)
            {
                ReleaseLocked(batch);
                _failures = 0;
                _notBefore = default;
                _serverNotBefore = default;
            }
            Debug($"batch kabul edildi: accepted={accepted} rejected={rejected}");
            return new FlushResult { Sent = size, Accepted = accepted, Rejected = rejected, Status = status, BatchId = batchId };
        }
        if (status is >= 400 and < 500 and not 429)
        {
            lock (_gate)
            {
                ReleaseLocked(batch);
            }
            Warn($"batch kalıcı olarak reddedildi: HTTP {status}, {size} olay atıldı, {ProblemTitle(text)}");
            return new FlushResult { Sent = size, Rejected = size, Status = status };
        }
        NoteFailure(retryAfter);
        Debug($"geçici hata: HTTP {status}, {size} olay kuyrukta");
        return new FlushResult { Sent = size, Status = status, Retained = size };
    }

    /// <summary>İstek sürerken izin geri çekildiyse kuyruk çoktan boşaltılmıştır; yeni batch'e dokunulmaz.</summary>
    private void ReleaseLocked(List<Queued> batch)
    {
        if (ReferenceEquals(_pinned, batch))
        {
            _pinned = null;
        }
    }

    private TimeSpan? ReadRetryAfter(RetryConditionHeaderValue? header)
    {
        if (header?.Delta is { } delta)
        {
            return delta;
        }
        if (header?.Date is { } date)
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
            // Yarım jitter: aynı anda yeniden başlayan süreçler toplayıcıya birlikte yüklenmez.
            _notBefore = _now() + TimeSpan.FromMilliseconds(Math.Round(ceiling * (0.5 + (_random() * 0.5))));
            if (retryAfter is { } wait && wait > TimeSpan.Zero)
            {
                _serverNotBefore = _now() + (wait < MaxRetryAfter ? wait : MaxRetryAfter);
            }
        }
    }

    private static (int Accepted, int Rejected, string? BatchId) ParseAck(string text, int size)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            var accepted = root.TryGetProperty("accepted", out var a) && a.TryGetInt32(out var acceptedValue) ? acceptedValue : size;
            var rejected = root.TryGetProperty("rejected", out var r) && r.TryGetInt32(out var rejectedValue) ? rejectedValue : 0;
            var batchId = root.TryGetProperty("batch_id", out var b) && b.ValueKind == JsonValueKind.String ? b.GetString() : null;
            return (accepted, rejected, batchId);
        }
        catch (JsonException)
        {
            return (size, 0, null);
        }
    }

    /// <summary>Ham gövde loga yazılmaz; yalnız RFC 7807 başlığı.</summary>
    private static string ProblemTitle(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            if (doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.TryGetProperty("title", out var title)
                && title.ValueKind == JsonValueKind.String)
            {
                var value = title.GetString() ?? "";
                return value.Length > 120 ? value[..120] : value;
            }
        }
        catch (JsonException)
        {
            // Gövde JSON değilse başlık yoktur.
        }
        return "problem+json yok";
    }

    private async Task RunLoopAsync()
    {
        using var ticker = new PeriodicTimer(_flushInterval);
        var ticking = ticker.WaitForNextTickAsync(_stop.Token).AsTask();
        var waking = _wake.WaitAsync(_stop.Token);
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                var completed = await Task.WhenAny(ticking, waking).ConfigureAwait(false);
                await completed.ConfigureAwait(false);
                if (completed == ticking)
                {
                    ticking = ticker.WaitForNextTickAsync(_stop.Token).AsTask();
                }
                else
                {
                    waking = _wake.WaitAsync(_stop.Token);
                }
                bool waiting;
                lock (_gate)
                {
                    var until = _notBefore > _serverNotBefore ? _notBefore : _serverNotBefore;
                    waiting = _now() < until || QueuedLocked() == 0;
                }
                if (!waiting)
                {
                    await DrainAsync(force: false, _stop.Token).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Normal kapanış.
        }
        catch (Exception ex)
        {
            Warn($"arka plan göndericisi durdu: {ex.GetType().Name}");
        }
    }

    private void Signal()
    {
        try
        {
            if (_wake.CurrentCount == 0)
            {
                _wake.Release();
            }
        }
        catch (SemaphoreFullException)
        {
            // Zaten uyandırılmış.
        }
    }

    /// <summary>Arka plan göndericiyi durdurur, kalanı en çok <paramref name="timeout"/> içinde göndermeyi dener. Birden çok çağrı güvenlidir.</summary>
    public async Task<FlushResult> CloseAsync(TimeSpan? timeout = null)
    {
        lock (_gate)
        {
            if (_closed)
            {
                return new FlushResult { Retained = QueuedLocked() };
            }
            _closed = true;
        }
        await _stop.CancelAsync().ConfigureAwait(false);
        if (_loop is not null)
        {
            await _loop.ConfigureAwait(false);
        }
        using var limit = new CancellationTokenSource(timeout ?? DefaultCloseTimeout);
        return await DrainAsync(force: true, limit.Token).ConfigureAwait(false);
    }

    /// <summary>Anlık durum (tanı amaçlı); anahtar döndürülmez.</summary>
    public FeralinStatus GetStatus()
    {
        lock (_gate)
        {
            var until = _notBefore > _serverNotBefore ? _notBefore : _serverNotBefore;
            var backoff = until - _now();
            return new FeralinStatus(SdkName, SdkVersion, QueuedLocked(), _dropped, _consent, _optedOut, _closed, backoff > TimeSpan.Zero ? backoff : TimeSpan.Zero, _endpoint);
        }
    }

    private int Queued_()
    {
        lock (_gate)
        {
            return QueuedLocked();
        }
    }

    private int QueuedLocked() => _queue.Count + (_pinned?.Count ?? 0);

    private void ClearQueueLocked()
    {
        _queue.Clear();
        _pinned = null;
        _failures = 0;
        _notBefore = default;
        _serverNotBefore = default;
    }

    private void Debug(string message) => Write(FeralinLogLevel.Debug, message);

    private void Warn(string message) => Write(FeralinLogLevel.Warning, message);

    private void Write(FeralinLogLevel level, string message)
    {
        try
        {
            _log?.Invoke(level, message);
        }
        catch (Exception)
        {
            // Uygulamanın log hatası SDK akışını kesmez.
        }
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        await CloseAsync().ConfigureAwait(false);
        Release();
    }

    /// <inheritdoc />
    public void Dispose()
    {
        // Eşzamanlı bağlam kilitlenmesin diye iş havuzunda beklenir.
        Task.Run(() => CloseAsync()).GetAwaiter().GetResult();
        Release();
    }

    private void Release()
    {
        if (_ownsHttp)
        {
            _http.Dispose();
        }
        _stop.Dispose();
        _sendLock.Dispose();
        _wake.Dispose();
    }
}
