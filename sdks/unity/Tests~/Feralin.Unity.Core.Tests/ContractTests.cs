using System.Text.Json;
using Feralin.Unity;
using Xunit;

namespace Feralin.Unity.Core.Tests;

/// <summary>Diğer mobil SDK'larla ortak sözleşmeler: gelir, reklam geliri, grup, kullanıcı özellikleri, oyun olayları, oturum ve hata.</summary>
public class ContractTests
{
    private const string Key = "pk_test_unity_key_0001";
    private DateTimeOffset _now = new(2026, 11, 3, 10, 0, 0, TimeSpan.Zero);
    private double _random = 0.0;
    private readonly List<string> _logs = new();
    private readonly FakeTransport _transport = new();

    private FeralinClient Make(Consent consent = null, Action<FeralinOptions> edit = null)
    {
        var options = new FeralinOptions
        {
            ProjectKey = Key,
            CollectUrl = "https://collect.example.test/",
            Transport = _transport,
            Consent = consent ?? new Consent(true),
            Clock = () => _now,
            Random = () => _random,
            Log = (_, message) => _logs.Add(message),
        };
        edit?.Invoke(options);
        return new FeralinClient(options);
    }

    private static Dictionary<string, object> Props(params (string Key, object Value)[] items) => items.ToDictionary(item => item.Key, item => item.Value);

    private JsonElement Sent(FeralinClient client, int index = 0)
    {
        client.Flush();
        return JsonDocument.Parse(_transport.Requests[^1].Body).RootElement.GetProperty("events")[index];
    }

    // ---- gelir ----

    [Fact]
    public void RevenueUsesSharedContractAndNeverSendsVerified()
    {
        var client = Make();
        var tracked = client.TrackRevenue(new RevenueInput
        {
            TransactionId = "GPA.1234",
            AmountMinor = 4999,
            Currency = "TRY",
            ProductId = "gem_pack",
            Quantity = 2,
            PurchaseType = PurchaseType.SubscriptionStart,
            Properties = Props(("verified", true), ("verification", "x"), ("verification_source", "y"), ("receipt_provider", "z"), ("receipt_digest", "d"), ("fr_click", "clk_1"), ("plan", "pro")),
        });
        Assert.Equal("feralin_purchase", tracked.EventName);
        var props = Sent(client).GetProperty("properties");
        Assert.Equal("GPA.1234", props.GetProperty("transaction_id").GetString());
        Assert.Equal(4999, props.GetProperty("amount_minor").GetInt64());
        Assert.Equal("TRY", props.GetProperty("currency").GetString());
        Assert.Equal("gem_pack", props.GetProperty("product_id").GetString());
        Assert.Equal(2, props.GetProperty("quantity").GetInt32());
        Assert.Equal("subscription_start", props.GetProperty("purchase_type").GetString());
        Assert.Equal("pro", props.GetProperty("plan").GetString());
        foreach (var banned in new[] { "verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt" })
        {
            Assert.False(props.TryGetProperty(banned, out _), banned);
        }
        Assert.False(Sent(client).TryGetProperty("verified", out _));
    }

    [Fact]
    public void RevenueDefaultsMatchAndroid()
    {
        var client = Make();
        client.TrackRevenue(new RevenueInput { TransactionId = "t1", AmountMinor = 100, Currency = "USD" });
        var props = Sent(client).GetProperty("properties");
        Assert.Equal(1, props.GetProperty("quantity").GetInt32());
        Assert.Equal("purchase", props.GetProperty("purchase_type").GetString());
        Assert.False(props.TryGetProperty("product_id", out _));
        Assert.False(props.TryGetProperty("receipt", out _));
    }

    [Fact]
    public void RevenueReceiptIsForwardedOnlyAsProviderAndToken()
    {
        var client = Make();
        client.TrackRevenue(new RevenueInput { TransactionId = "t1", AmountMinor = 100, Currency = "USD", Receipt = new Receipt(ReceiptProvider.Google, "purchase-token-abc"), Properties = Props(("receipt", "sahte")) });
        var receipt = Sent(client).GetProperty("properties").GetProperty("receipt");
        Assert.Equal("google", receipt.GetProperty("provider").GetString());
        Assert.Equal("purchase-token-abc", receipt.GetProperty("token").GetString());
        Assert.Equal(2, receipt.EnumerateObject().Count());
    }

    [Theory]
    [InlineData(null, 1L, "TRY")]
    [InlineData("", 1L, "TRY")]
    [InlineData("t", -1L, "TRY")]
    [InlineData("t", 9007199254740992L, "TRY")]
    [InlineData("t", 1L, "try")]
    [InlineData("t", 1L, "TR")]
    [InlineData("t", 1L, null)]
    public void RevenueRejectsOutOfContractInput(string transactionId, long amount, string currency)
    {
        var client = Make();
        Assert.Null(client.TrackRevenue(new RevenueInput { TransactionId = transactionId, AmountMinor = amount, Currency = currency }));
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public void RevenueRejectsRemainingInvalidFields()
    {
        var client = Make();
        Assert.Null(client.TrackRevenue(new RevenueInput { TransactionId = new string('a', 129), AmountMinor = 1, Currency = "TRY" }));
        Assert.Null(client.TrackRevenue(new RevenueInput { TransactionId = "t", AmountMinor = 1, Currency = "TRY", ProductId = "" }));
        Assert.Null(client.TrackRevenue(new RevenueInput { TransactionId = "t", AmountMinor = 1, Currency = "TRY", Quantity = -1 }));
        Assert.Null(client.TrackRevenue(new RevenueInput { TransactionId = "t", AmountMinor = 1, Currency = "TRY", Quantity = 100001 }));
        Assert.Null(client.TrackRevenue(new RevenueInput { TransactionId = "t", AmountMinor = 1, Currency = "TRY", PurchaseType = (PurchaseType)99 }));
        Assert.Null(client.TrackRevenue(new RevenueInput { TransactionId = "t", AmountMinor = 1, Currency = "TRY", Receipt = new Receipt(ReceiptProvider.Apple, "") }));
        Assert.Null(client.TrackRevenue(new RevenueInput { TransactionId = "t", AmountMinor = 1, Currency = "TRY", Receipt = new Receipt(ReceiptProvider.Apple, new string('x', 8193)) }));
        Assert.Null(client.TrackRevenue(null));
        // Abonelik iptali para taşımaz.
        Assert.Null(client.TrackRevenue(new RevenueInput { TransactionId = "t", AmountMinor = 5, Currency = "TRY", PurchaseType = PurchaseType.SubscriptionCancel }));
        Assert.NotNull(client.TrackRevenue(new RevenueInput { TransactionId = "t", AmountMinor = 0, Currency = "TRY", PurchaseType = PurchaseType.SubscriptionCancel }));
    }

    [Fact]
    public void RevenueWithoutConsentProducesNothing()
    {
        var client = Make(Consent.None);
        Assert.Null(client.TrackRevenue(new RevenueInput { TransactionId = "t", AmountMinor = 1, Currency = "TRY" }));
    }

    [Theory]
    [InlineData("TRY", "49.99", 4999)]
    [InlineData("USD", "0.5", 50)]
    [InlineData("USD", "1.005", 101)]
    [InlineData("JPY", "500", 500)]
    [InlineData("KRW", "1200", 1200)]
    [InlineData("KWD", "1.234", 1234)]
    public void CurrencyMinorUnitsFollowIso4217(string currency, string amount, long expected)
    {
        Assert.Equal(expected, CurrencyMinorUnits.ToMinor(decimal.Parse(amount, System.Globalization.CultureInfo.InvariantCulture), currency));
    }

    [Fact]
    public void CurrencyMinorUnitsRejectsNegativeAndHuge()
    {
        Assert.Null(CurrencyMinorUnits.ToMinor(-1m, "TRY"));
        Assert.Null(CurrencyMinorUnits.ToMinor(decimal.MaxValue / 1000, "TRY"));
    }

    // ---- reklam geliri ----

    [Fact]
    public void AdRevenueIsSeparateEventNotPurchase()
    {
        var client = Make();
        var tracked = client.TrackAdRevenue(new AdRevenueInput { Network = "admob", AdUnit = "ca-app-pub-1/2", AdFormat = AdFormat.RewardedInterstitial, RevenueMicros = 12500, Currency = "USD", Placement = "level_end", Precision = AdPrecision.PublisherProvided, ImpressionId = "imp_1" });
        Assert.Equal("fr_ad_revenue", tracked.EventName);
        var props = Sent(client).GetProperty("properties");
        Assert.Equal("admob", props.GetProperty("network").GetString());
        Assert.Equal("publisher_provided", props.GetProperty("precision").GetString());
        Assert.Equal("imp_1", props.GetProperty("impression_id").GetString());
        Assert.False(props.TryGetProperty("ad_network", out _));
        Assert.False(props.TryGetProperty("revenue_minor", out _));
        Assert.Equal("ca-app-pub-1/2", props.GetProperty("ad_unit").GetString());
        Assert.Equal("rewarded_interstitial", props.GetProperty("ad_format").GetString());
        Assert.Equal(12500, props.GetProperty("revenue_micros").GetInt64());
        Assert.Equal("USD", props.GetProperty("currency").GetString());
        Assert.Equal("level_end", props.GetProperty("placement").GetString());
        Assert.False(props.TryGetProperty("transaction_id", out _));
        Assert.False(props.TryGetProperty("amount_minor", out _));
    }

    [Theory]
    [InlineData(null, "u", 1L, "USD")]
    [InlineData("AdMob", "u", 1L, "USD")]
    [InlineData("1net", "u", 1L, "USD")]
    [InlineData("n", "", 1L, "USD")]
    [InlineData("n", "u", -1L, "USD")]
    [InlineData("n", "u", 1L, "usd")]
    public void AdRevenueRejectsBadInput(string network, string unit, long revenue, string currency)
    {
        Assert.Null(Make().TrackAdRevenue(new AdRevenueInput { Network = network, AdUnit = unit, RevenueMicros = revenue, Currency = currency }));
    }

    [Fact]
    public void AdRevenueNeverCarriesVerification()
    {
        var client = Make();
        client.TrackAdRevenue(new AdRevenueInput { Network = "n", AdUnit = "u", RevenueMicros = 1, Currency = "USD", Properties = Props(("verified", true)) });
        Assert.False(Sent(client).GetProperty("properties").TryGetProperty("verified", out _));
    }

    // ---- grup ve kullanıcı özellikleri ----

    [Fact]
    public void GroupMatchesReactNativeContract()
    {
        var client = Make();
        var tracked = client.Group("klan_7", Props(("tier", "gold"), ("verified", true), ("bad key", 1)));
        Assert.Equal("fr_group", tracked.EventName);
        var props = Sent(client).GetProperty("properties");
        Assert.Equal("klan_7", props.GetProperty("group_id").GetString());
        Assert.Equal("gold", props.GetProperty("tier").GetString());
        Assert.False(props.TryGetProperty("verified", out _));
        Assert.False(props.TryGetProperty("bad key", out _));
    }

    [Fact]
    public void GroupIdIsRequiredAndBounded()
    {
        var client = Make();
        Assert.Null(client.Group(""));
        Assert.Null(client.Group(null));
        Assert.Null(client.Group(new string('g', 129)));
        Assert.NotNull(client.Group(new string('g', 128)));
        // Özellikler çağıranın group_id değerini ezemez.
        client.Group("asil", Props(("group_id", "sahte")));
        Assert.Equal("asil", Sent(client, 1).GetProperty("properties").GetProperty("group_id").GetString());
    }

    [Fact]
    public void SetUserPropertiesMatchesReactNativeContract()
    {
        var client = Make();
        var tracked = client.SetUserProperties(Props(("plan", "pro"), ("level", 12), ("verified", true), ("1bad", 1)));
        Assert.Equal("fr_user_properties", tracked.EventName);
        var props = Sent(client).GetProperty("properties");
        Assert.Equal("pro", props.GetProperty("plan").GetString());
        Assert.Equal(12, props.GetProperty("level").GetInt32());
        Assert.False(props.TryGetProperty("verified", out _));
        Assert.False(props.TryGetProperty("1bad", out _));
        Assert.Null(client.SetUserProperties(Props(("1bad", 1))));
        Assert.Null(client.SetUserProperties(null));
    }

    // ---- oyun olayları ----

    [Fact]
    public void GameEventsUseAgreedNamesAndFields()
    {
        var client = Make();
        client.TrackLevelStart("k1");
        client.TrackLevelComplete("k1", 1, 900, 41500);
        client.TrackLevelFail("k2", 3, 10, 12000, "zaman_doldu");
        client.TrackEconomySource("gem", 50, "quest_reward", "gift_box");
        client.TrackEconomySink("gem", 20, "shop", "sword_01");
        client.TrackRewardedAdShown("revive", "applovin_max");
        client.TrackRewardedAdComplete("revive", "applovin_max", 1, "life");
        client.TrackIapOfferShown("gem_pack", "shop");
        client.TrackIapInitiated("gem_pack", "shop", "txn_1");
        client.Flush();
        var events = JsonDocument.Parse(_transport.Requests[0].Body).RootElement.GetProperty("events").EnumerateArray().ToArray();
        Assert.Equal(new[] { "level_start", "level_complete", "level_fail", "economy_source", "economy_sink", "rewarded_ad_shown", "rewarded_ad_complete", "iap_offer_shown", "iap_initiated" }, events.Select(e => e.GetProperty("event_name").GetString()));
        var fail = events[2].GetProperty("properties");
        Assert.Equal("k2", fail.GetProperty("level_id").GetString());
        Assert.Equal("zaman_doldu", fail.GetProperty("fail_reason").GetString());
        Assert.Equal(12000, fail.GetProperty("duration_ms").GetInt64());
        Assert.Equal(3, fail.GetProperty("attempt").GetInt64());
        Assert.False(fail.TryGetProperty("duration_seconds", out _));
        Assert.Equal(10, fail.GetProperty("score").GetInt64());
        var source = events[3].GetProperty("properties");
        Assert.Equal("gem", source.GetProperty("currency_name").GetString());
        Assert.Equal("quest_reward", source.GetProperty("reason").GetString());
        Assert.Equal(50, source.GetProperty("amount").GetInt64());
        Assert.Equal("gift_box", source.GetProperty("item_id").GetString());
        var complete = events[6].GetProperty("properties");
        Assert.Equal("revive", complete.GetProperty("placement").GetString());
        Assert.Equal("life", complete.GetProperty("reward_currency").GetString());
        Assert.Equal("applovin_max", complete.GetProperty("network").GetString());
        Assert.Equal("txn_1", events[8].GetProperty("properties").GetProperty("transaction_id").GetString());
        Assert.Equal(1, complete.GetProperty("reward_amount").GetInt64());
        Assert.All(events, e => Assert.Equal("unity", e.GetProperty("platform").GetString()));
    }

    [Fact]
    public void GameEventsRejectInvalidInput()
    {
        var client = Make();
        Assert.Null(client.TrackLevelFail(""));
        Assert.Null(client.TrackLevelStart("k", attempt: 0));
        Assert.Null(client.TrackLevelComplete("k", durationMs: 86400001));
        Assert.Null(client.TrackLevelComplete("k", score: -1));
        Assert.Null(client.TrackLevelFail("k", failReason: new string('x', 65)));
        Assert.Null(client.TrackEconomySource("gem", 1000000000001));
        Assert.Null(client.TrackIapOfferShown(""));
        Assert.Null(client.TrackIapInitiated("p", transactionId: new string('t', 129)));
        Assert.Null(client.TrackEconomySource("", 1));
        Assert.Null(client.TrackEconomySource("gem", 0));
        Assert.Null(client.TrackEconomySink("gem", -5));
        Assert.Null(client.TrackRewardedAdShown(""));
        Assert.Null(client.TrackRewardedAdComplete("p", rewardAmount: -1));
        Assert.Equal(0, client.GetStatus().Queued);
    }

    // ---- oturum ----

    [Fact]
    public void SessionIdIsAutomaticAndStable()
    {
        var client = Make();
        client.Track("a");
        client.Track("b");
        client.Flush();
        var events = JsonDocument.Parse(_transport.Requests[0].Body).RootElement.GetProperty("events").EnumerateArray().ToArray();
        var id = events[0].GetProperty("session_id").GetString();
        Assert.Equal(26, id.Length);
        Assert.Equal(id, events[1].GetProperty("session_id").GetString());
    }

    [Fact]
    public void SessionRotatesAfterThirtyMinutesInBackgroundOnly()
    {
        var client = Make();
        var first = client.Track("a");
        client.NotifyBackground();
        _now += TimeSpan.FromMinutes(29) + TimeSpan.FromSeconds(59);
        client.NotifyForeground();
        var stillSame = client.Track("b");

        client.NotifyBackground();
        _now += TimeSpan.FromMinutes(30);
        client.NotifyForeground();
        var rotated = client.Track("c");

        client.Flush();
        var ids = JsonDocument.Parse(_transport.Requests[0].Body).RootElement.GetProperty("events").EnumerateArray().Select(e => e.GetProperty("session_id").GetString()).ToArray();
        Assert.Equal(ids[0], ids[1]);
        Assert.NotEqual(ids[1], ids[2]);
        Assert.NotNull(first);
        Assert.NotNull(stillSame);
        Assert.NotNull(rotated);
    }

    [Fact]
    public void RepeatedBackgroundNotificationsKeepTheFirstInstant()
    {
        var client = Make();
        client.Track("a");
        client.NotifyBackground();
        _now += TimeSpan.FromMinutes(20);
        // Duraklama ve odak kaybı art arda gelir; ikinci bildirim süreyi sıfırlamaz.
        client.NotifyBackground();
        _now += TimeSpan.FromMinutes(11);
        client.NotifyForeground();
        client.Track("b");
        client.Flush();
        var ids = JsonDocument.Parse(_transport.Requests[0].Body).RootElement.GetProperty("events").EnumerateArray().Select(e => e.GetProperty("session_id").GetString()).ToArray();
        Assert.NotEqual(ids[0], ids[1]);
    }

    [Fact]
    public void ForegroundWithoutBackgroundKeepsSession()
    {
        var client = Make();
        client.Track("a");
        _now += TimeSpan.FromHours(5);
        client.NotifyForeground();
        client.Track("b");
        client.Flush();
        var ids = JsonDocument.Parse(_transport.Requests[0].Body).RootElement.GetProperty("events").EnumerateArray().Select(e => e.GetProperty("session_id").GetString()).ToArray();
        Assert.Equal(ids[0], ids[1]);
    }

    [Fact]
    public void ResetStartsNewSessionAndZeroTimeoutDisablesIt()
    {
        var client = Make();
        client.Track("a");
        client.Reset();
        client.Track("b");
        client.Flush();
        var ids = JsonDocument.Parse(_transport.Requests[0].Body).RootElement.GetProperty("events").EnumerateArray().Select(e => e.GetProperty("session_id").GetString()).ToArray();
        // Reset kuyruğu da siler; yalnız ikinci olay kalır ve oturumu yenidir.
        Assert.Single(ids);

        var off = Make(null, o => o.SessionTimeout = TimeSpan.Zero);
        off.Track("a");
        off.NotifyBackground();
        off.NotifyForeground();
        off.Track("b");
        off.Flush();
        var last = JsonDocument.Parse(_transport.Requests[^1].Body).RootElement.GetProperty("events")[0];
        Assert.False(last.TryGetProperty("session_id", out _));
    }

    [Fact]
    public void ManualSessionIdStillOverrides()
    {
        var client = Make();
        client.SetSessionId("elle_1");
        client.Track("a");
        client.Flush();
        Assert.Equal("elle_1", JsonDocument.Parse(_transport.Requests[0].Body).RootElement.GetProperty("events")[0].GetProperty("session_id").GetString());
    }

    // ---- hata ----

    private const string Stack = "UnityEngine.Debug:LogException(Exception)\nFeralin.Game.Inventory.AddItem (System.String id, System.Int32 count) (at Assets/Scripts/Inventory.cs:42)\nFeralin.Game.Shop.Buy (System.String sku) (at C:/Users/Ornek/proj/Assets/Scripts/Shop.cs:101)\n";

    [Fact]
    public void CaptureErrorBuildsScrubbedFingerprintedEvent()
    {
        var client = Make();
        var tracked = client.CaptureError("NullReferenceException", "Oyuncu ali@example.com 192.168.1.20 adresinden girdi; token=abcdef123456 https://api.x.com/v1?key=GIZLI&u=1 yolu C:\\Users\\Ornek\\AppData\\x", Stack, false, ErrorSource.LogException);
        Assert.Equal("fr_error", tracked.EventName);
        var props = Sent(client).GetProperty("properties");
        var message = props.GetProperty("message").GetString();
        Assert.DoesNotContain("ali@example.com", message);
        Assert.DoesNotContain("192.168.1.20", message);
        Assert.DoesNotContain("abcdef123456", message);
        Assert.DoesNotContain("GIZLI", message);
        Assert.DoesNotContain("Ornek", message);
        Assert.Contains("[email]", message);
        Assert.Contains("[ip]", message);
        Assert.Equal("NullReferenceException", props.GetProperty("error_type").GetString());
        Assert.False(props.GetProperty("handled").GetBoolean());
        Assert.Equal("uncaught_exception", props.GetProperty("origin").GetString());
        Assert.False(props.GetProperty("fatal").GetBoolean());
        Assert.False(props.TryGetProperty("frames", out _));
        Assert.False(props.TryGetProperty("source", out _));
        Assert.Matches("^[0-9a-f]{16}$", props.GetProperty("fingerprint").GetString());
        var top = props.GetProperty("top_frame").GetString();
        Assert.Equal("UnityEngine.Debug:LogException", top);
        Assert.DoesNotContain("Assets/", top);
        Assert.Equal(3, props.GetProperty("frame_count").GetInt32());
        Assert.True(message.Length <= 200);
        // Şema fr_error alan listesi dışındaki alan taşınmaz.
        var allowed = new[] { "error_type", "message", "fingerprint", "top_frame", "frame_count", "app_version", "handled", "fatal", "origin" };
        Assert.All(props.EnumerateObject(), p => Assert.Contains(p.Name, allowed));
    }

    [Fact]
    public void FingerprintIgnoresLineNumbersPathsAndArguments()
    {
        var a = ErrorSanitizer.Fingerprint("Boom", ErrorSanitizer.NormalizeFrames("A.B.C (System.String x) (at /Users/ali/a.cs:10)\nD.E.F () (at /home/b/b.cs:20)", 12));
        var b = ErrorSanitizer.Fingerprint("Boom", ErrorSanitizer.NormalizeFrames("A.B.C (System.Int32 y) (at C:\\Users\\veli\\x.cs:999)\nD.E.F () [0x0001f] in <abc123>:0", 12));
        var other = ErrorSanitizer.Fingerprint("Boom", ErrorSanitizer.NormalizeFrames("A.B.C () (at a.cs:1)\nD.E.G () (at b.cs:2)", 12));
        Assert.Equal(a, b);
        Assert.NotEqual(a, other);
        Assert.NotEqual(a, ErrorSanitizer.Fingerprint("Other", ErrorSanitizer.NormalizeFrames("A.B.C () (at a.cs:1)\nD.E.F () (at b.cs:2)", 12)));
    }

    [Fact]
    public void ScrubRemovesTokensNumbersAndPaths()
    {
        var s = ErrorSanitizer.Scrub("Authorization: Bearer abc.def.ghi password=hunter2 eyJhbGciOi.eyJzdWIiOiIx.sig0123456789 +90 532 123 45 67 /home/ali/x /Users/veli/y 2001:db8:85a3:0:0:8a2e:370:7334 " + new string('a', 60), 512);
        Assert.DoesNotContain("hunter2", s);
        Assert.DoesNotContain("eyJhbGciOi", s);
        Assert.DoesNotContain("532 123", s);
        Assert.DoesNotContain("/ali/", s);
        Assert.DoesNotContain("/veli/", s);
        Assert.DoesNotContain("8a2e", s);
        Assert.DoesNotContain(new string('a', 60), s);
        Assert.Equal("", ErrorSanitizer.Scrub(null, 10));
        Assert.True(ErrorSanitizer.Scrub(new string('x', 5000), 100).Length <= 100);
    }

    [Fact]
    public void ErrorRateLimitsAndCountsSuppressed()
    {
        var client = Make(null, o => o.Errors = new ErrorOptions { MaxPerMinute = 100, MaxPerFingerprintPerMinute = 2 });
        for (var i = 0; i < 5; i++)
        {
            client.CaptureError("Boom", "m", Stack);
        }
        Assert.Equal(2, client.GetStatus().Queued);
        Assert.Equal(3, client.GetStatus().ErrorsSuppressed);

        // Pencere kayınca yeni hata yeniden alınır; bastırılan toplam durumda kalır.
        _now += TimeSpan.FromSeconds(61);
        Assert.NotNull(client.CaptureError("Boom", "m", Stack));
        Assert.Equal(3, client.GetStatus().Queued);
        Assert.Equal(3, client.GetStatus().ErrorsSuppressed);
    }

    [Fact]
    public void ErrorGlobalLimitAppliesAcrossFingerprints()
    {
        var client = Make(null, o => o.Errors = new ErrorOptions { MaxPerMinute = 3, MaxPerFingerprintPerMinute = 10 });
        for (var i = 0; i < 6; i++)
        {
            client.CaptureError("Hata" + i, "m", "X.Y" + i + " ()");
        }
        Assert.Equal(3, client.GetStatus().Queued);
        Assert.Equal(3, client.GetStatus().ErrorsSuppressed);
    }

    [Fact]
    public void ErrorSamplingDropsEvents()
    {
        _random = 0.9;
        var client = Make(null, o => o.Errors = new ErrorOptions { SampleRate = 0.5 });
        Assert.Null(client.CaptureError("Boom", "m", Stack));
        _random = 0.1;
        var kept = client.CaptureError("Boom", "m", Stack);
        Assert.NotNull(kept);
        Assert.False(Sent(client).GetProperty("properties").TryGetProperty("sample_rate", out _));
        // Örnekleme dışı kalan hata hız sınırı sayacını harcamaz.
        Assert.Equal(0, client.GetStatus().ErrorsSuppressed);
    }

    [Fact]
    public void ErrorCaptureRespectsConsentAndNeverThrows()
    {
        Assert.Null(Make(Consent.None).CaptureError("Boom", "m", Stack));
        var client = Make(null, o => o.Errors = new ErrorOptions { MaxPerMinute = 0 });
        Assert.Null(client.CaptureError("Boom", "m", Stack));
        var closed = Make();
        closed.Close();
        Assert.Null(closed.CaptureError("Boom", "m", Stack));
        Assert.NotNull(Make().CaptureError(null, null, null));
    }

    [Fact]
    public void ErrorFramesAreBounded()
    {
        var client = Make(null, o => o.Errors = new ErrorOptions { MaxFrames = 3 });
        var stack = string.Join("\n", Enumerable.Range(0, 30).Select(i => "Ns.Type" + i + ".Method ()"));
        client.CaptureError("Boom", "m", stack);
        Assert.Equal(3, Sent(client).GetProperty("properties").GetProperty("frame_count").GetInt32());
    }
}
