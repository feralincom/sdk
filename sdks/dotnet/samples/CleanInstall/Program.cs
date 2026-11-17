// Temiz kurulumdan çalışan tüketici: nupkg dosyaları boş dizine kurulur ve gerçek services/collect ile konuşur.
// Senaryo QA-C yerel sürümüdür: ASP.NET Core DI ile sipariş olayı, idempotency ve hata yönetimi. Denetim satırları
// outbox_check.go ile PostgreSQL üzerinde doğrulanır.
using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Feralin;
using Feralin.AspNetCore;

var collectUrl = Require("FERALIN_E2E_COLLECT_URL");
var projectKey = Require("FERALIN_E2E_PROJECT_KEY");
var checks = Require("FERALIN_E2E_CHECKS");

void Expect(string line) => File.AppendAllText(checks, line + "\n");
void Report(string name, object detail) => Console.WriteLine($"  OK {name}: {JsonSerializer.Serialize(detail)}");

FeralinClient Make(Consent? consent = null, HttpMessageHandler? handler = null, string? key = null) => new(new FeralinOptions
{
    ProjectKey = key ?? projectKey,
    CollectUrl = collectUrl,
    FlushInterval = TimeSpan.Zero,
    Consent = consent,
    HttpHandler = handler,
});

// 202 + outbox satırı + fr_click reklam izniyle
await using (var client = Make(new Consent(true, true)))
{
    var e = client.Track("order_completed", new Dictionary<string, object?> { ["order_id"] = "ord_net_1", ["fr_click"] = "clk_net_1", ["amount"] = 12.5m }, new TrackOptions { UserId = "user_net_1" })!;
    var r = await client.FlushAsync();
    Check((r.Status, r.Accepted, r.Rejected, r.Retained) == (202, 1, 0, 0), "202 bekleniyordu");
    Expect($"frclick {r.BatchId}");
    Expect($"once {e.EventId}");
    Report("202-outbox-frclick", new { r.Status, r.BatchId });
}

// Reklam izni yok: fr_click çıkarılır
await using (var client = Make(new Consent(true, false)))
{
    var e = client.Track("order_completed", new Dictionary<string, object?> { ["order_id"] = "ord_net_2", ["fr_click"] = "clk_net_2" })!;
    Check(!e.Properties.ContainsKey("fr_click"), "fr_click çıkarılmalıydı");
    var r = await client.FlushAsync();
    Check(r.Status == 202, "202 bekleniyordu");
    Expect($"nofrclick {r.BatchId}");
    Report("frclick-izinsiz-cikarildi", new { r.Status });
}

// İzinsiz: SDK olay üretmez ve istek yapmaz
using (var counting = new CountingHandler(new HttpClientHandler()))
await using (var client = Make(null, counting))
{
    Check(client.Track("order_completed") is null, "izinsiz olay üretilmemeliydi");
    var r = await client.FlushAsync();
    Check(r.Sent == 0 && counting.Requests == 0, "izinsiz istek yapılmamalıydı");
    Report("izinsiz-sdk-uretmez", new { r.Sent, counting.Requests });
}

using var raw = new HttpClient();

// İzinsiz ham istek: toplayıcı olay düzeyinde reddeder, outbox'a yazmaz
{
    var id = ("01JCNET" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()).PadRight(26, '0');
    var body = JsonSerializer.Serialize(new { events = new[] { new { event_id = id, event_name = "denied_event", occurred_at = DateTimeOffset.UtcNow.ToString("O"), platform = "dotnet", schema_version = 1, consent = new { analytics = false } } } });
    using var request = new HttpRequestMessage(HttpMethod.Post, $"{collectUrl}/v1/batch") { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    request.Headers.TryAddWithoutValidation("x-feralin-project-key", projectKey);
    request.Headers.TryAddWithoutValidation("Idempotency-Key", Idempotency.KeyFor(new[] { id }));
    using var response = await raw.SendAsync(request);
    var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement;
    Check((int)response.StatusCode == 202 && json.GetProperty("accepted").GetInt32() == 0 && json.GetProperty("rejected_reasons").GetProperty("consent_denied").GetInt32() == 1, "toplayıcı izinsiz olayı reddetmeliydi");
    Expect($"absent {id}");
    Report("izinsiz-toplayici-red", new { status = (int)response.StatusCode, rejected = json.GetProperty("rejected").GetInt32() });
}

// Yanlış anahtar: 401, olay atılır, uygulama düşmez
await using (var client = Make(new Consent(true), key: "pk_test_wrong_key_000"))
{
    var e = client.Track("order_completed", new Dictionary<string, object?> { ["order_id"] = "ord_net_wrong" })!;
    var r = await client.FlushAsync();
    Check((r.Status, r.Rejected, r.Retained) == (401, 1, 0), "401 bekleniyordu");
    Expect($"absent {e.EventId}");
    Report("yanlis-anahtar-401", new { r.Status, r.Rejected });
}

// Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
using (var lossy = new LossyHandler(new HttpClientHandler()))
await using (var client = Make(new Consent(true), lossy))
{
    var e = client.Track("order_completed", new Dictionary<string, object?> { ["order_id"] = "ord_net_retry" })!;
    var lost = await client.FlushAsync();
    Check((lost.Status, lost.Retained) == (0, 1), "yanıt kaybı kuyrukta tutulmalıydı");
    var next = client.Track("order_shipped", new Dictionary<string, object?> { ["order_id"] = "ord_net_retry" })!;
    var retried = await client.FlushAsync();
    Check(retried.Status == 202 && retried.Retained == 0, "tekrar 202 vermeliydi");
    Check(lossy.Keys.Count >= 3 && lossy.Keys[0] == lossy.Keys[1], "aynı anahtar bekleniyordu");
    Expect($"once {e.EventId}");
    Expect($"once {next.EventId}");
    Report("idempotency-tekrar", new { key = lossy.Keys[0], ayni = lossy.Keys[0] == lossy.Keys[1], retried.Accepted });

    // Doğrudan tekrar: aynı gövde ve anahtar aynı batch_id ve ilk kabulün olay sayısını (bu batch tek olay: 1) döndürür (ölçüm denetimi madde 32); yeni olay yazılmaz.
    using var replay = new HttpRequestMessage(HttpMethod.Post, $"{collectUrl}/v1/batch") { Content = new StringContent(lossy.Bodies[2], Encoding.UTF8, "application/json") };
    replay.Headers.TryAddWithoutValidation("x-feralin-project-key", projectKey);
    replay.Headers.TryAddWithoutValidation("Idempotency-Key", lossy.Keys[2]);
    using var response = await raw.SendAsync(replay);
    var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement;
    Check((int)response.StatusCode == 202 && json.GetProperty("accepted").GetInt32() == 1 && json.GetProperty("batch_id").GetString() == retried.BatchId, "aynı batch_id bekleniyordu");
    Report("idempotency-ayni-batch", new { batch_id = retried.BatchId, accepted = json.GetProperty("accepted").GetInt32() });
}

// QA-C yerel: ASP.NET Core DI ile sipariş olayı, istek bazlı izin ve hata yönetimi
{
    var builder = WebApplication.CreateSlimBuilder();
    builder.WebHost.ConfigureKestrel(k => k.Listen(IPAddress.Loopback, 0));
    builder.Logging.ClearProviders();
    builder.Services.AddFeralin(o =>
    {
        o.ProjectKey = projectKey;
        o.CollectUrl = collectUrl;
        o.FlushInterval = TimeSpan.Zero;
    });
    var app = builder.Build();
    app.MapPost("/orders", async (HttpContext http, FeralinClient feralin) =>
    {
        var order = await http.Request.ReadFromJsonAsync<OrderRequest>() ?? throw new InvalidOperationException("gövde yok");
        var tracked = feralin.Track(
            "order_completed",
            new Dictionary<string, object?> { ["order_id"] = order.OrderId, ["amount"] = order.Amount, ["currency"] = order.Currency },
            new TrackOptions { UserId = order.UserId, Consent = new Consent(order.AnalyticsConsent) });
        var flushed = await feralin.FlushAsync();
        return Results.Json(new { event_id = tracked?.EventId, batch_id = flushed.BatchId, status = flushed.Status });
    });
    await app.StartAsync();
    var address = app.Urls.First();

    using var ok = await raw.PostAsJsonAsync($"{address}/orders", new OrderRequest("ord_aspnet_1", "user_aspnet_1", 42.5m, "TRY", true));
    var okBody = JsonDocument.Parse(await ok.Content.ReadAsStringAsync()).RootElement;
    Check(ok.IsSuccessStatusCode && okBody.GetProperty("status").GetInt32() == 202, "sipariş olayı 202 vermeliydi");
    Expect($"once {okBody.GetProperty("event_id").GetString()}");
    Report("qa-c-aspnet-di-siparis", new { status = okBody.GetProperty("status").GetInt32(), batch = okBody.GetProperty("batch_id").GetString() });

    using var denied = await raw.PostAsJsonAsync($"{address}/orders", new OrderRequest("ord_aspnet_2", "user_aspnet_2", 1m, "TRY", false));
    var deniedBody = JsonDocument.Parse(await denied.Content.ReadAsStringAsync()).RootElement;
    Check(denied.IsSuccessStatusCode && deniedBody.GetProperty("event_id").ValueKind == JsonValueKind.Null, "izinsiz sipariş olay üretmemeliydi");
    Report("qa-c-izinsiz-siparis", new { http = (int)denied.StatusCode, olay = "yok" });

    await app.StopAsync();
    await app.DisposeAsync();
}

// QA-C hata yönetimi: toplayıcı kapalıyken uygulama düşmez, olay kuyrukta kalır
await using (var client = new FeralinClient(new FeralinOptions { ProjectKey = projectKey, CollectUrl = "http://127.0.0.1:9", FlushInterval = TimeSpan.Zero, Consent = new Consent(true), Timeout = TimeSpan.FromSeconds(3) }))
{
    client.Track("order_completed", new Dictionary<string, object?> { ["order_id"] = "ord_net_down" });
    var r = await client.FlushAsync();
    Check((r.Status, r.Retained) == (0, 1), "ağ hatası kuyrukta kalmalıydı");
    Report("qa-c-toplayici-kapali", new { r.Status, r.Retained });
    client.Reset();
}

// UTP §8.2 kimlik yöntemleri: global özellik, kullanıcı özellikleri ve grup. Toplayıcı izin listesi (plan, tier) dışını düşürür;
// denetim satırları profile_check.go ile doğrulanır.
await using (var client = Make(new Consent(true)))
{
    var profileChecks = Require("FERALIN_E2E_PROFILE_CHECKS");
    void ExpectProfile(string line) => File.AppendAllText(profileChecks, line + "\n");
    client.SetGlobalProperties(new Dictionary<string, object?> { ["app_release"] = "e2e" });
    var tracked = client.Track("feature_used", new Dictionary<string, object?> { ["feature"] = "export" }, new TrackOptions { UserId = "user_net_profile" })!;
    var props = client.SetUserProperties(new Dictionary<string, object?> { ["plan"] = "pro", ["tier"] = 2, ["secret_note"] = "x", ["email"] = "a@b.co" }, new TrackOptions { UserId = "user_net_profile" })!;
    Check(!props.Properties.ContainsKey("email") && !props.Properties.ContainsKey("app_release"), "e-posta ve global özellik fr_user_properties olayında olmamalıydı");
    var group = client.Group("acme-team", new Dictionary<string, object?> { ["plan"] = "team" }, new TrackOptions { UserId = "user_net_profile" })!;
    Check(client.Group("ekip@acme.com") is null, "e-posta biçimli grup kimliği olay üretmemeliydi");
    var r = await client.FlushAsync();
    Check((r.Status, r.Accepted, r.Rejected) == (202, 3, 0), "3 kimlik olayı kabul edilmeliydi");
    ExpectProfile($"prop {tracked.EventId} app_release=\"e2e\"");
    ExpectProfile($"name fr_user_properties:{props.EventId}");
    ExpectProfile($"prop {props.EventId} plan=\"pro\"");
    ExpectProfile($"prop {props.EventId} tier=2");
    ExpectProfile($"noprop {props.EventId} secret_note");
    ExpectProfile($"noprop {props.EventId} email");
    ExpectProfile($"name fr_group:{group.EventId}");
    ExpectProfile($"prop {group.EventId} group_id=\"acme-team\"");
    ExpectProfile($"prop {group.EventId} plan=\"team\"");
    Expect($"once {props.EventId}");
    Expect($"once {group.EventId}");
    Report("kimlik-yontemleri", new { r.Status, r.Accepted });
}

// Çoklu olay, kapanışta gönderim
{
    var client = Make(new Consent(true));
    var events = new[] { "cart_viewed", "checkout_started", "order_completed" }.Select(n => client.Track(n, new Dictionary<string, object?> { ["source"] = "e2e" })!).ToArray();
    var r = await client.CloseAsync();
    Check((r.Status, r.Accepted) == (202, 3), "3 olay kabul edilmeliydi");
    foreach (var e in events)
    {
        Expect($"once {e.EventId}");
    }
    Report("close-batch", new { r.Accepted });
    await client.DisposeAsync();
}

Console.WriteLine(".NET tüketici: tüm senaryolar geçti");
return 0;

static string Require(string name) => Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} zorunlu");

static void Check(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException($"KALDI: {message}");
    }
}

internal sealed record OrderRequest(string OrderId, string UserId, decimal Amount, string Currency, bool AnalyticsConsent);

internal sealed class CountingHandler : DelegatingHandler
{
    public CountingHandler(HttpMessageHandler inner) : base(inner) { }
    public int Requests { get; private set; }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Requests++;
        return base.SendAsync(request, cancellationToken);
    }
}

/// <summary>İlk isteği sunucuya ulaştırır, yanıtı uygulamaya vermez: yol üstünde kaybolan yanıtı gerçek toplayıcıyla canlandırır.</summary>
internal sealed class LossyHandler : DelegatingHandler
{
    private bool _first = true;
    public LossyHandler(HttpMessageHandler inner) : base(inner) { }
    public List<string> Keys { get; } = new();
    public List<string> Bodies { get; } = new();

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Keys.Add(request.Headers.GetValues("Idempotency-Key").Single());
        Bodies.Add(await request.Content!.ReadAsStringAsync(cancellationToken));
        var response = await base.SendAsync(request, cancellationToken);
        if (_first)
        {
            _first = false;
            response.Dispose();
            throw new HttpRequestException("yanıt yolda kayboldu");
        }
        return response;
    }
}
