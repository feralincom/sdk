using System.Text;
using System.Text.Json;
using Feralin.Unity;
using Xunit;

namespace Feralin.Unity.Core.Tests;

/// <summary>Fera Fly kısa link çözümlemesi: Android ve Swift SDK'larla aynı kurallar.</summary>
public class ShortLinkTests
{
    private const string Click = "clk_AbCdEfGh12345678";

    private static string Body(string path = "/urun/42", string click = Click) =>
        "{\"code\":\"kampanya\",\"destination\":\"https://apps.apple.com/app/id1\",\"deep_link_path\":"
        + (path == null ? "null" : "\"" + path + "\"")
        + ",\"utm\":{\"campaign\":\"yaz\",\"source\":\"ig\"},\"click_id\":"
        + (click == null ? "null" : "\"" + click + "\"") + ",\"rule\":\"ios_url\"}";

    private static FeralinClient Make(FakeTransport transport, Consent consent, string device = "android", string[] hosts = null)
    {
        var options = new FeralinOptions
        {
            ProjectKey = "pk_test_unity_short_1",
            CollectUrl = "https://collect.example.test/",
            Transport = transport,
            Consent = consent,
            Random = () => 1.0,
            ShortLinkDevice = device,
        };
        if (hosts != null)
        {
            options.ShortLinkHosts = hosts;
        }
        return new FeralinClient(options);
    }

    private static JsonElement[] SentEvents(FeralinClient client, FakeTransport transport)
    {
        client.Flush();
        return transport.Requests
            .Where(r => r.Method == "POST")
            .SelectMany(r => JsonDocument.Parse(r.Body).RootElement.GetProperty("events").EnumerateArray().Select(e => e.Clone()))
            .ToArray();
    }

    [Fact]
    public void HostRuleAcceptsOnlyHttpsListedHostOrSubdomain()
    {
        var hosts = new[] { "fera.fly" };
        Assert.True(ShortLinks.IsShortLink("https://fera.fly/abc", hosts));
        Assert.True(ShortLinks.IsShortLink("https://marka.fera.fly/abc", hosts));
        Assert.True(ShortLinks.IsShortLink("https://FERA.FLY/abc", hosts));
        Assert.False(ShortLinks.IsShortLink("http://fera.fly/abc", hosts));
        Assert.False(ShortLinks.IsShortLink("https://sahtefera.fly/abc", hosts));
        Assert.False(ShortLinks.IsShortLink("https://fera.fly.kotu.com/abc", hosts));
        Assert.False(ShortLinks.IsShortLink(null, hosts));
        Assert.False(ShortLinks.IsShortLink("https://fera.fly/abc", new string[0]));
    }

    [Fact]
    public void ParseDropsMalformedFields()
    {
        var ok = ShortLinks.Parse(Body());
        Assert.Equal("kampanya", ok.Code);
        Assert.Equal("/urun/42", ok.DeepLinkPath);
        Assert.Equal(Click, ok.ClickId);
        Assert.Equal("yaz", ok.Utm["campaign"]);

        var bad = ShortLinks.Parse("{\"code\":\"k1\",\"deep_link_path\":\"//kotu.com/x\",\"click_id\":\"kisa\",\"utm\":{\"email\":\"a@b.c\",\"campaign\":\"yaz\"}}");
        Assert.Null(bad.DeepLinkPath);
        Assert.Null(bad.ClickId);
        Assert.Equal(new[] { "campaign" }, bad.Utm.Keys.ToArray());

        Assert.Null(ShortLinks.Parse("<html>"));
        Assert.Null(ShortLinks.Parse("[]"));
        Assert.Null(ShortLinks.Parse("{\"code\":\"../x\"}"));
        Assert.Null(ShortLinks.Parse(""));
    }

    [Fact]
    public void SyntheticUrlKeepsHostAndCarriesEvidence()
    {
        Assert.Equal(
            "https://marka.fera.fly/urun/42?fr_click=" + Click + "&utm_campaign=yaz&utm_source=ig",
            ShortLinks.SyntheticUrl("https://marka.fera.fly/kampanya?gizli=1", ShortLinks.Parse(Body())));
        Assert.Equal("https://fera.fly/", ShortLinks.SyntheticUrl("https://fera.fly/k", ShortLinks.Parse("{\"code\":\"k\"}")));
    }

    [Fact]
    public void ShortLinkIsResolvedWithGetAndEventCarriesClickAndUtm()
    {
        var transport = new FakeTransport();
        transport.Responses.Enqueue(new TransportResponse(200, Body()));
        var client = Make(transport, new Consent(true, true), device: "ios");
        ShortLinkOpen open = null;
        client.HandleShortLink("https://marka.fera.fly/kampanya", result => open = result);

        Assert.Equal("/urun/42", open.Destination);
        Assert.Equal("kampanya", open.LinkCode);
        Assert.True(open.HasClickId);
        Assert.Equal("kampanya", client.LastShortLink.Code);
        var get = transport.Requests[0];
        Assert.Equal("GET", get.Method);
        Assert.Equal("https://marka.fera.fly/kampanya", get.Url);
        Assert.Empty(get.Body);
        Assert.Equal("application/vnd.feralin.link+json", get.Headers["Accept"]);
        Assert.Contains("iPhone", get.Headers["User-Agent"]);
        Assert.False(get.Headers.ContainsKey("Feralin-Attribution"));
        Assert.False(get.Headers.ContainsKey("x-feralin-project-key"));

        var e = Assert.Single(SentEvents(client, transport));
        Assert.Equal("deep_link_opened", e.GetProperty("event_name").GetString());
        Assert.Equal("https://marka.fera.fly/urun/42", e.GetProperty("context").GetProperty("page_url").GetString());
        var props = e.GetProperty("properties");
        Assert.Equal(Click, props.GetProperty("fr_click").GetString());
        Assert.Equal("yaz", props.GetProperty("utm_campaign").GetString());
    }

    [Fact]
    public void HandleDeepLinkAlsoResolvesShortLinks()
    {
        var transport = new FakeTransport();
        transport.Responses.Enqueue(new TransportResponse(200, Body()));
        var client = Make(transport, new Consent(true, true));
        client.HandleDeepLink("https://fera.fly/kampanya");
        Assert.Equal("/urun/42", client.LastShortLink.DeepLinkPath);
        Assert.Contains("Android", transport.Requests[0].Headers["User-Agent"]);
        Assert.Single(SentEvents(client, transport));
    }

    [Fact]
    public void WithoutAdvertisingConsentEvidenceIsNeitherRequestedNorSent()
    {
        var transport = new FakeTransport();
        transport.Responses.Enqueue(new TransportResponse(200, Body()));
        var client = Make(transport, new Consent(true, false));
        client.HandleShortLink("https://fera.fly/kampanya", _ => { });
        Assert.Equal("off", transport.Requests[0].Headers["Feralin-Attribution"]);
        var props = Assert.Single(SentEvents(client, transport)).GetProperty("properties");
        Assert.False(props.TryGetProperty("fr_click", out _));
        Assert.Equal("none", props.GetProperty("attribution_source").GetString());
    }

    [Fact]
    public void WithoutAnalyticsOrBeforeDecisionNoRequestIsMade()
    {
        var denied = new FakeTransport();
        ShortLinkOpen open = null;
        Make(denied, Consent.None).HandleShortLink("https://fera.fly/kampanya", r => open = r);
        Assert.Empty(denied.Requests);
        Assert.Equal("/kampanya", open.Destination);
        Assert.Null(open.LinkCode);

        var pending = new FakeTransport();
        var client = Make(pending, null);
        client.HandleDeepLink("https://fera.fly/kampanya");
        Assert.Empty(pending.Requests);
        Assert.Equal(0, client.GetStatus().Queued);
    }

    [Fact]
    public void LinksWithClickOrOtherHostsAreNotResolved()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true));
        client.HandleDeepLink("https://fera.fly/urun?fr_click=" + Click);
        client.HandleDeepLink("https://link.feralin.com/kampanya");
        Assert.All(transport.Requests, r => Assert.Equal("POST", r.Method));
        Assert.Equal(2, SentEvents(client, transport).Length);
    }

    [Theory]
    [InlineData(0, "")]
    [InlineData(404, "{}")]
    [InlineData(200, "<html>")]
    public void FailedResolutionCountsTheOriginalLinkOnce(int status, string body)
    {
        var transport = new FakeTransport();
        transport.Responses.Enqueue(new TransportResponse(status, body));
        var client = Make(transport, new Consent(true, true));
        ShortLinkOpen open = null;
        client.HandleShortLink("https://fera.fly/kampanya", r => open = r);
        Assert.Equal("/kampanya", open.Destination);
        Assert.Null(client.LastShortLink);
        var e = Assert.Single(SentEvents(client, transport));
        Assert.Equal("https://fera.fly/kampanya", e.GetProperty("context").GetProperty("page_url").GetString());
    }

    [Fact]
    public void TransportExceptionDoesNotLeak()
    {
        var transport = new FakeTransport { Throw = new System.InvalidOperationException("ağ") };
        var client = Make(transport, new Consent(true, true));
        ShortLinkOpen open = null;
        client.HandleShortLink("https://fera.fly/kampanya", r => open = r);
        Assert.Equal("/kampanya", open.Destination);
        Assert.Equal(1, client.GetStatus().Queued);
    }

    [Fact]
    public void BrandedHostCanBeAdded()
    {
        var transport = new FakeTransport();
        transport.Responses.Enqueue(new TransportResponse(200, Body()));
        var client = Make(transport, new Consent(true, true), hosts: new[] { "fera.fly", "go.marka.com" });
        client.HandleDeepLink("https://go.marka.com/kampanya");
        Assert.Equal("GET", transport.Requests[0].Method);
        Assert.Equal("kampanya", client.LastShortLink.Code);
    }
}
