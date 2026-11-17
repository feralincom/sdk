using System.Globalization;
using System.Text;
using System.Text.Json;
using Feralin.Unity;
using Xunit;

namespace Feralin.Unity.Core.Tests;

/// <summary>Sahte taşıyıcı: yanıtlar sırayla verilir; Defer açıksa yanıt elle tetiklenene kadar bekler.</summary>
internal sealed class FakeTransport : IFeralinTransport
{
    public List<TransportRequest> Requests { get; } = new();
    public Queue<TransportResponse> Responses { get; } = new();
    public List<Action<TransportResponse>> Pending { get; } = new();
    public bool Defer { get; set; }
    public Exception Throw { get; set; }
    public bool CallTwice { get; set; }

    public void Send(TransportRequest request, Action<TransportResponse> onComplete)
    {
        Requests.Add(request);
        if (Throw != null)
        {
            throw Throw;
        }
        if (Defer)
        {
            Pending.Add(onComplete);
            return;
        }
        var response = Responses.Count > 0 ? Responses.Dequeue() : Ack(request);
        onComplete(response);
        if (CallTwice)
        {
            onComplete(response);
        }
    }

    public void Complete(int index, TransportResponse response) => Pending[index](response);

    public static TransportResponse Ack(TransportRequest request)
    {
        var count = JsonDocument.Parse(request.Body).RootElement.GetProperty("events").GetArrayLength();
        return new TransportResponse(202, "{\"batch_id\":\"b1\",\"accepted\":" + count + ",\"rejected\":0}");
    }
}

/// <summary>Bellek içi kimlik deposu; PlayerPrefs yerine geçer.</summary>
internal sealed class MemoryIdStore : IAnonymousIdStore
{
    public string Value { get; set; }
    public bool ThrowOnAccess { get; set; }

    public string Load() => ThrowOnAccess ? throw new InvalidOperationException("ana iş parçacığı değil") : Value;

    public void Save(string anonymousId)
    {
        if (ThrowOnAccess)
        {
            throw new InvalidOperationException("ana iş parçacığı değil");
        }
        Value = anonymousId;
    }

    public void Clear()
    {
        if (ThrowOnAccess)
        {
            throw new InvalidOperationException("ana iş parçacığı değil");
        }
        Value = null;
    }
}

public class FeralinClientTests
{
    private const string Key = "pk_test_unity_key_0001";
    private DateTimeOffset _now = new(2026, 11, 3, 10, 0, 0, TimeSpan.Zero);
    private readonly List<string> _logs = new();
    private readonly FakeTransport _transport = new();

    private FeralinClient Make(Consent consent = null, Action<FeralinOptions> edit = null)
    {
        var options = new FeralinOptions
        {
            ProjectKey = Key,
            CollectUrl = "https://collect.example.test/",
            Transport = _transport,
            Consent = consent,
            Clock = () => _now,
            Random = () => 1.0,
            Log = (_, message) => _logs.Add(message),
        };
        edit?.Invoke(options);
        return new FeralinClient(options);
    }

    private static Dictionary<string, object> Props(params (string Key, object Value)[] items) =>
        items.ToDictionary(item => item.Key, item => item.Value);

    private static JsonElement Event(TransportRequest request, int index = 0) =>
        JsonDocument.Parse(request.Body).RootElement.GetProperty("events")[index];

    private static string Header(TransportRequest request, string name) => request.Headers[name];

    private static FlushResult Flush(FeralinClient client)
    {
        FlushResult result = null;
        client.Flush(r => result = r);
        Assert.NotNull(result);
        return result;
    }

    [Theory]
    [InlineData("sk_live_secret_0001", "https://c.example.test")]
    [InlineData("nope", "https://c.example.test")]
    [InlineData("pk_1", "https://c.example.test")]
    [InlineData("", "https://c.example.test")]
    [InlineData(Key, "ftp://c.example.test")]
    [InlineData(Key, "relative/path")]
    [InlineData(Key, "")]
    public void ConfigurationErrorsThrowInConstructorWithoutLeakingKey(string key, string url)
    {
        var error = Assert.Throws<ArgumentException>(() => new FeralinClient(new FeralinOptions { ProjectKey = key, CollectUrl = url, Transport = _transport }));
        if (key.Length > 0)
        {
            Assert.DoesNotContain(key, error.Message);
        }
    }

    [Fact]
    public void TransportIsRequired()
    {
        Assert.Throws<ArgumentException>(() => new FeralinClient(new FeralinOptions { ProjectKey = Key, CollectUrl = "https://c.example.test" }));
    }

    [Fact]
    public void InstallCodeGoesOnlyOnFirstConsentedEvent()
    {
        var waiting = Make(null, o => o.InstallCode = " K7M2-Q9XR4 ");
        Assert.Null(waiting.Track("level_start"));
        waiting.SetConsent(new Consent(true));
        var first = waiting.Track("level_start", new Dictionary<string, object> { ["level"] = "1" });
        Assert.NotNull(first);
        Assert.Equal("K7M2-Q9XR4", first.Properties["fr_install_code"]);
        var second = waiting.Track("level_complete");
        Assert.False(second.Properties != null && second.Properties.ContainsKey("fr_install_code"));
        var bad = Make(new Consent(true), o => o.InstallCode = "x;DROP");
        var ev = bad.Track("level_start");
        Assert.False(ev.Properties != null && ev.Properties.ContainsKey("fr_install_code"));
    }

    [Fact]
    public void WithoutConsentNoEventAndNoRequest()
    {
        var client = Make();
        Assert.Null(client.Track("level_start"));
        var result = Flush(client);
        Assert.Equal(0, result.Sent);
        Assert.Empty(_transport.Requests);
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public void WireEventMatchesUtpV1()
    {
        var client = Make(new Consent(true, true));
        client.Identify("player_1");
        client.SetAnonymousId("anon_1");
        client.SetSessionId("session_1");
        var tracked = client.Track("level_start", Props(("level_id", "w1"), ("hard", true)));
        Assert.NotNull(tracked);
        Assert.Equal(26, tracked.EventId.Length);
        Flush(client);

        var request = Assert.Single(_transport.Requests);
        Assert.Equal("https://collect.example.test/v1/batch", request.Url);
        Assert.Equal(Key, Header(request, "X-Feralin-Project-Key"));
        Assert.Equal("application/json", Header(request, "Content-Type"));
        Assert.Equal(Idempotency.KeyFor(new[] { tracked.EventId }), Header(request, "Idempotency-Key"));
        var root = JsonDocument.Parse(request.Body).RootElement;
        Assert.Equal("2026-11-03T10:00:00.000Z", root.GetProperty("sent_at").GetString());
        var e = root.GetProperty("events")[0];
        Assert.Equal(tracked.EventId, e.GetProperty("event_id").GetString());
        Assert.Equal("level_start", e.GetProperty("event_name").GetString());
        Assert.Equal("2026-11-03T10:00:00.000Z", e.GetProperty("occurred_at").GetString());
        Assert.Equal("unity", e.GetProperty("platform").GetString());
        Assert.Equal(1, e.GetProperty("schema_version").GetInt32());
        Assert.Equal("feralin-unity", e.GetProperty("sdk").GetProperty("name").GetString());
        Assert.True(e.GetProperty("consent").GetProperty("analytics").GetBoolean());
        Assert.True(e.GetProperty("consent").GetProperty("advertising").GetBoolean());
        Assert.Equal("player_1", e.GetProperty("user_id").GetString());
        Assert.Equal("anon_1", e.GetProperty("anonymous_id").GetString());
        Assert.Equal("session_1", e.GetProperty("session_id").GetString());
        Assert.Equal("w1", e.GetProperty("properties").GetProperty("level_id").GetString());
        Assert.False(e.TryGetProperty("verified", out _));
        Assert.False(e.TryGetProperty("tenant_id", out _));
    }

    [Fact]
    public void FrClickRemovedWithoutAdvertisingConsent()
    {
        var client = Make(new Consent(true));
        var tracked = client.Track("level_start", Props(("fr_click", "clk_1"), ("a", 1)));
        Assert.False(tracked.Properties.ContainsKey("fr_click"));
        Flush(client);
        Assert.False(Event(_transport.Requests[0]).GetProperty("properties").TryGetProperty("fr_click", out _));
    }

    [Fact]
    public void FrClickKeptWithAdvertisingConsent()
    {
        var client = Make(new Consent(true, true));
        client.Track("level_start", Props(("fr_click", "clk_1")));
        Flush(client);
        Assert.Equal("clk_1", Event(_transport.Requests[0]).GetProperty("properties").GetProperty("fr_click").GetString());
    }

    [Theory]
    [InlineData("verified")]
    [InlineData("Verified")]
    [InlineData("tenant_id")]
    [InlineData("project_id")]
    public void ServerOnlyPropertiesNeverLeaveTheClient(string name)
    {
        var client = Make(new Consent(true));
        var tracked = client.Track("iap_purchase", Props((name, true), ("a", 1)));
        Assert.False(tracked.Properties.ContainsKey(name));
        Assert.Contains(_logs, line => line.Contains("özellik çıkarıldı"));
    }

    [Theory]
    [InlineData("LevelStart")]
    [InlineData("1level")]
    [InlineData("")]
    [InlineData(null)]
    public void InvalidEventNameReturnsNull(string name)
    {
        Assert.Null(Make(new Consent(true)).Track(name));
    }

    [Fact]
    public void InvalidPropertyKeysAreRemoved()
    {
        var tracked = Make(new Consent(true)).Track("a", Props(("ok_key", 1), ("bad-key", 2), ("9bad", 3)));
        Assert.Equal(new[] { "ok_key" }, tracked.Properties.Keys.ToArray());
    }

    [Fact]
    public void PropertyLimitIsApplied()
    {
        var many = Enumerable.Range(0, 150).ToDictionary(i => "k" + i, i => (object)i);
        Assert.Equal(100, Make(new Consent(true)).Track("a", many).Properties.Count);
    }

    [Fact]
    public void TooLongIdentifiersDoNotCrash()
    {
        var client = Make(new Consent(true));
        Assert.Null(client.Track("a", null, new TrackOptions { UserId = new string('u', 129) }));
        client.Identify(new string('u', 129));
        var e = client.Track("a");
        Flush(client);
        Assert.False(Event(_transport.Requests[0]).TryGetProperty("user_id", out _));
        Assert.NotNull(e);
    }

    [Fact]
    public void BadValuesReturnNullInsteadOfThrowing()
    {
        var client = Make(new Consent(true));
        var cycle = new Dictionary<string, object>();
        cycle["self"] = cycle;
        Assert.Null(client.Track("a", Props(("cycle", cycle))));
        Assert.Null(client.Track("a", Props(("nan", double.NaN))));
        Assert.Null(client.Track("a", Props(("inf", float.PositiveInfinity))));
        Assert.Null(client.Track("a", Props(("object", new object()))));
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public void ValuesSerializeInvariantlyAndEscape()
    {
        var previous = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = new CultureInfo("tr-TR");
        try
        {
            var client = Make(new Consent(true));
            client.Track("a", Props(
                ("d", 1.5),
                ("f", 2.5f),
                ("m", 19.99m),
                ("text", "İşğüöç \"tırnak\" \\ \n\u0001"),
                ("list", new object[] { 1, "x", null, true }),
                ("map", new Dictionary<string, object> { ["n"] = 7L })));
            Flush(client);
            var props = Event(_transport.Requests[0]).GetProperty("properties");
            Assert.Equal(1.5, props.GetProperty("d").GetDouble());
            Assert.Equal(2.5, props.GetProperty("f").GetDouble());
            Assert.Equal(19.99m, props.GetProperty("m").GetDecimal());
            Assert.Equal("İşğüöç \"tırnak\" \\ \n\u0001", props.GetProperty("text").GetString());
            Assert.Equal(4, props.GetProperty("list").GetArrayLength());
            Assert.Equal(7, props.GetProperty("map").GetProperty("n").GetInt64());
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    [Theory]
    [InlineData("4b321ae683d5ab40-1", "01ARZ3NDEKTSV4RRFFQ69G5FAV")]
    [InlineData("de0c7683bd7be052-2", "01ARZ3NDEKTSV4RRFFQ69G5FAW", "01ARZ3NDEKTSV4RRFFQ69G5FAV")]
    public void IdempotencyKeyMatchesPythonSdk(string expected, params string[] ids)
    {
        Assert.Equal(expected, Idempotency.KeyFor(ids));
    }

    [Fact]
    public void AcknowledgementIsParsedAndQueueEmptied()
    {
        _transport.Responses.Enqueue(new TransportResponse(202, "{\"batch_id\":\"batch_9\",\"accepted\":2,\"rejected\":1,\"rejected_reasons\":{\"consent_denied\":1}}"));
        var client = Make(new Consent(true));
        client.Track("a");
        client.Track("b");
        client.Track("c");
        var result = Flush(client);
        Assert.Equal((3, 2, 1, 202, 0, "batch_9"), (result.Sent, result.Accepted, result.Rejected, result.Status, result.Retained, result.BatchId));
    }

    [Fact]
    public void UnreadableAcknowledgementStillCountsAsSent()
    {
        _transport.Responses.Enqueue(new TransportResponse(202, "<html>"));
        var client = Make(new Consent(true));
        client.Track("a");
        var result = Flush(client);
        Assert.Equal((1, 1, 0), (result.Accepted, result.Sent, result.Retained));
    }

    [Theory]
    [InlineData(401)]
    [InlineData(403)]
    public void AuthFailureDiscardsWholeQueueWithoutCrashing(int status)
    {
        _transport.Responses.Enqueue(new TransportResponse(status, "{\"title\":\"unauthorized\"}"));
        var client = Make(new Consent(true), o => o.BatchSize = 2);
        for (var i = 0; i < 5; i++)
        {
            client.Track("a");
        }
        var result = Flush(client);
        Assert.Equal((status, 5, 0), (result.Status, result.Rejected, result.Retained));
        Assert.Single(_transport.Requests);
        Assert.Equal(0, client.GetStatus().Backoff.Ticks);
        Assert.DoesNotContain(_logs, line => line.Contains(Key));
    }

    [Fact]
    public void OtherClientErrorDropsOnlyThatBatch()
    {
        _transport.Responses.Enqueue(new TransportResponse(400, "not json"));
        var client = Make(new Consent(true), o => o.BatchSize = 1);
        client.Track("a");
        client.Track("b");
        var result = Flush(client);
        Assert.Equal((2, 1, 1, 0), (result.Sent, result.Rejected, result.Accepted, result.Retained));
        Assert.Contains(_logs, line => line.Contains("problem+json yok"));
    }

    [Fact]
    public void NetworkErrorKeepsBatchAndRetriesWithSameKeyEvenAfterNewEvents()
    {
        _transport.Responses.Enqueue(TransportResponse.NetworkError);
        var client = Make(new Consent(true));
        var first = client.Track("a");
        var failed = Flush(client);
        Assert.Equal((0, 1), (failed.Status, failed.Retained));
        var second = client.Track("b");
        Assert.Equal(2, client.GetStatus().Queued);

        var result = Flush(client);
        Assert.Equal((202, 0), (result.Status, result.Retained));
        Assert.Equal(3, _transport.Requests.Count);
        Assert.Equal(Header(_transport.Requests[0], "Idempotency-Key"), Header(_transport.Requests[1], "Idempotency-Key"));
        Assert.Equal(1, JsonDocument.Parse(_transport.Requests[1].Body).RootElement.GetProperty("events").GetArrayLength());
        Assert.Equal(first.EventId, Event(_transport.Requests[1]).GetProperty("event_id").GetString());
        Assert.Equal(second.EventId, Event(_transport.Requests[2]).GetProperty("event_id").GetString());
    }

    [Theory]
    [InlineData(500)]
    [InlineData(503)]
    [InlineData(429)]
    public void TemporaryStatusKeepsEvents(int status)
    {
        _transport.Responses.Enqueue(new TransportResponse(status));
        var client = Make(new Consent(true));
        client.Track("a");
        var result = Flush(client);
        Assert.Equal((status, 1, 0), (result.Status, result.Retained, result.Rejected));
    }

    [Fact]
    public void ThrowingTransportKeepsEventsAndDoesNotCrash()
    {
        _transport.Throw = new InvalidOperationException("ana iş parçacığı değil");
        var client = Make(new Consent(true));
        client.Track("a");
        var result = Flush(client);
        Assert.Equal((0, 1), (result.Status, result.Retained));
    }

    [Fact]
    public void DoubleTransportCallbackIsIgnored()
    {
        _transport.CallTwice = true;
        var client = Make(new Consent(true));
        client.Track("a");
        var calls = 0;
        client.Flush(_ => calls++);
        Assert.Equal(1, calls);
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public void BackoffGrowsExponentiallyAndIsCapped()
    {
        var client = Make(new Consent(true));
        client.Track("a");
        var expected = new[] { 1, 2, 4, 8, 16, 30, 30 };
        foreach (var seconds in expected)
        {
            _transport.Responses.Enqueue(TransportResponse.NetworkError);
            Flush(client);
            Assert.Equal(TimeSpan.FromSeconds(seconds), client.GetStatus().Backoff);
        }
    }

    [Fact]
    public void TickRespectsBackoffThenRetries()
    {
        var client = Make(new Consent(true));
        client.Track("a");
        _transport.Responses.Enqueue(TransportResponse.NetworkError);
        _now += TimeSpan.FromSeconds(2);
        client.Tick();
        Assert.Single(_transport.Requests);

        _now += TimeSpan.FromMilliseconds(500);
        client.Tick();
        Assert.Single(_transport.Requests);

        _now += TimeSpan.FromSeconds(2);
        client.Tick();
        Assert.Equal(2, _transport.Requests.Count);
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public void RetryAfterBlocksExplicitFlushUntilExpiry()
    {
        _transport.Responses.Enqueue(new TransportResponse(429, null, "60"));
        var client = Make(new Consent(true));
        client.Track("a");
        Flush(client);
        Assert.Equal(TimeSpan.FromSeconds(60), client.GetStatus().Backoff);

        var blocked = Flush(client);
        Assert.Equal((0, 1), (blocked.Sent, blocked.Retained));
        Assert.Single(_transport.Requests);

        _now += TimeSpan.FromSeconds(61);
        Assert.Equal(202, Flush(client).Status);
    }

    [Fact]
    public void RetryAfterIsCappedAtFiveMinutes()
    {
        _transport.Responses.Enqueue(new TransportResponse(503, null, "86400"));
        var client = Make(new Consent(true));
        client.Track("a");
        Flush(client);
        Assert.Equal(TimeSpan.FromMinutes(5), client.GetStatus().Backoff);
    }

    [Fact]
    public void TickSendsOnIntervalOrFullBatchButNotWhenEmpty()
    {
        var client = Make(new Consent(true), o => o.BatchSize = 2);
        client.Tick();
        _now += TimeSpan.FromSeconds(5);
        client.Tick();
        Assert.Empty(_transport.Requests);

        _now += TimeSpan.FromSeconds(1);
        client.Track("a");
        client.Tick();
        Assert.Single(_transport.Requests);

        client.Track("a");
        client.Tick();
        Assert.Single(_transport.Requests);
        client.Track("b");
        client.Tick();
        Assert.Equal(2, _transport.Requests.Count);
    }

    [Fact]
    public void ZeroIntervalDisablesTick()
    {
        var client = Make(new Consent(true), o => o.FlushInterval = TimeSpan.Zero);
        client.Track("a");
        _now += TimeSpan.FromHours(1);
        client.Tick();
        Assert.Empty(_transport.Requests);
    }

    [Fact]
    public void QueueLimitDropsOldest()
    {
        var client = Make(new Consent(true), o => o.QueueLimit = 2);
        client.Track("a");
        var second = client.Track("b");
        var third = client.Track("c");
        Assert.Equal(1, client.GetStatus().Dropped);
        Flush(client);
        var body = Encoding.UTF8.GetString(_transport.Requests[0].Body);
        Assert.Contains(second.EventId, body);
        Assert.Contains(third.EventId, body);
        Assert.Contains(_logs, line => line.Contains("kuyruk sınırı"));
    }

    [Fact]
    public void BatchesAreSplitAndKeysDiffer()
    {
        var client = Make(new Consent(true), o => o.BatchSize = 2);
        for (var i = 0; i < 5; i++)
        {
            client.Track("a");
        }
        var result = Flush(client);
        Assert.Equal((5, 5, 0), (result.Sent, result.Accepted, result.Retained));
        Assert.Equal(3, _transport.Requests.Count);
        Assert.Equal(3, _transport.Requests.Select(r => Header(r, "Idempotency-Key")).Distinct().Count());
    }

    [Fact]
    public void SynchronousTransportDoesNotGrowStack()
    {
        var client = Make(new Consent(true), o =>
        {
            o.BatchSize = 1;
            o.QueueLimit = 50000;
        });
        for (var i = 0; i < 50000; i++)
        {
            client.Track("a");
        }
        Assert.Equal(50000, Flush(client).Accepted);
    }

    [Fact]
    public void WithdrawingConsentClearsQueueAndStopsEvents()
    {
        var client = Make(new Consent(true));
        client.Track("a");
        client.SetConsent(new Consent(false));
        Assert.Equal(0, client.GetStatus().Queued);
        Assert.Null(client.Track("b"));
        Assert.Equal(0, Flush(client).Sent);
        Assert.Empty(_transport.Requests);
    }

    [Fact]
    public void ConsentWithdrawnDuringRequestDropsPendingBatch()
    {
        _transport.Defer = true;
        var client = Make(new Consent(true));
        client.Track("a");
        FlushResult result = null;
        client.Flush(r => result = r);
        client.OptOut();
        Assert.Equal(0, client.GetStatus().Queued);

        _transport.Complete(0, TransportResponse.NetworkError);
        Assert.Equal(0, result.Retained);
        Assert.Equal(0, client.GetStatus().Queued);
        Assert.Single(_transport.Requests);
    }

    [Fact]
    public void ConsentGrantAppliesToNewEventsOnly()
    {
        var client = Make();
        Assert.Null(client.Track("a"));
        client.SetConsent(new Consent(true));
        Assert.NotNull(client.Track("b"));
        Assert.Equal(1, client.GetStatus().Queued);
    }

    [Fact]
    public void AsyncTransportRunsSingleFlightAndFollowerGetsResult()
    {
        _transport.Defer = true;
        var client = Make(new Consent(true));
        client.Track("a");
        FlushResult first = null, second = null;
        client.Flush(r => first = r);
        client.Track("b");
        client.Flush(r => second = r);
        client.Tick();
        Assert.Single(_transport.Requests);

        _transport.Complete(0, new TransportResponse(202, "{\"accepted\":1}"));
        // İlk tur sıradaki "b" olayını da gönderir; tek istek sürer.
        Assert.Equal(2, _transport.Requests.Count);
        _transport.Complete(1, new TransportResponse(202, "{\"accepted\":1}"));
        Assert.Equal(2, first.Accepted);
        Assert.NotNull(second);
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public void CallbackExceptionDoesNotBreakTheClient()
    {
        var client = Make(new Consent(true));
        client.Track("a");
        client.Flush(_ => throw new InvalidOperationException("oyun hatası"));
        Assert.Equal(0, client.GetStatus().Queued);
        Assert.Contains(_logs, line => line.Contains("geri çağrı"));
    }

    [Fact]
    public void LogCallbackExceptionDoesNotBreakTheClient()
    {
        var client = Make(new Consent(true), o => o.Log = (_, _) => throw new InvalidOperationException());
        Assert.Null(client.Track("BAD"));
        Assert.NotNull(client.Track("ok"));
    }

    [Fact]
    public void CloseFlushesIgnoringRetryAfterAndBlocksNewEvents()
    {
        _transport.Responses.Enqueue(new TransportResponse(429, null, "120"));
        var client = Make(new Consent(true));
        client.Track("a");
        Flush(client);
        FlushResult closed = null;
        client.Close(r => closed = r);
        Assert.Equal((202, 0), (closed.Status, closed.Retained));
        Assert.Null(client.Track("b"));
        client.Tick();

        FlushResult again = null;
        client.Close(r => again = r);
        Assert.Equal(0, again.Sent);
        FlushResult flushed = null;
        client.Flush(r => flushed = r);
        Assert.Equal(0, flushed.Sent);
        Assert.Equal(2, _transport.Requests.Count);
    }

    [Fact]
    public void ResetClearsIdentityAndQueue()
    {
        var client = Make(new Consent(true));
        client.Identify("player_1");
        client.SetAnonymousId("anon_1");
        client.Track("a");
        client.Reset();
        Assert.Equal(0, client.GetStatus().Queued);
        client.Track("b");
        Flush(client);
        var e = Event(_transport.Requests[0]);
        Assert.False(e.TryGetProperty("user_id", out _));
        Assert.False(e.TryGetProperty("anonymous_id", out _));
    }

    [Fact]
    public void ResetRotatesStoredAnonymousIdSoSharedDeviceAccountsAreNotLinked()
    {
        var store = new MemoryIdStore();
        var client = Make(new Consent(true), o => o.AnonymousIdStore = store);
        var first = store.Value;
        Assert.Equal(26, first.Length);
        client.Identify("player_1");
        client.Track("a");
        Flush(client);
        Assert.Equal(first, Event(_transport.Requests[0]).GetProperty("anonymous_id").GetString());

        client.Reset();
        var second = store.Value;
        Assert.Equal(26, second.Length);
        Assert.NotEqual(first, second);
        client.Identify("player_2");
        client.Track("b");
        Flush(client);
        var e = Event(_transport.Requests[1]);
        Assert.Equal(second, e.GetProperty("anonymous_id").GetString());
        Assert.Equal("player_2", e.GetProperty("user_id").GetString());
    }

    [Fact]
    public void WithdrawalDeletesStoredIdAndNextConsentGetsANewOne()
    {
        var store = new MemoryIdStore();
        var client = Make(new Consent(true), o => o.AnonymousIdStore = store);
        var first = store.Value;
        client.SetConsent(new Consent(false));
        Assert.Null(store.Value);
        client.Reset();
        Assert.Null(store.Value);
        client.SetConsent(new Consent(true));
        Assert.Equal(26, store.Value.Length);
        Assert.NotEqual(first, store.Value);
    }

    [Fact]
    public void ConsentKeepsStoredIdAcrossClients()
    {
        var store = new MemoryIdStore { Value = "01JC0000000000000000INSTAL" };
        var client = Make(new Consent(false), o => o.AnonymousIdStore = store);
        Assert.Equal("01JC0000000000000000INSTAL", store.Value);
        client.SetConsent(new Consent(true));
        client.Track("a");
        Flush(client);
        Assert.Equal("01JC0000000000000000INSTAL", Event(_transport.Requests[0]).GetProperty("anonymous_id").GetString());
    }

    [Fact]
    public void StoreFailureDoesNotCrashAndResetStillDropsOldId()
    {
        var store = new MemoryIdStore { Value = "01JC0000000000000000INSTAL" };
        var client = Make(new Consent(true), o => o.AnonymousIdStore = store);
        store.ThrowOnAccess = true;
        client.Reset();
        client.Track("a");
        Flush(client);
        Assert.NotEqual("01JC0000000000000000INSTAL", Event(_transport.Requests[0]).GetProperty("anonymous_id").GetString());
        Assert.Contains(_logs, line => line.Contains("InvalidOperationException"));
    }

    [Fact]
    public void WithdrawalDropsAnonymousIdEvenWithoutStore()
    {
        var client = Make(new Consent(true));
        client.SetAnonymousId("anon_1");
        client.SetConsent(new Consent(false));
        client.SetConsent(new Consent(true));
        client.Track("a");
        Flush(client);
        Assert.False(Event(_transport.Requests[0]).TryGetProperty("anonymous_id", out _));
    }

    [Fact]
    public void ContextCarriesOnlySchemaFieldsAndIsClipped()
    {
        var client = Make(new Consent(true), o => o.Context = new EventContext { AppVersion = new string('v', 40), AppBuild = "42", Locale = "tr-TR", Timezone = "Europe/Istanbul" });
        client.Track("a");
        Flush(client);
        var context = Event(_transport.Requests[0]).GetProperty("context");
        Assert.Equal(32, context.GetProperty("app").GetProperty("version").GetString().Length);
        Assert.Equal("42", context.GetProperty("app").GetProperty("build").GetString());
        Assert.Equal("tr-TR", context.GetProperty("locale").GetString());
        Assert.Equal("Europe/Istanbul", context.GetProperty("timezone").GetString());
        Assert.False(context.TryGetProperty("screen", out _));
    }

    [Fact]
    public void StatusNeverExposesKey()
    {
        var client = Make(new Consent(true));
        var status = client.GetStatus();
        Assert.DoesNotContain(Key, status.Endpoint);
        Assert.Equal("feralin-unity", status.Sdk);
        Assert.Equal("0.2.0", status.Version);
    }

    [Fact]
    public void KeyNeverReachesLogs()
    {
        _transport.Responses.Enqueue(new TransportResponse(400, "{\"title\":\"bad\"}"));
        var client = Make(new Consent(true), o => o.QueueLimit = 1);
        client.Track("BAD NAME");
        client.Track("a");
        client.Track("b");
        Flush(client);
        Assert.NotEmpty(_logs);
        Assert.All(_logs, line => Assert.DoesNotContain(Key, line));
    }

    [Fact]
    public void LevelEventsCarryExpectedProperties()
    {
        var client = Make(new Consent(true));
        Assert.Equal("level_start", client.TrackLevelStart("w1").EventName);
        var complete = client.TrackLevelComplete("w1", 2, 1200, 33500, Props(("stars", 3)));
        Assert.Equal("level_complete", complete.EventName);
        Assert.Equal(1200L, complete.Properties["score"]);
        Assert.Equal(33500L, complete.Properties["duration_ms"]);
        Assert.Equal(2L, complete.Properties["attempt"]);
        Assert.Equal(3, complete.Properties["stars"]);
        Assert.Null(client.TrackLevelStart(""));
        Assert.Null(client.TrackLevelComplete(null));
    }

    [Fact]
    public void IapPurchaseMapsToFeralinPurchaseAndNeverSendsVerified()
    {
        var client = Make(new Consent(true));
        var tracked = client.TrackIapPurchase("gem_pack", 49.99m, "TRY", "txn_1", Props(("verified", true)));
        Flush(client);
        var e = Event(_transport.Requests[0]);
        var props = e.GetProperty("properties");
        Assert.Equal("feralin_purchase", tracked.EventName);
        Assert.Equal(4999, props.GetProperty("amount_minor").GetInt64());
        Assert.Equal("TRY", props.GetProperty("currency").GetString());
        Assert.Equal("gem_pack", props.GetProperty("product_id").GetString());
        Assert.Equal("txn_1", props.GetProperty("transaction_id").GetString());
        Assert.False(props.TryGetProperty("price", out _));
        Assert.False(props.TryGetProperty("revenue_source", out _));
        Assert.False(props.TryGetProperty("verified", out _));
        Assert.False(e.TryGetProperty("verified", out _));
    }

    [Theory]
    [InlineData("", 1, "TRY")]
    [InlineData("p", -1, "TRY")]
    [InlineData("p", 1, "try")]
    [InlineData("p", 1, null)]
    public void IapPurchaseRejectsBadInput(string product, int price, string currency)
    {
        Assert.Null(Make(new Consent(true)).TrackIapPurchase(product, price, currency, "txn_1"));
    }

    [Fact]
    public void IapPurchaseWithoutTransactionIdIsRejectedBecauseContractRequiresIt()
    {
        Assert.Null(Make(new Consent(true)).TrackIapPurchase("p", 1, "TRY"));
    }

    [Fact]
    public void GameEventsObeyConsent()
    {
        var client = Make();
        Assert.Null(client.TrackLevelStart("w1"));
        Assert.Null(client.TrackIapPurchase("p", 1m, "TRY"));
    }

    [Fact]
    public void UlidsAreUniqueAndTimePrefixed()
    {
        var client = Make(new Consent(true));
        var ids = Enumerable.Range(0, 200).Select(_ => client.NewId()).ToList();
        Assert.Equal(200, ids.Distinct().Count());
        Assert.All(ids, id =>
        {
            Assert.Matches("^[0-9A-HJKMNP-TV-Z]{26}$", id);
            Assert.Equal(ids[0].Substring(0, 10), id.Substring(0, 10));
        });
    }
}
