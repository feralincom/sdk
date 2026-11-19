using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Feralin.Unity;
using Xunit;

namespace Feralin.Unity.Core.Tests;

public class AttributionParamsTests
{
    [Fact]
    public void ParsesFrClickAndUtmOnly()
    {
        var p = AttributionParams.ParseQuery("fr_click=clk_01&utm_source=google&utm_medium=cpc&utm_campaign=yaz&gclid=SECRET&fbclid=X&other=1");
        Assert.Equal("clk_01", p.FrClick);
        Assert.Equal(new[] { "utm_campaign", "utm_medium", "utm_source" }, p.Utm.Keys.OrderBy(k => k));
        Assert.False(p.IsEmpty);
        Assert.DoesNotContain("SECRET", string.Join(",", p.Utm.Values));
    }

    [Fact]
    public void FirstValueWinsAndBadPartsAreIgnored()
    {
        var p = AttributionParams.ParseQuery("fr_click=ilk&fr_click=ikinci&utm_source=%ZZ&utm_medium=cpc&=x&utm_term");
        Assert.Equal("ilk", p.FrClick);
        Assert.False(p.Utm.ContainsKey("utm_source"));
        Assert.Equal("cpc", p.Utm["utm_medium"]);
    }

    [Fact]
    public void RejectsMalformedFrClick()
    {
        Assert.Null(AttributionParams.ParseQuery("fr_click=bo%C5%9F+luk").FrClick);
        Assert.Null(AttributionParams.ParseQuery("fr_click=" + new string('a', 257)).FrClick);
        Assert.Null(AttributionParams.ParseQuery("fr_click=a/b").FrClick);
    }

    [Fact]
    public void DoubleEncodedReferrerIsDecodedOnce()
    {
        var p = AttributionParams.ParseQuery("fr_click%3Dclk_9%26utm_source%3Dnews");
        Assert.Equal("clk_9", p.FrClick);
        Assert.Equal("news", p.Utm["utm_source"]);
    }

    [Fact]
    public void ValuesAreClippedAndDecoded()
    {
        var p = AttributionParams.ParseQuery("utm_campaign=" + new string('k', 400) + "&utm_term=ya%C4%9Fmur+bulutu");
        Assert.Equal(256, p.Utm["utm_campaign"].Length);
        Assert.Equal("yağmur bulutu", p.Utm["utm_term"]);
    }

    [Theory]
    [InlineData("utm_source=google-play&utm_medium=organic", true)]
    [InlineData("utm_source=(not set)&utm_medium=(not set)", true)]
    [InlineData("utm_source=google&utm_medium=cpc", false)]
    [InlineData("fr_click=clk_1&utm_medium=organic", false)]
    public void PlayOrganicDefaultIsNotEvidence(string query, bool organic)
    {
        Assert.Equal(organic, AttributionParams.ParseQuery(query).IsPlayOrganicDefault);
    }

    [Theory]
    [InlineData("fr_click=c1&fr_dl=/oyun/seviye/3", "/oyun/seviye/3")]
    [InlineData("fr_click=c1&fr_dl=/a?b=1", "/a?b=1")]
    [InlineData("fr_click=c1&fr_dl=//evil.example", null)]
    [InlineData("fr_click=c1&fr_dl=https://evil.example/x", null)]
    [InlineData("fr_click=c1&fr_dl=/a/../etc", null)]
    [InlineData("fr_click=c1&fr_dl=/a/%2e%2e/b", null)]
    [InlineData("fr_click=c1&fr_dl=/a%252Fb", null)]
    [InlineData("fr_click=c1&fr_dl=/a/%252e%252e/b", null)]
    [InlineData("fr_click=c1&fr_dl=/a%2Fb", "/a/b")]
    [InlineData("fr_click=c1&fr_dl=/a%5Cb", null)]
    [InlineData("fr_click=c1&fr_dl=/a%0Ab", null)]
    [InlineData("fr_click=c1&fr_dl=/a%255Cb", null)]
    [InlineData("fr_click=c1&fr_dl=/a%zz", null)]
    [InlineData("fr_dl=/yol", null)]
    public void DeferredDeepLinkPathFollowsLinkRouterRules(string query, string expected)
    {
        Assert.Equal(expected, AttributionParams.ParseQuery(query).DeepLinkPath);
    }

    [Fact]
    public void DeepLinkKeepsOnlySchemeHostPathAndAllowlist()
    {
        var link = DeepLink.Parse("https://link.feralin.com:8443/r/abc?fr_click=c1&utm_source=x&email=ali@x.com&token=SECRET#frag");
        Assert.Equal("https://link.feralin.com:8443/r/abc", link.CleanUrl);
        Assert.Equal("c1", link.Params.FrClick);
        Assert.Equal("x", link.Params.Utm["utm_source"]);
        Assert.DoesNotContain("SECRET", link.CleanUrl);
        Assert.Equal("https://a.example/", DeepLink.Parse("https://a.example").CleanUrl);
        Assert.Equal("http://a.example/p", DeepLink.Parse("http://a.example:80/p").CleanUrl);
    }

    [Theory]
    [InlineData("oyun://seviye/3?fr_click=c1")]
    [InlineData("ftp://a.example/x")]
    [InlineData("javascript:alert(1)")]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("not a url")]
    public void CustomSchemesAndGarbageAreNotEvidence(string raw)
    {
        Assert.Null(DeepLink.Parse(raw));
    }
}

public class AttributionClientTests : IDisposable
{
    private const string Key = "pk_test_unity_key_0001";
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "feralin-unity-attr-" + Guid.NewGuid().ToString("N"));
    private readonly byte[] _storeKey = RandomNumberGenerator.GetBytes(32);
    private DateTimeOffset _now = new(2026, 11, 3, 10, 0, 0, TimeSpan.Zero);
    private readonly List<string> _logs = new();
    private TrackingStatus _tracking = TrackingStatus.Authorized;

    public void Dispose()
    {
        try
        {
            Directory.Delete(_dir, true);
        }
        catch (IOException)
        {
        }
    }

    private sealed class FakeReferrer : IInstallReferrerSource
    {
        public int Reads { get; private set; }
        public string Referrer { get; set; }
        public bool Throw { get; set; }
        public bool Defer { get; set; }
        public Action<string> Pending { get; private set; }

        public void Read(Action<string> onResult)
        {
            Reads++;
            if (Throw)
            {
                throw new InvalidOperationException("kitaplık yok");
            }
            if (Defer)
            {
                Pending = onResult;
                return;
            }
            onResult(Referrer);
        }
    }

    private sealed class FakeTokens : IAdServicesTokenSource
    {
        public AdServicesTokenResult Result { get; set; } = AdServicesTokenResult.FromToken("TOKEN-DEGERI-1");
        public int Calls { get; private set; }

        public void GetToken(Action<AdServicesTokenResult> onResult)
        {
            Calls++;
            onResult(Result);
        }
    }

    private FeralinClient Make(FakeTransport transport, Consent consent, Action<FeralinOptions> edit = null, bool store = true)
    {
        var options = new FeralinOptions
        {
            ProjectKey = Key,
            CollectUrl = "https://collect.example.test/",
            Transport = transport,
            Consent = consent,
            Clock = () => _now,
            Random = () => 1.0,
            Store = store ? new EncryptedEventStore(new FileEventStore(_dir), new AesGcmPayloadCipher(_storeKey)) : null,
            Log = (_, message) => _logs.Add(message),
            TrackingStatusProvider = () => _tracking,
            AttributionApiUrl = "https://api.feralin.test/",
            ProjectId = "proj_demo 1",
        };
        edit?.Invoke(options);
        return new FeralinClient(options);
    }

    private static JsonElement[] Events(TransportRequest request) =>
        JsonDocument.Parse(request.Body).RootElement.GetProperty("events").EnumerateArray().Select(e => e.Clone()).ToArray();

    private static JsonElement[] SentEvents(FeralinClient client, FakeTransport transport)
    {
        client.Flush();
        return transport.Requests.SelectMany(Events).ToArray();
    }

    [Fact]
    public void FirstOpenWithReferrerCarriesFrClickAndIsCountedOncePerInstall()
    {
        var transport = new FakeTransport();
        var referrer = new FakeReferrer { Referrer = "fr_click=clk_play_1&utm_source=google&utm_medium=cpc" };
        var client = Make(transport, new Consent(true, true));
        client.StartAttribution(referrer);
        var events = SentEvents(client, transport);
        var open = Assert.Single(events);
        Assert.Equal("app_first_open", open.GetProperty("event_name").GetString());
        var props = open.GetProperty("properties");
        Assert.Equal("play_install_referrer", props.GetProperty("attribution_source").GetString());
        Assert.Equal("clk_play_1", props.GetProperty("fr_click").GetString());
        Assert.Equal("google", props.GetProperty("utm_source").GetString());
        Assert.True(open.GetProperty("consent").GetProperty("advertising").GetBoolean());

        // Aynı kurulumda yeniden başlatma: referrer okunmaz, ikinci ilk açılış yok.
        var again = new FakeReferrer { Referrer = "fr_click=baska" };
        var restarted = Make(new FakeTransport(), new Consent(true, true));
        restarted.StartAttribution(again);
        Assert.Equal(0, again.Reads);
        Assert.Equal(0, restarted.GetStatus().Queued);
    }

    private sealed class FakeMeta : IMetaReferrerSource
    {
        public int Reads { get; private set; }
        public string AppId { get; private set; }
        public string Value { get; set; }
        public string Read(string appId)
        {
            Reads++;
            AppId = appId;
            return Value;
        }
    }

    [Fact]
    public void FirstOpenCarriesMetaReferrerOnlyWithAdvertisingConsentAndAppId()
    {
        var meta = new FakeMeta { Value = "{\"r\":\"x\",\"p\":\"instagram\"}" };
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true), o => { o.MetaAppId = " 1234567890 "; o.MetaReferrerSource = meta; });
        client.StartAttribution(new FakeReferrer());
        var props = Assert.Single(SentEvents(client, transport)).GetProperty("properties");
        Assert.Equal(meta.Value, props.GetProperty("meta_install_referrer").GetString());
        Assert.Equal("1234567890", meta.AppId);

        // Reklam izni yoksa okunmaz.
        Dispose();
        var denied = new FakeMeta { Value = "x" };
        var deniedTransport = new FakeTransport();
        var deniedClient = Make(deniedTransport, new Consent(true, false), o => { o.MetaAppId = "1234567890"; o.MetaReferrerSource = denied; });
        deniedClient.StartAttribution(new FakeReferrer());
        Assert.False(Assert.Single(SentEvents(deniedClient, deniedTransport)).GetProperty("properties").TryGetProperty("meta_install_referrer", out _));
        Assert.Equal(0, denied.Reads);

        // Geçersiz App ID ile okunmaz.
        Dispose();
        var bad = new FakeMeta { Value = "x" };
        var badTransport = new FakeTransport();
        var badClient = Make(badTransport, new Consent(true, true), o => { o.MetaAppId = "abc"; o.MetaReferrerSource = bad; });
        badClient.StartAttribution(new FakeReferrer());
        SentEvents(badClient, badTransport);
        Assert.Equal(0, bad.Reads);
    }

    private sealed class FakeInstallStore : IInstallStoreSource
    {
        public int Reads { get; private set; }
        public string Value { get; set; }
        public bool Throw { get; set; }
        public string Read()
        {
            Reads++;
            if (Throw)
            {
                throw new InvalidOperationException("paket bilgisi yok");
            }
            return Value;
        }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void FirstOpenCarriesInstallStoreRegardlessOfAdvertisingConsent(bool advertising)
    {
        var source = new FakeInstallStore { Value = InstallStore.SamsungGalaxyStore };
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, advertising), o => o.InstallStoreSource = source);
        client.StartAttribution(new FakeReferrer());
        var open = Assert.Single(SentEvents(client, transport));
        Assert.Equal("app_first_open", open.GetProperty("event_name").GetString());
        Assert.Equal("samsung_galaxy_store", open.GetProperty("properties").GetProperty("install_store").GetString());
        Assert.Equal(1, source.Reads);
    }

    [Theory]
    [InlineData("com.ornek.ozelmagaza")]
    [InlineData("com.android.vending")]
    [InlineData("")]
    [InlineData(null)]
    public void InstallStoreOutsideClosedListIsNeverSent(string value)
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true), o => o.InstallStoreSource = new FakeInstallStore { Value = value });
        client.StartAttribution(new FakeReferrer());
        var open = Assert.Single(SentEvents(client, transport));
        Assert.False(open.GetProperty("properties").TryGetProperty("install_store", out _));
        if (!string.IsNullOrEmpty(value))
        {
            Assert.DoesNotContain(value, open.GetRawText());
        }
    }

    [Fact]
    public void InstallStoreReadFailureDoesNotBlockFirstOpen()
    {
        var source = new FakeInstallStore { Throw = true };
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true), o => o.InstallStoreSource = source);
        client.StartAttribution(new FakeReferrer { Referrer = "fr_click=clk_1" });
        var props = Assert.Single(SentEvents(client, transport)).GetProperty("properties");
        Assert.False(props.TryGetProperty("install_store", out _));
        Assert.Equal("play_install_referrer", props.GetProperty("attribution_source").GetString());
        Assert.Equal(1, source.Reads);

        // Kaynak verilmemiş (iOS, Editor): alan yok.
        Dispose();
        var bareTransport = new FakeTransport();
        var bare = Make(bareTransport, new Consent(true, true));
        bare.StartAttribution(new FakeReferrer());
        Assert.False(Assert.Single(SentEvents(bare, bareTransport)).GetProperty("properties").TryGetProperty("install_store", out _));
    }

    [Fact]
    public void InstallStoreIsNotReadWithoutAnalyticsConsent()
    {
        var source = new FakeInstallStore { Value = InstallStore.GooglePlay };
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(false, false), o => o.InstallStoreSource = source);
        client.StartAttribution(new FakeReferrer());
        Assert.Empty(SentEvents(client, transport));
        Assert.Equal(0, source.Reads);
    }

    [Fact]
    public void FirstOpenWithoutAdvertisingConsentNeverReadsReferrerAndCarriesNoEvidence()
    {
        var transport = new FakeTransport();
        var referrer = new FakeReferrer { Referrer = "fr_click=clk_gizli&utm_source=x" };
        var client = Make(transport, new Consent(true, false));
        client.StartAttribution(referrer);
        var open = Assert.Single(SentEvents(client, transport));
        Assert.Equal(0, referrer.Reads);
        var props = open.GetProperty("properties");
        Assert.Equal("none", props.GetProperty("attribution_source").GetString());
        Assert.False(props.TryGetProperty("fr_click", out _));
        Assert.False(props.TryGetProperty("utm_source", out _));
    }

    [Fact]
    public void OrganicPlayDefaultIsNotEvidence()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true));
        client.StartAttribution(new FakeReferrer { Referrer = "utm_source=google-play&utm_medium=organic" });
        var props = Assert.Single(SentEvents(client, transport)).GetProperty("properties");
        Assert.Equal("none", props.GetProperty("attribution_source").GetString());
        Assert.False(props.TryGetProperty("utm_source", out _));
    }

    [Fact]
    public void ReferrerFailureStillCountsFirstOpenAsNone()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true));
        client.StartAttribution(new FakeReferrer { Throw = true });
        var props = Assert.Single(SentEvents(client, transport)).GetProperty("properties");
        Assert.Equal("none", props.GetProperty("attribution_source").GetString());
    }

    [Fact]
    public void FirstOpenWaitsForConsentDecisionAndForSlowReferrer()
    {
        var transport = new FakeTransport();
        var referrer = new FakeReferrer { Referrer = "fr_click=gec_geldi", Defer = true };
        var client = Make(transport, null);
        client.StartAttribution(referrer);
        Assert.Equal(0, referrer.Reads);
        Assert.Equal(0, client.GetStatus().Queued);

        client.SetConsent(new Consent(true, true));
        Assert.Equal(1, referrer.Reads);
        Assert.Equal(0, client.GetStatus().Queued);
        referrer.Pending("fr_click=gec_geldi");
        var open = Assert.Single(SentEvents(client, transport));
        Assert.Equal("gec_geldi", open.GetProperty("properties").GetProperty("fr_click").GetString());
        // Geri çağrı ikinci kez gelse de tek olay.
        referrer.Pending("fr_click=baska");
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public void WithdrawingConsentWhileReadingDoesNotMarkInstallAndRetriesLater()
    {
        var transport = new FakeTransport();
        var referrer = new FakeReferrer { Defer = true };
        var client = Make(transport, new Consent(true, true));
        client.StartAttribution(referrer);
        client.SetConsent(Consent.None);
        referrer.Pending("fr_click=x");
        Assert.Equal(0, client.GetStatus().Queued);
        Assert.Null(new FileEventStore(_dir).GetMarker("first_open_event_id"));

        // İzin yeniden verilince aynı kaynak bir kez daha okunur ve ilk açılış o zaman sayılır.
        referrer.Defer = false;
        referrer.Referrer = "fr_click=sonra";
        client.SetConsent(new Consent(true, true));
        var open = Assert.Single(SentEvents(client, transport));
        Assert.Equal("sonra", open.GetProperty("properties").GetProperty("fr_click").GetString());
    }

    [Fact]
    public void AdvertisingConsentGivenLaterCarriesEvidenceInFollowUpEvent()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, false));
        var referrer = new FakeReferrer { Referrer = "fr_click=clk_sonra&utm_source=ads" };
        client.StartAttribution(referrer);
        Assert.Equal(0, referrer.Reads);

        _now += TimeSpan.FromMinutes(5);
        client.SetConsent(new Consent(true, true));
        Assert.Equal(1, referrer.Reads);
        var events = SentEvents(client, transport);
        Assert.Equal(new[] { "app_first_open", "deep_link_opened" }, events.Select(e => e.GetProperty("event_name").GetString()));
        var followUp = events[1].GetProperty("properties");
        Assert.True(followUp.GetProperty("consent_followup").GetBoolean());
        Assert.Equal("play_install_referrer", followUp.GetProperty("attribution_source").GetString());
        Assert.Equal("clk_sonra", followUp.GetProperty("fr_click").GetString());
        Assert.Equal("2026-11-03T10:00:00.000Z", followUp.GetProperty("first_open_at").GetString());

        // Referrer bir kez okunur.
        client.SetConsent(new Consent(true, true));
        Assert.Equal(1, referrer.Reads);
    }

    [Fact]
    public void WithoutPersistentStoreAttributionDoesNothing()
    {
        var transport = new FakeTransport();
        var referrer = new FakeReferrer { Referrer = "fr_click=x" };
        var client = Make(transport, new Consent(true, true), store: false);
        client.StartAttribution(referrer);
        Assert.Equal(0, referrer.Reads);
        Assert.Equal(0, client.GetStatus().Queued);
        Assert.Contains(_logs, l => l.Contains("kalıcı depo yok"));
    }

    [Fact]
    public void AttDeniedBlocksAdvertisingEvidence()
    {
        _tracking = TrackingStatus.Denied;
        var transport = new FakeTransport();
        var referrer = new FakeReferrer { Referrer = "fr_click=x" };
        var client = Make(transport, new Consent(true, true));
        client.StartAttribution(referrer);
        var open = Assert.Single(SentEvents(client, transport));
        Assert.Equal(0, referrer.Reads);
        Assert.Equal("none", open.GetProperty("properties").GetProperty("attribution_source").GetString());
        Assert.False(open.GetProperty("consent").GetProperty("advertising").GetBoolean());
        // Uygulamanın verdiği fr_click da ATT reddinde gönderilmez.
        client.Track("level_start", new Dictionary<string, object> { ["fr_click"] = "clk" });
        client.Flush();
        var last = Events(transport.Requests[^1]).Last();
        Assert.False(last.TryGetProperty("properties", out var sentProps) && sentProps.TryGetProperty("fr_click", out _));
    }

    [Fact]
    public void DeepLinkBecomesEventWithCleanUrlAndFrClick()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true));
        client.HandleDeepLink("https://link.feralin.com/r/abc?fr_click=clk_dl_1&utm_campaign=kis&token=SECRET&email=a@b.com");
        var e = Assert.Single(SentEvents(client, transport));
        Assert.Equal("deep_link_opened", e.GetProperty("event_name").GetString());
        Assert.Equal("https://link.feralin.com/r/abc", e.GetProperty("context").GetProperty("page_url").GetString());
        var props = e.GetProperty("properties");
        Assert.Equal("app_link", props.GetProperty("attribution_source").GetString());
        Assert.Equal("clk_dl_1", props.GetProperty("fr_click").GetString());
        Assert.Equal("kis", props.GetProperty("utm_campaign").GetString());
        Assert.DoesNotContain("SECRET", transport.Requests[0].Body.Length > 0 ? Encoding.UTF8.GetString(transport.Requests[0].Body) : "");
        Assert.DoesNotContain("a@b.com", Encoding.UTF8.GetString(transport.Requests[0].Body));
    }

    [Fact]
    public void DeepLinkWithoutAdvertisingConsentCarriesNoEvidence()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, false));
        client.HandleDeepLink("https://link.feralin.com/r/abc?fr_click=clk_dl_1&utm_source=x");
        var e = Assert.Single(SentEvents(client, transport));
        var props = e.GetProperty("properties");
        Assert.Equal("none", props.GetProperty("attribution_source").GetString());
        Assert.False(props.TryGetProperty("fr_click", out _));
        Assert.False(props.TryGetProperty("utm_source", out _));
        Assert.Equal("https://link.feralin.com/r/abc", e.GetProperty("context").GetProperty("page_url").GetString());
    }

    [Fact]
    public void CustomSchemeAndGarbageLinksProduceNoEvent()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true));
        client.HandleDeepLink("oyun://seviye/3?fr_click=c");
        client.HandleDeepLink("");
        client.HandleDeepLink(null);
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public void DeepLinkBeforeConsentDecisionWaitsInMemoryOnly()
    {
        var transport = new FakeTransport();
        var client = Make(transport, null);
        client.HandleDeepLink("https://link.feralin.com/r/abc?fr_click=bekleyen");
        Assert.Equal(0, client.GetStatus().Queued);
        Assert.Empty(new FileEventStore(_dir).Load());

        client.SetConsent(new Consent(true, true));
        var e = Assert.Single(SentEvents(client, transport));
        Assert.Equal("bekleyen", e.GetProperty("properties").GetProperty("fr_click").GetString());
    }

    [Fact]
    public void DeepLinkBeforeDeniedDecisionIsDropped()
    {
        var transport = new FakeTransport();
        var client = Make(transport, null);
        client.HandleDeepLink("https://link.feralin.com/r/abc?fr_click=bekleyen");
        client.SetConsent(Consent.None);
        client.SetConsent(new Consent(true, true));
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public void LinkEvidenceBeforeFirstOpenIsUsedWhenNoReferrer()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true));
        client.HandleDeepLink("https://link.feralin.com/r/abc?fr_click=link_kanit");
        client.StartAttribution(new FakeReferrer());
        var events = SentEvents(client, transport);
        var open = events.Single(e => e.GetProperty("event_name").GetString() == "app_first_open");
        Assert.Equal("app_link", open.GetProperty("properties").GetProperty("attribution_source").GetString());
        Assert.Equal("link_kanit", open.GetProperty("properties").GetProperty("fr_click").GetString());
    }

    [Fact]
    public void DeferredDeepLinkIsDeliveredOnceAndOnlyWithConsent()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true));
        client.StartAttribution(new FakeReferrer { Referrer = "fr_click=c1&fr_dl=/oyun/seviye/3" });
        Assert.Equal("/oyun/seviye/3", client.ConsumeDeferredDeepLink());
        Assert.Null(client.ConsumeDeferredDeepLink());

        var other = Make(new FakeTransport(), new Consent(true, true));
        Assert.Null(other.ConsumeDeferredDeepLink());
    }

    [Fact]
    public void DeferredDeepLinkIsNotDeliveredWithoutAdvertisingConsent()
    {
        var client = Make(new FakeTransport(), new Consent(true, true));
        client.StartAttribution(new FakeReferrer { Referrer = "fr_click=c1&fr_dl=/yol" });
        client.SetConsent(new Consent(true, false));
        Assert.Null(client.ConsumeDeferredDeepLink());
    }

    // ---- iOS AdServices ve kurulum kimliği ----

    private static JsonElement Body(TransportRequest request) => JsonDocument.Parse(request.Body).RootElement;

    [Fact]
    public void BindInstallSendsTokenWithInstallIdAndBearerKey()
    {
        var transport = new FakeTransport();
        transport.Responses.Enqueue(new TransportResponse(202, "{}"));
        var client = Make(transport, new Consent(true, true));
        InstallBinding result = null;
        var tokens = new FakeTokens();
        client.BindInstall(tokens, r => result = r);
        Assert.Equal("received", result.Status);
        Assert.Equal(26, result.InstallId.Length);

        var request = transport.Requests[0];
        Assert.Equal("https://api.feralin.test/v1/projects/proj_demo%201/attribution/apple-adservices/tokens", request.Url);
        Assert.Equal("Bearer " + Key, request.Headers["Authorization"]);
        Assert.Equal("TOKEN-DEGERI-1", Body(request).GetProperty("token").GetString());
        Assert.Equal(result.InstallId, Body(request).GetProperty("install_id").GetString());
        Assert.DoesNotContain("TOKEN-DEGERI-1", string.Join("|", _logs));

        // Aynı kurulumda kimlik kalıcıdır.
        transport.Responses.Enqueue(new TransportResponse(202, "{}"));
        var restarted = Make(transport, new Consent(true, true));
        InstallBinding second = null;
        restarted.BindInstall(tokens, r => second = r);
        Assert.Equal(result.InstallId, second.InstallId);
    }

    [Fact]
    public void BindInstallReturnsExactStatuses()
    {
        InstallBinding Bind(FakeTransport transport, Consent consent, IAdServicesTokenSource source, Action<FeralinOptions> edit = null)
        {
            InstallBinding result = null;
            Make(transport, consent, edit).BindInstall(source, r => result = r);
            return result;
        }

        var ok = new FakeTokens();
        var notConfigured = Bind(new FakeTransport(), new Consent(true, true), ok, o => o.AttributionApiUrl = null);
        Assert.Equal("not_configured", notConfigured.Status);
        Assert.Null(notConfigured.InstallId);
        Assert.Equal("not_configured", Bind(new FakeTransport(), new Consent(true, true), ok, o => o.ProjectId = " ").Status);

        var noConsent = Bind(new FakeTransport(), new Consent(true, false), ok);
        Assert.Equal("skipped_no_consent", noConsent.Status);
        Assert.Null(noConsent.InstallId);
        Assert.Equal(0, ok.Calls);
        Assert.Equal("skipped_no_consent", Bind(new FakeTransport(), Consent.None, ok).Status);

        var unsupported = Bind(new FakeTransport(), new Consent(true, true), null);
        Assert.Equal("unsupported", unsupported.Status);
        Assert.Null(unsupported.InstallId);

        var unavailable = Bind(new FakeTransport(), new Consent(true, true), new FakeTokens { Result = AdServicesTokenResult.Failed() });
        Assert.Equal("token_unavailable", unavailable.Status);
        // Token yoksa da hesap bağı için kurulum kimliği geçerlidir.
        Assert.Equal(26, unavailable.InstallId.Length);

        var oldIos = Bind(new FakeTransport(), new Consent(true, true), new FakeTokens { Result = AdServicesTokenResult.Unsupported() });
        Assert.Equal("unsupported", oldIos.Status);
        Assert.Equal(26, oldIos.InstallId.Length);

        var rejected = new FakeTransport();
        rejected.Responses.Enqueue(new TransportResponse(400, "{}"));
        Assert.Equal("rejected", Bind(rejected, new Consent(true, true), ok).Status);

        foreach (var status in new[] { 0, 429, 503 })
        {
            var flaky = new FakeTransport();
            flaky.Responses.Enqueue(new TransportResponse(status, "{}"));
            Assert.Equal("temporary_failure", Bind(flaky, new Consent(true, true), ok).Status);
        }

        var thrown = new FakeTransport { Throw = new InvalidOperationException("ağ") };
        Assert.Equal("temporary_failure", Bind(thrown, new Consent(true, true), ok).Status);
    }

    [Fact]
    public void BindInstallHonoursAttDenialAndWithdrawnConsent()
    {
        _tracking = TrackingStatus.Denied;
        InstallBinding result = null;
        var tokens = new FakeTokens();
        Make(new FakeTransport(), new Consent(true, true)).BindInstall(tokens, r => result = r);
        Assert.Equal("skipped_no_consent", result.Status);
        Assert.Equal(0, tokens.Calls);

        // Gönderim sırasında reklam izni geri çekilirse kimlik verilmez.
        _tracking = TrackingStatus.Authorized;
        var transport = new FakeTransport { Defer = true };
        var client = Make(transport, new Consent(true, true));
        InstallBinding late = null;
        client.BindInstall(tokens, r => late = r);
        client.SetConsent(new Consent(true, false));
        transport.Complete(0, new TransportResponse(202, "{}"));
        // Token gönderilmişti (Swift ile aynı: received), ama kimlik izin çekildiği için verilmez.
        Assert.Equal("received", late.Status);
        Assert.Null(late.InstallId);
    }

    [Fact]
    public void InstallIdIsRemovedWhenAdvertisingConsentIsWithdrawnOrReset()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true));
        InstallBinding first = null;
        client.BindInstall(new FakeTokens(), r => first = r);
        Assert.NotNull(first.InstallId);
        Assert.NotNull(new FileEventStore(_dir).GetMarker("install_id"));

        client.SetConsent(new Consent(true, false));
        Assert.Null(new FileEventStore(_dir).GetMarker("install_id"));

        client.SetConsent(new Consent(true, true));
        InstallBinding second = null;
        client.BindInstall(new FakeTokens(), r => second = r);
        Assert.NotEqual(first.InstallId, second.InstallId);

        client.Reset();
        Assert.Null(new FileEventStore(_dir).GetMarker("install_id"));
    }

    [Fact]
    public void BindInstallDoesNotInventDeviceIdentifiers()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true));
        client.BindInstall(new FakeTokens(), _ => { });
        var body = Encoding.UTF8.GetString(transport.Requests[0].Body);
        Assert.Equal(2, JsonDocument.Parse(body).RootElement.EnumerateObject().Count());
        Assert.DoesNotContain("idfa", body, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("device", body, StringComparison.OrdinalIgnoreCase);
    }
}
