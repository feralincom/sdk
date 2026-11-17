// Temiz kurulumdan çalışan tüketici: nupkg dosyaları boş dizine kurulur, MauiApp konteyneri kurulur ve gerçek services/collect ile konuşulur.
// Sade net9.0 hedefidir; platform yaşam döngüsü geri çağrıları burada tetiklenmez, FeralinLifecycle doğrudan çağrılır.
using System.Text;
using System.Text.Json;
using Feralin;
using Feralin.Maui;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui.Hosting;

var collectUrl = Require("FERALIN_E2E_COLLECT_URL");
var projectKey = Require("FERALIN_E2E_PROJECT_KEY");
var checks = Require("FERALIN_E2E_CHECKS");

void Expect(string line) => File.AppendAllText(checks, line + "\n");
void Report(string name, object detail) => Console.WriteLine($"  OK {name}: {JsonSerializer.Serialize(detail)}");

MauiApp Make(Consent? consent = null, HttpMessageHandler? handler = null, string? key = null)
{
    var builder = MauiApp.CreateBuilder(useDefaults: false);
    builder.UseFeralin(options =>
    {
        options.ProjectKey = key ?? projectKey;
        options.CollectUrl = collectUrl;
        options.FlushInterval = TimeSpan.Zero;
        options.Consent = consent;
        options.HttpHandler = handler;
    });
    return builder.Build();
}

static FeralinClient Client(MauiApp app) => app.Services.GetRequiredService<FeralinClient>();

// 202 + outbox satırı + fr_click reklam izniyle
using (var app = Make(new Consent(true, true)))
{
    var e = Client(app).Track("order_completed", new Dictionary<string, object?> { ["order_id"] = "ord_maui_1", ["fr_click"] = "clk_maui_1" })!;
    var r = await Client(app).FlushAsync();
    Check((r.Status, r.Accepted, r.Rejected, r.Retained) == (202, 1, 0, 0), "202 bekleniyordu");
    Expect($"frclick {r.BatchId}");
    Expect($"once {e.EventId}");
    Report("202-outbox-frclick", new { r.Status, r.BatchId });
}

// Reklam izni yok: fr_click çıkarılır
using (var app = Make(new Consent(true, false)))
{
    var e = Client(app).Track("order_completed", new Dictionary<string, object?> { ["order_id"] = "ord_maui_2", ["fr_click"] = "clk_maui_2" })!;
    Check(!e.Properties.ContainsKey("fr_click"), "fr_click çıkarılmalıydı");
    var r = await Client(app).FlushAsync();
    Check(r.Status == 202, "202 bekleniyordu");
    Expect($"nofrclick {r.BatchId}");
    Report("frclick-izinsiz-cikarildi", new { r.Status });
}

// İzinsiz: SDK olay üretmez ve istek yapmaz
using (var counting = new CountingHandler(new HttpClientHandler()))
using (var app = Make(null, counting))
{
    Check(Client(app).Track("order_completed") is null, "izinsiz olay üretilmemeliydi");
    var r = await Client(app).FlushAsync();
    Check(r.Sent == 0 && counting.Requests == 0, "izinsiz istek yapılmamalıydı");
    Report("izinsiz-sdk-uretmez", new { r.Sent, counting.Requests });
}

using var raw = new HttpClient();

// İzinsiz ham istek: toplayıcı olay düzeyinde reddeder, outbox'a yazmaz
{
    var id = ("01JCMAU" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()).PadRight(26, '0');
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
using (var app = Make(new Consent(true), key: "pk_test_wrong_key_000"))
{
    var e = Client(app).Track("order_completed", new Dictionary<string, object?> { ["order_id"] = "ord_maui_wrong" })!;
    var r = await Client(app).FlushAsync();
    Check((r.Status, r.Rejected, r.Retained) == (401, 1, 0), "401 bekleniyordu");
    Expect($"absent {e.EventId}");
    Report("yanlis-anahtar-401", new { r.Status, r.Rejected });
}

// Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
using (var lossy = new LossyHandler(new HttpClientHandler()))
using (var app = Make(new Consent(true), lossy))
{
    var e = Client(app).Track("order_completed", new Dictionary<string, object?> { ["order_id"] = "ord_maui_retry" })!;
    var lost = await Client(app).FlushAsync();
    Check((lost.Status, lost.Retained) == (0, 1), "yanıt kaybı kuyrukta tutulmalıydı");
    var next = Client(app).Track("order_shipped", new Dictionary<string, object?> { ["order_id"] = "ord_maui_retry" })!;
    var retried = await Client(app).FlushAsync();
    Check(retried.Status == 202 && retried.Retained == 0, "tekrar 202 vermeliydi");
    Check(lossy.Keys.Count >= 3 && lossy.Keys[0] == lossy.Keys[1], "aynı anahtar bekleniyordu");
    Expect($"once {e.EventId}");
    Expect($"once {next.EventId}");
    Report("idempotency-tekrar", new { key = lossy.Keys[0], retried.Accepted });
}

// Yaşam döngüsü: arka plana geçiş çağrısı kuyruğu gerçek toplayıcıya gönderir
using (var app = Make(new Consent(true)))
{
    var e = Client(app).Track("screen_view", new Dictionary<string, object?> { ["screen"] = "home" })!;
    app.Services.GetRequiredService<FeralinLifecycle>().OnBackground();
    for (var i = 0; i < 100 && Client(app).GetStatus().Queued > 0; i++)
    {
        await Task.Delay(100);
    }
    Check(Client(app).GetStatus().Queued == 0, "arka plan çağrısı kuyruğu göndermeliydi");
    Expect($"once {e.EventId}");
    Report("yasam-dongusu-arka-plan", new { queued = 0 });
}

// MauiApp kapanışı: kalan olaylar Dispose sırasında gönderilir
{
    var app = Make(new Consent(true));
    var e = Client(app).Track("screen_view", new Dictionary<string, object?> { ["screen"] = "exit" })!;
    app.Dispose();
    Expect($"once {e.EventId}");
    Report("maui-dispose-gonderir", new { e.EventId });
}

Console.WriteLine("maui tüketici: tüm senaryolar geçti");
return 0;

static string Require(string name) => Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} zorunlu");

static void Check(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException($"KALDI: {message}");
    }
}

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

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Keys.Add(request.Headers.GetValues("Idempotency-Key").Single());
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
