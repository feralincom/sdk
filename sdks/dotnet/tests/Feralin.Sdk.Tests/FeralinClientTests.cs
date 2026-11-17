using System.Net;
using System.Text;
using System.Text.Json;
using Xunit;

namespace Feralin.Tests;

/// <summary>Sahte HTTP işleyicisiyle SDK davranışı. Gerçek toplayıcı testi scripts/sdk-e2e/run.mjs içindedir.</summary>
public class FeralinClientTests
{
    private const string Key = "pk_test_dotnet_unit_0001";
    private const string CollectUrl = "http://collector.test";
    private static readonly Consent Granted = new(true);

    private sealed record Call(HttpRequestMessage Request, string Body)
    {
        public JsonElement Json => JsonDocument.Parse(Body).RootElement;
        public string Header(string name) => Request.Headers.GetValues(name).Single();
        public string[] EventIds => Json.GetProperty("events").EnumerateArray().Select(e => e.GetProperty("event_id").GetString()!).ToArray();
    }

    private sealed class FakeHandler : HttpMessageHandler
    {
        private readonly Queue<Func<HttpResponseMessage>> _responses = new();
        public List<Call> Calls { get; } = new();

        public FakeHandler Respond(HttpStatusCode status, string body = "{\"batch_id\":\"b1\",\"accepted\":1,\"rejected\":0}", int? retryAfter = null)
        {
            _responses.Enqueue(() =>
            {
                var response = new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
                if (retryAfter is { } seconds)
                {
                    response.Headers.TryAddWithoutValidation("Retry-After", seconds.ToString());
                }
                return response;
            });
            return this;
        }

        public FakeHandler Fail()
        {
            _responses.Enqueue(() => throw new HttpRequestException("ağ yok"));
            return this;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
            Calls.Add(new Call(request, body));
            if (_responses.TryDequeue(out var next))
            {
                return next();
            }
            return new HttpResponseMessage(HttpStatusCode.Accepted) { Content = new StringContent("{\"batch_id\":\"bx\",\"accepted\":1,\"rejected\":0}") };
        }
    }

    private static FeralinClient Client(FakeHandler handler, Consent? consent = null, Action<FeralinOptions>? configure = null, Func<DateTimeOffset>? now = null, Func<double>? random = null)
    {
        var options = new FeralinOptions { ProjectKey = Key, CollectUrl = CollectUrl, FlushInterval = TimeSpan.Zero, HttpHandler = handler, Consent = consent ?? Granted };
        configure?.Invoke(options);
        return new FeralinClient(options, now ?? (() => DateTimeOffset.UtcNow), random ?? (() => 1.0));
    }

    private static Dictionary<string, object?> Props(params (string Key, object? Value)[] pairs) => pairs.ToDictionary(p => p.Key, p => p.Value);

    [Theory]
    [InlineData("sk_live_12345678", CollectUrl, "gizli anahtar")]
    [InlineData("abc_12345678", CollectUrl, "pk_")]
    [InlineData(Key, "ftp://x", "CollectUrl")]
    [InlineData(Key, "yol", "CollectUrl")]
    public void Yapilandirma_hatasi_kurucuda_firlar(string key, string url, string message)
    {
        var ex = Assert.Throws<ArgumentException>(() => new FeralinClient(new FeralinOptions { ProjectKey = key, CollectUrl = url }));
        Assert.Contains(message, ex.Message);
    }

    [Fact]
    public async Task Izin_yoksa_olay_uretilmez_ve_istek_yapilmaz()
    {
        var handler = new FakeHandler();
        await using var client = new FeralinClient(new FeralinOptions { ProjectKey = Key, CollectUrl = CollectUrl, FlushInterval = TimeSpan.Zero, HttpHandler = handler });
        Assert.Null(client.Track("order_completed"));
        Assert.Equal(0, (await client.FlushAsync()).Sent);
        Assert.Empty(handler.Calls);
    }

    [Fact]
    public void Olay_bazli_izin_varsayilani_asar_acik_ret_asilamaz()
    {
        var client = Client(new FakeHandler(), new Consent(false));
        Assert.NotNull(client.Track("a", null, new TrackOptions { Consent = Granted }));
        client.OptOut();
        Assert.Equal(0, client.GetStatus().Queued);
        Assert.Null(client.Track("a", null, new TrackOptions { Consent = Granted }));
        client.SetConsent(Granted);
        Assert.NotNull(client.Track("a"));
    }

    [Fact]
    public void Fr_click_yalniz_reklam_izniyle_gider()
    {
        var client = Client(new FakeHandler());
        var props = Props(("fr_click", "x"), ("keep", 1));
        Assert.False(client.Track("a", props)!.Properties.ContainsKey("fr_click"));
        Assert.False(client.Track("a", props, new TrackOptions { Consent = new Consent(true, false) })!.Properties.ContainsKey("fr_click"));
        Assert.True(client.Track("a", props, new TrackOptions { Consent = new Consent(true, true) })!.Properties.ContainsKey("fr_click"));
    }

    [Fact]
    public async Task TrackRevenue_sozlesmesi_verified_duser_gecersiz_girdi_olay_uretmez()
    {
        var handler = new FakeHandler();
        var client = Client(handler);
        var tracked = client.TrackRevenue(new RevenueInput("ord_1", 4999, "TRY")
        {
            ProductId = "pro",
            PurchaseType = PurchaseType.SubscriptionStart,
            Receipt = new Receipt(ReceiptProvider.Stripe, "tok_1"),
            Properties = Props(("verified", true), ("receipt_digest", "x"), ("plan", "pro")),
        }, new TrackOptions { UserId = "user_42" });
        Assert.NotNull(tracked);
        Assert.Equal(RevenueRules.EventName, tracked!.EventName);
        Assert.Equal("ord_1", tracked.Properties["transaction_id"]);
        Assert.Equal(4999L, tracked.Properties["amount_minor"]);
        Assert.Equal("TRY", tracked.Properties["currency"]);
        Assert.Equal(1, tracked.Properties["quantity"]);
        Assert.Equal("subscription_start", tracked.Properties["purchase_type"]);
        Assert.Equal("pro", tracked.Properties["plan"]);
        Assert.False(tracked.Properties.ContainsKey("verified"));
        Assert.False(tracked.Properties.ContainsKey("receipt_digest"));
        var result = await client.FlushAsync();
        Assert.Equal(202, result.Status);
        var wire = handler.Calls.Single().Json.GetProperty("events")[0];
        Assert.Equal("feralin_purchase", wire.GetProperty("event_name").GetString());
        Assert.Equal("user_42", wire.GetProperty("user_id").GetString());
        Assert.False(wire.TryGetProperty("verified", out _));
        var props = wire.GetProperty("properties");
        Assert.Equal(4999, props.GetProperty("amount_minor").GetInt64());
        Assert.Equal("stripe", props.GetProperty("receipt").GetProperty("provider").GetString());
        Assert.False(props.TryGetProperty("verified", out _));

        foreach (var bad in new[]
        {
            new RevenueInput("", 1, "TRY"),
            new RevenueInput("t", -1, "TRY"),
            new RevenueInput("t", RevenueRules.MaxAmountMinor + 1, "TRY"),
            new RevenueInput("t", 1, "try"),
            new RevenueInput("t", 1, "TRY") { Quantity = -1 },
            new RevenueInput("t", 1, "TRY") { PurchaseType = (PurchaseType)99 },
            new RevenueInput("t", 1, "TRY") { Receipt = new Receipt(ReceiptProvider.Apple, "") },
            new RevenueInput("t", 1, "TRY") { PurchaseType = PurchaseType.SubscriptionCancel },
        })
        {
            Assert.Null(client.TrackRevenue(bad));
        }
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public async Task Tel_bicimi_utp_v1_ve_anahtar_yalniz_baslikta()
    {
        var handler = new FakeHandler();
        var client = Client(handler);
        client.Identify("user_42");
        client.Track("order_completed", Props(("order_id", "ord_1"), ("geçersiz anahtar", 1)), new TrackOptions
        {
            AnonymousId = "anon_1",
            SessionId = "sess_1",
            OccurredAt = new DateTimeOffset(2026, 11, 3, 10, 0, 0, TimeSpan.Zero),
            Context = new EventContext
            {
                PageUrl = "https://shop.example/odeme?token=gizli&utm_source=ads#x",
                Referrer = "https://google.example/search?q=gizli",
                PageTitle = "Ödeme",
                Locale = "tr-TR",
                Timezone = "Europe/Istanbul",
                AppVersion = "1.0.0",
            },
        });
        var result = await client.FlushAsync();
        Assert.Equal(202, result.Status);
        Assert.Equal("bx", result.BatchId);

        var call = handler.Calls.Single();
        Assert.Equal($"{CollectUrl}/v1/batch", call.Request.RequestUri!.ToString());
        Assert.Equal(Key, call.Header("x-feralin-project-key"));
        Assert.DoesNotContain(Key, call.Body);
        Assert.DoesNotContain("gizli", call.Body);
        var root = call.Json;
        Assert.Equal(JsonValueKind.String, root.GetProperty("sent_at").ValueKind);
        var e = root.GetProperty("events")[0];
        Assert.Equal("dotnet", e.GetProperty("platform").GetString());
        Assert.Equal(1, e.GetProperty("schema_version").GetInt32());
        Assert.Equal("feralin-dotnet", e.GetProperty("sdk").GetProperty("name").GetString());
        Assert.Equal("2026-11-03T10:00:00.000Z", e.GetProperty("occurred_at").GetString());
        Assert.Equal(26, e.GetProperty("event_id").GetString()!.Length);
        Assert.Equal("user_42", e.GetProperty("user_id").GetString());
        Assert.True(e.GetProperty("consent").GetProperty("analytics").GetBoolean());
        Assert.False(e.GetProperty("consent").TryGetProperty("advertising", out _));
        Assert.Equal("https://shop.example/odeme", e.GetProperty("context").GetProperty("page_url").GetString());
        Assert.Equal("https://google.example", e.GetProperty("context").GetProperty("referrer").GetString());
        Assert.Equal("ads", e.GetProperty("properties").GetProperty("utm_source").GetString());
        Assert.False(e.GetProperty("properties").TryGetProperty("geçersiz anahtar", out _));
        foreach (var banned in new[] { "tenant_id", "project_id", "verified" })
        {
            Assert.False(e.TryGetProperty(banned, out _));
        }
    }

    [Fact]
    public void Gecersiz_girdi_firlatmaz()
    {
        var warnings = new List<string>();
        var client = Client(new FakeHandler(), configure: o => o.Log = (_, m) => warnings.Add(m));
        Assert.Null(client.Track("Geçersiz Ad"));
        Assert.Null(client.Track("a", null, new TrackOptions { UserId = new string('x', 129) }));
        var loop = new Dictionary<string, object?>();
        loop["self"] = loop;
        Assert.Null(client.Track("a", Props(("loop", loop))));
        Assert.Null(client.Track("a", Props(("nan", double.NaN))));
        Assert.Equal(0, client.GetStatus().Queued);
        Assert.True(warnings.Count >= 3);
    }

    [Fact]
    public async Task Idempotency_anahtari_tum_event_id_ozetinden_ve_diger_sdklarla_ayni()
    {
        Assert.Equal("8f95d6b736d56c98-2", Idempotency.KeyFor(new[] { "01JC0000000000000000000002", "01JC0000000000000000000001" }));
        var handler = new FakeHandler();
        var client = Client(handler);
        var a = client.Track("a")!;
        var b = client.Track("b")!;
        await client.FlushAsync();
        Assert.Equal(Idempotency.KeyFor(new[] { a.EventId, b.EventId }), handler.Calls[0].Header("Idempotency-Key"));
    }

    [Fact]
    public async Task Sonucu_bilinmeyen_batch_ayni_icerik_ve_anahtarla_denenir()
    {
        var handler = new FakeHandler().Fail().Respond(HttpStatusCode.ServiceUnavailable).Respond(HttpStatusCode.Accepted).Respond(HttpStatusCode.Accepted);
        var client = Client(handler);
        var first = client.Track("a")!;
        var r1 = await client.FlushAsync();
        Assert.Equal((0, 1), (r1.Status, r1.Retained));
        var second = client.Track("b")!;
        var r2 = await client.FlushAsync();
        Assert.Equal((503, 2), (r2.Status, r2.Retained));
        var r3 = await client.FlushAsync();
        Assert.Equal((0, 2), (r3.Retained, r3.Sent));
        Assert.Equal(handler.Calls[0].Header("Idempotency-Key"), handler.Calls[1].Header("Idempotency-Key"));
        Assert.Equal(handler.Calls[1].Header("Idempotency-Key"), handler.Calls[2].Header("Idempotency-Key"));
        Assert.Equal(new[] { first.EventId }, handler.Calls[2].EventIds);
        Assert.Equal(new[] { second.EventId }, handler.Calls[3].EventIds);
    }

    [Fact]
    public async Task Kalici_4xx_atar_429_tutar_ve_retry_after_suresince_istek_yapmaz()
    {
        var now = new DateTimeOffset(2026, 11, 3, 10, 0, 0, TimeSpan.Zero);
        var handler = new FakeHandler()
            .Respond(HttpStatusCode.Unauthorized, "{\"title\":\"Proje anahtarı geçersiz\"}")
            .Respond(HttpStatusCode.TooManyRequests, "{}", retryAfter: 60)
            .Respond(HttpStatusCode.Accepted);
        var client = Client(handler, now: () => now);
        client.Track("a");
        var rejected = await client.FlushAsync();
        Assert.Equal((401, 1, 0), (rejected.Status, rejected.Rejected, rejected.Retained));
        client.Track("b");
        var limited = await client.FlushAsync();
        Assert.Equal((429, 1), (limited.Status, limited.Retained));
        var deferred = await client.FlushAsync();
        Assert.Equal((0, 1), (deferred.Sent, deferred.Retained));
        Assert.Equal(2, handler.Calls.Count);
        now = now.AddSeconds(61);
        Assert.Equal(202, (await client.FlushAsync()).Status);
    }

    [Fact]
    public async Task Geri_cekilme_ustel_jitterli_ve_sinirli()
    {
        var now = new DateTimeOffset(2026, 11, 3, 10, 0, 0, TimeSpan.Zero);
        var handler = new FakeHandler();
        for (var i = 0; i < 8; i++)
        {
            handler.Fail();
        }
        var client = Client(handler, now: () => now);
        client.Track("a");
        var delays = new List<double>();
        for (var i = 0; i < 8; i++)
        {
            await client.FlushAsync();
            delays.Add(client.GetStatus().Backoff.TotalMilliseconds);
        }
        Assert.Equal(new double[] { 1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000 }, delays);

        var half = Client(new FakeHandler().Fail(), now: () => now, random: () => 0);
        half.Track("a");
        await half.FlushAsync();
        Assert.Equal(500, half.GetStatus().Backoff.TotalMilliseconds);
    }

    [Fact]
    public async Task Kuyruk_siniri_en_eskiyi_atar_ve_500_ust_siniri_uygulanir()
    {
        var handler = new FakeHandler();
        var client = Client(handler, configure: o => { o.QueueLimit = 3; o.BatchSize = 2; });
        var ids = new[] { "a", "b", "c", "d" }.Select(n => client.Track(n)!.EventId).ToArray();
        Assert.Equal(1, client.GetStatus().Dropped);
        await client.FlushAsync();
        Assert.Equal(2, handler.Calls[0].EventIds.Length);
        Assert.Equal(ids.Skip(1), handler.Calls.SelectMany(c => c.EventIds));

        var large = new FakeHandler();
        var capped = Client(large, configure: o => { o.QueueLimit = 10_000; o.BatchSize = 10_000; });
        for (var i = 0; i < 501; i++)
        {
            capped.Track("a");
        }
        await capped.FlushAsync();
        Assert.Equal(500, large.Calls[0].EventIds.Length);
        Assert.Single(large.Calls[1].EventIds);
    }

    [Fact]
    public async Task Govde_900_kb_ile_bolunur_tek_basina_asan_olay_atilir()
    {
        var handler = new FakeHandler();
        var client = Client(handler);
        client.Track("a", Props(("blob", new string('x', 500 * 1024))));
        client.Track("b", Props(("blob", new string('x', 500 * 1024))));
        Assert.Null(client.Track("c", Props(("blob", new string('x', 1024 * 1024)))));
        await client.FlushAsync();
        Assert.Equal(2, handler.Calls.Count);
        Assert.All(handler.Calls, c => Assert.True(Encoding.UTF8.GetByteCount(c.Body) < 1024 * 1024));
    }

    [Fact]
    public async Task Close_kalani_gonderir_sonra_olay_uretilmez_ikinci_cagri_guvenli()
    {
        var handler = new FakeHandler();
        var client = Client(handler);
        client.Track("a");
        Assert.Equal(202, (await client.CloseAsync()).Status);
        Assert.Single(handler.Calls);
        Assert.Null(client.Track("b"));
        Assert.Equal(0, (await client.CloseAsync()).Sent);
        await client.DisposeAsync();
    }

    [Fact]
    public async Task Arka_plan_gondericisi_kuyrugu_bosaltir()
    {
        var handler = new FakeHandler();
        var client = Client(handler, configure: o => o.FlushInterval = TimeSpan.FromMilliseconds(10));
        client.Track("a");
        for (var i = 0; i < 200 && handler.Calls.Count == 0; i++)
        {
            await Task.Delay(10);
        }
        Assert.Single(handler.Calls);
        await client.DisposeAsync();
    }

    [Fact]
    public async Task Sir_loglanmaz()
    {
        var lines = new List<string>();
        var handler = new FakeHandler().Respond(HttpStatusCode.Unauthorized, "{\"title\":\"Geçersiz\",\"detail\":\"gizli_govde\"}").Fail().Respond(HttpStatusCode.InternalServerError);
        var client = Client(handler, configure: o => o.Log = (_, m) => lines.Add(m));
        client.Identify("kullanici_gizli");
        client.Track("a", Props(("deger", "ozellik_gizli")));
        await client.FlushAsync();
        client.Track("b", Props(("deger", "ozellik_gizli")));
        await client.FlushAsync();
        await client.FlushAsync();
        var output = string.Join("\n", lines);
        Assert.NotEmpty(lines);
        foreach (var secret in new[] { Key, "ozellik_gizli", "kullanici_gizli", "gizli_govde" })
        {
            Assert.DoesNotContain(secret, output);
        }
        Assert.DoesNotContain(Key, client.GetStatus().ToString());
    }

    [Fact]
    public async Task Kapatilmis_istemcide_cagrilar_firlatmaz()
    {
        var client = Client(new FakeHandler());
        await client.DisposeAsync();
        Assert.Null(client.Track("a"));
        Assert.Equal(0, (await client.FlushAsync()).Sent);
        await client.DisposeAsync();
    }

    [Fact]
    public void Logger_hatasi_uygulamaya_yansimaz()
    {
        var client = Client(new FakeHandler(), configure: o => o.Log = (_, _) => throw new InvalidOperationException("logger"));
        Assert.Null(client.Track("Geçersiz Ad"));
    }
}
