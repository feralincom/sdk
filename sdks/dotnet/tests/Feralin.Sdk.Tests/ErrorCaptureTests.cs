using System.Net;
using System.Text;
using System.Text.Json;
using Xunit;

namespace Feralin.Tests;

internal sealed class PaymentDeclinedException : Exception
{
    public PaymentDeclinedException(string message) : base(message)
    {
    }
}

/// <summary><c>fr_error</c> sözleşmesi (X4) ve kurulum eşleştirme kodu (<c>fr_install_code</c>).</summary>
public class ErrorCaptureTests
{
    private const string Key = "pk_test_dotnet_unit_0001";
    private static readonly HashSet<string> Allowed = new() { "error_type", "message", "fingerprint", "top_frame", "frame_count", "app_version", "handled", "fatal", "origin" };

    private sealed class Recorder : HttpMessageHandler
    {
        public List<string> Bodies { get; } = new();

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Bodies.Add(await request.Content!.ReadAsStringAsync(cancellationToken));
            return new HttpResponseMessage(HttpStatusCode.Accepted) { Content = new StringContent("{\"batch_id\":\"b1\",\"accepted\":1,\"rejected\":0}", Encoding.UTF8, "application/json") };
        }

        public JsonElement Event(int index) => JsonDocument.Parse(Bodies.Single()).RootElement.GetProperty("events")[index];
    }

    private static FeralinClient Client(Recorder handler, Consent? consent, Action<FeralinOptions>? configure = null, Func<double>? random = null)
    {
        var options = new FeralinOptions { ProjectKey = Key, CollectUrl = "http://collector.test", FlushInterval = TimeSpan.Zero, HttpHandler = handler, Consent = consent };
        configure?.Invoke(options);
        return new FeralinClient(options, () => DateTimeOffset.UtcNow, random ?? (() => 0.5));
    }

    private static void Charge() => throw new PaymentDeclinedException(
        "kart reddedildi ali@example.com https://pay.example.com/x?t=1 id 550e8400-e29b-41d4-a716-446655440000 tel +90 532 123 45 67 oturum ab12cd34ef56gh78ij90kl12mn34");

    private static async Task ChargeAsync()
    {
        await Task.Yield();
        Charge();
    }

    [Fact]
    public async Task CaptureError_sozlesmesi_ham_yigin_ve_kisisel_veri_gitmez()
    {
        var handler = new Recorder();
        var client = Client(handler, new Consent(true), o => o.AppVersion = "2.4.0");
        TrackedEvent? tracked = null;
        try
        {
            Charge();
        }
        catch (Exception ex)
        {
            tracked = client.CaptureError(ex, options: new TrackOptions { UserId = "user_42" });
        }
        Assert.NotNull(tracked);
        var p = tracked!.Properties;
        Assert.Equal("fr_error", tracked.EventName);
        Assert.Equal("PaymentDeclinedException", p["error_type"]);
        var message = (string)p["message"]!;
        foreach (var leak in new[] { "ali@example.com", "pay.example.com", "550e8400", "532 123", "ab12cd34" })
        {
            Assert.DoesNotContain(leak, message);
        }
        foreach (var tag in new[] { "[email]", "[url]", "[id]", "[num]", "[token]" })
        {
            Assert.Contains(tag, message);
        }
        Assert.Matches("^[0-9a-f]{16}$", (string)p["fingerprint"]!);
        Assert.Equal("Feralin.Tests.ErrorCaptureTests.Charge", p["top_frame"]);
        Assert.Equal(true, p["handled"]);
        Assert.Equal(false, p["fatal"]);
        Assert.Equal("handled", p["origin"]);
        Assert.Equal("2.4.0", p["app_version"]);
        Assert.All(p.Keys, k => Assert.Contains(k, Allowed));
        await client.FlushAsync();
        var wire = handler.Event(0);
        Assert.Equal("user_42", wire.GetProperty("user_id").GetString());
        Assert.False(wire.GetProperty("properties").TryGetProperty("stack", out _));
    }

    [Fact]
    public async Task Async_yontem_ozgun_adiyla_cerceve_olur()
    {
        var client = Client(new Recorder(), new Consent(true));
        Exception? caught = null;
        try
        {
            await ChargeAsync();
        }
        catch (Exception ex)
        {
            caught = ex;
        }
        var frames = ErrorRules.Frames(caught!);
        Assert.Equal("Feralin.Tests.ErrorCaptureTests.Charge", frames[0]);
        Assert.Contains("Feralin.Tests.ErrorCaptureTests.ChargeAsync", frames);
        Assert.DoesNotContain(frames, f => f.StartsWith("System.", StringComparison.Ordinal) || f.Contains("MoveNext") || f.Contains(':'));
        Assert.NotNull(client.CaptureError(caught!));
    }

    [Fact]
    public void Izin_sinir_ve_koken_kurallari()
    {
        var client = Client(new Recorder(), null);
        Assert.Null(client.CaptureError(new InvalidOperationException("x")));
        client.SetConsent(new Consent(true));
        var sent = Enumerable.Range(0, 5).Count(_ => client.CaptureError(new InvalidOperationException("aynı hata")) is not null);
        Assert.Equal(3, sent);
        var fatal = client.CaptureError(new TimeoutException("çöktü"), ErrorOrigin.UncaughtException, fatal: true);
        Assert.Equal(false, fatal!.Properties["handled"]);
        Assert.Equal(true, fatal.Properties["fatal"]);
        Assert.Equal("uncaught_exception", fatal.Properties["origin"]);
        var unknown = client.CaptureError(new ArgumentException("başka"), "window_onerror");
        Assert.Equal("manual", unknown!.Properties["origin"]);
        // Fırlatılmamış istisnada çerçeve yok: temel rakamsız mesajdır.
        Assert.Equal(
            ErrorRules.Build(new KeyNotFoundException("sipariş 123 yok"))["fingerprint"],
            ErrorRules.Build(new KeyNotFoundException("sipariş 456 yok"))["fingerprint"]);
    }

    [Fact]
    public void Sinirlayici_toplam_ve_ornekleme()
    {
        var limiter = new ErrorLimiter(1, () => 0.5);
        Assert.Equal(20, Enumerable.Range(0, 40).Count(i => limiter.Allow(i.ToString("x16"))));
        Assert.False(new ErrorLimiter(0.25, () => 0.5).Allow("a"));
        Assert.True(new ErrorLimiter(0.75, () => 0.5).Allow("a"));
    }

    [Fact]
    public void Temizlik_ve_ozet_vektorleri()
    {
        // fnv1a64("|") — Go ve Python SDK testlerindeki vektörle aynı.
        Assert.Equal("af63f14c8602103b", ErrorRules.Fnv1a64("|"));
        Assert.Equal("sürüm 1.4.2 tamam", ErrorRules.Scrub("  sürüm 1.4.2   tamam "));
        Assert.Equal("UnsupportedOperationExceptionHandler", ErrorRules.Scrub("UnsupportedOperationExceptionHandler"));
        Assert.Equal(200, ErrorRules.Scrub(new string('ş', 300)).Length);
    }

    [Fact]
    public async Task InstallCode_yalniz_ilk_olaya_eklenir()
    {
        var handler = new Recorder();
        var client = Client(handler, new Consent(true), o => o.InstallCode = "  7K3M-9QX2-PR  ");
        Assert.NotNull(client.Track("app_open"));
        Assert.NotNull(client.Track("screen_view"));
        await client.FlushAsync();
        Assert.Equal("7K3M-9QX2-PR", handler.Event(0).GetProperty("properties").GetProperty("fr_install_code").GetString());
        Assert.False(handler.Event(1).TryGetProperty("properties", out var second) && second.TryGetProperty("fr_install_code", out _));
    }

    [Theory]
    [InlineData("SHORT")]
    [InlineData("ILLEGAL-OUI-CODE")]
    [InlineData("12345678901234567")]
    [InlineData("kod/../x1234")]
    public async Task Gecersiz_InstallCode_yok_sayilir(string code)
    {
        var handler = new Recorder();
        var client = Client(handler, new Consent(true), o => o.InstallCode = code);
        Assert.NotNull(client.Track("app_open"));
        await client.FlushAsync();
        Assert.False(handler.Event(0).TryGetProperty("properties", out var props) && props.TryGetProperty("fr_install_code", out _));
    }

    [Fact]
    public async Task InstallCode_izin_gelene_kadar_bekler()
    {
        var handler = new Recorder();
        var client = Client(handler, null, o => o.InstallCode = "ABCDEFGHJK");
        Assert.Null(client.Track("app_open"));
        client.SetConsent(new Consent(true));
        Assert.NotNull(client.Track("app_open"));
        await client.FlushAsync();
        Assert.Equal("ABCDEFGHJK", handler.Event(0).GetProperty("properties").GetProperty("fr_install_code").GetString());
    }
}
