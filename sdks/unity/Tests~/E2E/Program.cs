// Temiz kurulumdan çalışan tüketici: UPM tarball'ı boş dizine açılır, çekirdek derlenir ve gerçek services/collect ile konuşur.
// Taşıyıcı burada HttpClient'tır; UnityWebRequest yolu bu dosyada sınanmaz. Denetim satırları outbox_check.go ile doğrulanır.
using System.Text;
using System.Text.Json;
using Feralin.Unity;

var collectUrl = Require("FERALIN_E2E_COLLECT_URL");
var projectKey = Require("FERALIN_E2E_PROJECT_KEY");
var checks = Require("FERALIN_E2E_CHECKS");
using var http = new HttpClient();
// Gelir işlem kimliği toplayıcıda tekrar sayılmaz; aynı test veritabanında yeniden koşulabilsin diye her koşuya özgüdür.
var runId = Guid.NewGuid().ToString("N")[..10];

// Olay adı ve özellik denetimleri ayrı dosyadadır (scripts/sdk-e2e/unity_event_check.go); yol verilmezse atlanır.
var eventChecks = Environment.GetEnvironmentVariable("FERALIN_E2E_EVENT_CHECKS");
void Expect(string line) => File.AppendAllText(checks, line + "\n");
void ExpectEvent(string line)
{
    if (!string.IsNullOrEmpty(eventChecks))
    {
        File.AppendAllText(eventChecks, line + "\n");
    }
}
void Report(string name, object detail) => Console.WriteLine($"  OK {name}: {JsonSerializer.Serialize(detail)}");

FeralinClient Make(Consent consent = null, IFeralinTransport transport = null, string key = null) => new(new FeralinOptions
{
    ProjectKey = key ?? projectKey,
    CollectUrl = collectUrl,
    FlushInterval = TimeSpan.Zero,
    Consent = consent,
    Transport = transport ?? new HttpTransport(http),
});

static Dictionary<string, object> Props(params (string Key, object Value)[] items) => items.ToDictionary(item => item.Key, item => item.Value);

static FlushResult Flush(FeralinClient client)
{
    FlushResult result = null;
    client.Flush(r => result = r);
    Check(result != null, "HttpTransport eşzamanlıdır, sonuç hemen gelmeliydi");
    return result;
}

// 202 + outbox satırı + fr_click reklam izniyle
{
    var client = Make(new Consent(true, true));
    var e = client.TrackIapPurchase("gem_pack", 49.99m, "TRY", $"txn_unity_{runId}_1", Props(("fr_click", "clk_unity_1"), ("verified", true)));
    Check(e != null && !e.Properties.ContainsKey("verified"), "verified çıkarılmalıydı");
    var r = Flush(client);
    Check((r.Status, r.Accepted, r.Rejected, r.Retained) == (202, 1, 0, 0), $"202 bekleniyordu: {JsonSerializer.Serialize(r)}");
    Expect($"frclick {r.BatchId}");
    Expect($"once {e.EventId}");
    Expect($"platform unity:{e.EventId}");
    Report("202-outbox-frclick", new { r.Status, r.BatchId });
}

// Reklam izni yok: fr_click çıkarılır
{
    var client = Make(new Consent(true));
    var e = client.TrackLevelStart("dunya_1", properties: Props(("fr_click", "clk_unity_2")));
    Check(e != null && !e.Properties.ContainsKey("fr_click"), "fr_click çıkarılmalıydı");
    var r = Flush(client);
    Check(r.Status == 202, "202 bekleniyordu");
    Expect($"nofrclick {r.BatchId}");
    Report("frclick-izinsiz-cikarildi", new { r.Status });
}

// İzinsiz: SDK olay üretmez ve istek yapmaz
{
    var counting = new HttpTransport(http);
    var client = Make(null, counting);
    Check(client.Track("level_start") is null, "izinsiz olay üretilmemeliydi");
    var r = Flush(client);
    Check(r.Sent == 0 && counting.Requests == 0, "izinsiz istek yapılmamalıydı");
    Report("izinsiz-sdk-uretmez", new { r.Sent, counting.Requests });
}

// İzinsiz ham istek: toplayıcı olay düzeyinde reddeder, outbox'a yazmaz
{
    var id = ("01JCUNI" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()).PadRight(26, '0');
    var body = JsonSerializer.Serialize(new { events = new[] { new { event_id = id, event_name = "denied_event", occurred_at = DateTimeOffset.UtcNow.ToString("O"), platform = "unity", schema_version = 1, consent = new { analytics = false } } } });
    using var request = new HttpRequestMessage(HttpMethod.Post, $"{collectUrl}/v1/batch") { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    request.Headers.TryAddWithoutValidation("X-Feralin-Project-Key", projectKey);
    request.Headers.TryAddWithoutValidation("Idempotency-Key", Idempotency.KeyFor(new[] { id }));
    using var response = http.Send(request);
    var json = JsonDocument.Parse(response.Content.ReadAsStringAsync().GetAwaiter().GetResult()).RootElement;
    Check((int)response.StatusCode == 202 && json.GetProperty("accepted").GetInt32() == 0 && json.GetProperty("rejected_reasons").GetProperty("consent_denied").GetInt32() == 1, "toplayıcı izinsiz olayı reddetmeliydi");
    Expect($"absent {id}");
    Report("izinsiz-toplayici-red", new { status = (int)response.StatusCode, rejected = json.GetProperty("rejected").GetInt32() });
}

// Yanlış anahtar: 401, olay atılır, oyun düşmez
{
    var client = Make(new Consent(true), key: "pk_test_wrong_key_000");
    var e = client.Track("level_start", Props(("level_id", "yanlis")));
    var r = Flush(client);
    Check((r.Status, r.Rejected, r.Retained) == (401, 1, 0), "401 bekleniyordu");
    Expect($"absent {e.EventId}");
    Report("yanlis-anahtar-401", new { r.Status, r.Rejected });
}

// Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
{
    var lossy = new HttpTransport(http) { LoseFirstResponse = true };
    var client = Make(new Consent(true), lossy);
    var e = client.TrackLevelComplete("dunya_1", 1, 1200, 33500);
    var lost = Flush(client);
    Check((lost.Status, lost.Retained) == (0, 1), "yanıt kaybı kuyrukta tutulmalıydı");
    var next = client.TrackLevelStart("dunya_2");
    var retried = Flush(client);
    Check(retried.Status == 202 && retried.Retained == 0, "tekrar 202 vermeliydi");
    Check(lossy.Keys.Count == 3 && lossy.Keys[0] == lossy.Keys[1] && lossy.Keys[2] != lossy.Keys[0], "aynı anahtar bekleniyordu");
    Expect($"once {e.EventId}");
    Expect($"once {next.EventId}");
    Report("idempotency-tekrar", new { key = lossy.Keys[0], retried.Accepted });
}

// Ortak sözleşmeler: feralin_purchase, oyun olayları, fr_ad_revenue, fr_group, fr_user_properties, fr_error, otomatik oturum
{
    var client = Make(new Consent(true, true));
    var purchase = client.TrackRevenue(new RevenueInput
    {
        TransactionId = $"GPA.unity-{runId}",
        AmountMinor = 4999,
        Currency = "TRY",
        ProductId = "gem_pack",
        PurchaseType = PurchaseType.Purchase,
        Receipt = new Receipt(ReceiptProvider.Google, "GIZLI_PURCHASE_TOKEN_unity_e2e"),
        Properties = Props(("verified", true)),
    });
    var level = client.TrackLevelFail("dunya_3", 1, 10, 12500, "zaman_doldu");
    var economy = client.TrackEconomySource("gem", 50, "quest_reward", "gift_box");
    var rewarded = client.TrackRewardedAdComplete("revive", "applovin_max", 1, "life");
    var adRevenue = client.TrackAdRevenue(new AdRevenueInput { Network = "admob", AdUnit = "ca-app-pub-unity/e2e", AdFormat = AdFormat.Rewarded, RevenueMicros = 12500, Currency = "USD", Precision = AdPrecision.Estimated });
    var group = client.Group("klan_e2e", Props(("tier", "gold")));
    var userProps = client.SetUserProperties(Props(("plan", "pro")));
    var error = client.CaptureError("InvalidOperationException", "oyuncu ali@example.com girdi", "Game.Shop.Buy (System.String sku) (at C:/Users/Ali/proj/Shop.cs:10)\n", false, ErrorSource.LogException);
    Check(new[] { purchase, level, economy, rewarded, adRevenue, group, userProps, error }.All(e => e != null), "tüm sözleşme olayları üretilmeliydi");
    var r = Flush(client);
    Check((r.Status, r.Accepted, r.Rejected, r.Retained) == (202, 8, 0, 0), "8 olayın tamamı kabul edilmeliydi");
    ExpectEvent($"event feralin_purchase:{purchase.EventId}");
    ExpectEvent($"prop {purchase.EventId}:amount_minor=4999");
    ExpectEvent($"prop {purchase.EventId}:currency=\"TRY\"");
    ExpectEvent($"prop {purchase.EventId}:transaction_id=\"GPA.unity-{runId}\"");
    ExpectEvent($"prop {purchase.EventId}:receipt_provider=\"google\"");
    ExpectEvent($"noprop {purchase.EventId}:verified");
    ExpectEvent($"noraw {purchase.EventId}:GIZLI_PURCHASE_TOKEN_unity_e2e");
    ExpectEvent($"session {purchase.EventId}");
    ExpectEvent($"event level_fail:{level.EventId}");
    ExpectEvent($"event economy_source:{economy.EventId}");
    ExpectEvent($"event rewarded_ad_complete:{rewarded.EventId}");
    ExpectEvent($"event fr_ad_revenue:{adRevenue.EventId}");
    ExpectEvent($"prop {adRevenue.EventId}:revenue_micros=12500");
    ExpectEvent($"prop {adRevenue.EventId}:ad_format=\"rewarded\"");
    ExpectEvent($"noprop {adRevenue.EventId}:transaction_id");
    ExpectEvent($"noprop {adRevenue.EventId}:revenue_minor");
    ExpectEvent($"prop {adRevenue.EventId}:network=\"admob\"");
    ExpectEvent($"prop {adRevenue.EventId}:precision=\"estimated\"");
    ExpectEvent($"prop {error.EventId}:origin=\"uncaught_exception\"");
    ExpectEvent($"prop {error.EventId}:error_type=\"InvalidOperationException\"");
    ExpectEvent($"prop {level.EventId}:fail_reason=\"zaman_doldu\"");
    ExpectEvent($"prop {economy.EventId}:currency_name=\"gem\"");
    ExpectEvent($"event fr_group:{group.EventId}");
    ExpectEvent($"prop {group.EventId}:group_id=\"klan_e2e\"");
    ExpectEvent($"event fr_user_properties:{userProps.EventId}");
    ExpectEvent($"event fr_error:{error.EventId}");
    ExpectEvent($"noraw {error.EventId}:ali@example.com");
    ExpectEvent($"noraw {error.EventId}:C:/Users/Ali");
    Report("ortak-sozlesmeler", new { r.Status, r.Accepted });
}

// Kalıcı şifreli kuyruk: çevrimdışı olay yeniden başlatmadan sonra aynı event_id ile tek kez teslim edilir
{
    var directory = Path.Combine(Path.GetTempPath(), "feralin-unity-e2e-" + Guid.NewGuid().ToString("N"));
    var key = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
    IEventStore NewStore() => new EncryptedEventStore(new FileEventStore(directory), new AesGcmPayloadCipher(key));
    try
    {
        var offline = new FeralinClient(new FeralinOptions { ProjectKey = projectKey, CollectUrl = collectUrl, FlushInterval = TimeSpan.Zero, Consent = new Consent(true), Transport = new DownTransport(), Store = NewStore() });
        var tracked = offline.TrackRevenue(new RevenueInput { TransactionId = $"txn_unity_offline_{runId}", AmountMinor = 1999, Currency = "USD" });
        var failed = Flush(offline);
        Check((failed.Status, failed.Retained) == (0, 1), "çevrimdışı olay kuyrukta kalmalıydı");
        var onDisk = File.ReadAllText(Path.Combine(directory, "events.log"));
        Check(!onDisk.Contains("txn_unity_offline") && !onDisk.Contains("feralin_purchase"), "diskteki kuyruk şifreli olmalıydı");

        // Oyun kapandı; yeni süreç aynı diskten başlar.
        var restarted = new FeralinClient(new FeralinOptions { ProjectKey = projectKey, CollectUrl = collectUrl, FlushInterval = TimeSpan.Zero, Consent = new Consent(true), Transport = new HttpTransport(http), Store = NewStore() });
        Check(restarted.GetStatus().Queued == 1, "olay yeniden başlatmada geri yüklenmeliydi");
        var delivered = Flush(restarted);
        Check((delivered.Status, delivered.Accepted, delivered.Retained) == (202, 1, 0), "geri yüklenen olay kabul edilmeliydi");
        Check(NewStore().Load().Count == 0, "kabul edilen olay diskten silinmeliydi");
        Expect($"once {tracked.EventId}");
        ExpectEvent($"event feralin_purchase:{tracked.EventId}");
        Report("kalici-kuyruk-ayni-event-id", new { delivered.Status, tracked.EventId });
    }
    finally
    {
        try
        {
            Directory.Delete(directory, true);
        }
        catch (IOException)
        {
        }
    }
}

// Atıf: Play Install Referrer ve uygulama bağlantısı fr_click taşır; ilk açılış kurulum başına tek kez sayılır
{
    var directory = Path.Combine(Path.GetTempPath(), "feralin-unity-e2e-attr-" + Guid.NewGuid().ToString("N"));
    var key = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
    try
    {
        var store = new EncryptedEventStore(new FileEventStore(directory), new AesGcmPayloadCipher(key));
        var client = new FeralinClient(new FeralinOptions { ProjectKey = projectKey, CollectUrl = collectUrl, FlushInterval = TimeSpan.Zero, Consent = new Consent(true, true), Transport = new HttpTransport(http), Store = store });
        client.StartAttribution(new FixedReferrer("fr_click=clk_unity_ref&utm_source=google&utm_medium=cpc"));
        client.HandleDeepLink("https://link.feralin.com/r/abc?fr_click=clk_unity_dl&token=GIZLI_BAGLANTI_DEGERI");
        var r = Flush(client);
        Check((r.Status, r.Accepted, r.Retained) == (202, 2, 0), $"ilk açılış ve bağlantı olayı kabul edilmeliydi: {JsonSerializer.Serialize(r)}");
        var firstOpen = store.GetMarker("first_open_event_id");
        Check(firstOpen != null, "ilk açılış işareti yazılmalıydı");
        Expect($"frclick {r.BatchId}");
        ExpectEvent($"event app_first_open:{firstOpen}");
        ExpectEvent($"prop {firstOpen}:attribution_source=\"play_install_referrer\"");
        ExpectEvent($"prop {firstOpen}:fr_click=\"clk_unity_ref\"");
        ExpectEvent($"noraw {firstOpen}:GIZLI_BAGLANTI_DEGERI");

        var again = new FeralinClient(new FeralinOptions { ProjectKey = projectKey, CollectUrl = collectUrl, FlushInterval = TimeSpan.Zero, Consent = new Consent(true, true), Transport = new HttpTransport(http), Store = store });
        again.StartAttribution(new FixedReferrer("fr_click=baska"));
        Check(again.GetStatus().Queued == 0, "ikinci başlatmada ilk açılış tekrarlanmamalıydı");
        Report("atif-ilk-acilis-ve-baglanti", new { r.Status, r.Accepted });
    }
    finally
    {
        try
        {
            Directory.Delete(directory, true);
        }
        catch (IOException)
        {
        }
    }
}

// Toplayıcı kapalı: oyun düşmez, olay kuyrukta kalır
{
    var client = new FeralinClient(new FeralinOptions { ProjectKey = projectKey, CollectUrl = "http://127.0.0.1:9", FlushInterval = TimeSpan.Zero, Consent = new Consent(true), Transport = new HttpTransport(http) });
    client.Track("level_start");
    var r = Flush(client);
    Check((r.Status, r.Retained) == (0, 1), "ağ hatası kuyrukta kalmalıydı");
    Report("toplayici-kapali", new { r.Status, r.Retained });
}

Console.WriteLine("unity çekirdek tüketici: tüm senaryolar geçti");
return 0;

static string Require(string name) => Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} zorunlu");

static void Check(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException($"KALDI: {message}");
    }
}

/// <summary>Referrer kaynağı yerine sabit bir dizgi verir.</summary>
internal sealed class FixedReferrer : IInstallReferrerSource
{
    private readonly string _value;
    public FixedReferrer(string value) => _value = value;
    public void Read(Action<string> onResult) => onResult(_value);
}

/// <summary>Her zaman ağ hatası veren taşıyıcı: çevrimdışı cihaz.</summary>
internal sealed class DownTransport : IFeralinTransport
{
    public void Send(TransportRequest request, Action<TransportResponse> onComplete) => onComplete(TransportResponse.NetworkError);
}

/// <summary>Testin eşzamanlı taşıyıcısı. LoseFirstResponse: ilk istek sunucuya ulaşır, yanıtı SDK'ya verilmez.</summary>
internal sealed class HttpTransport : IFeralinTransport
{
    private readonly HttpClient _http;
    public HttpTransport(HttpClient http) => _http = http;
    public int Requests { get; private set; }
    public bool LoseFirstResponse { get; set; }
    public List<string> Keys { get; } = new();

    public void Send(TransportRequest request, Action<TransportResponse> onComplete)
    {
        Requests++;
        using var message = new HttpRequestMessage(HttpMethod.Post, request.Url) { Content = new ByteArrayContent(request.Body) };
        foreach (var header in request.Headers)
        {
            if (header.Key == "Content-Type")
            {
                message.Content.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
            else
            {
                message.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
        }
        Keys.Add(request.Headers["Idempotency-Key"]);
        TransportResponse response;
        try
        {
            using var answer = _http.Send(message);
            response = new TransportResponse((int)answer.StatusCode, answer.Content.ReadAsStringAsync().GetAwaiter().GetResult(), answer.Headers.RetryAfter?.ToString());
        }
        catch (HttpRequestException)
        {
            response = TransportResponse.NetworkError;
        }
        if (LoseFirstResponse)
        {
            LoseFirstResponse = false;
            response = TransportResponse.NetworkError;
        }
        onComplete(response);
    }
}
