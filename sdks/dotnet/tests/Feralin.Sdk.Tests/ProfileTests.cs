using System.Net;
using System.Text.Json;
using Xunit;

namespace Feralin.Tests;

/// <summary>UTP §8.2 kimlik yöntemleri: Group, SetUserProperties, SetGlobalProperties (toplayıcı profile_filter.go ile aynı kurallar).</summary>
public class ProfileTests
{
    private const string Key = "pk_test_dotnet_unit_0001";

    private sealed class Capture : HttpMessageHandler
    {
        public List<string> Bodies { get; } = new();

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Bodies.Add(request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken));
            return new HttpResponseMessage(HttpStatusCode.Accepted) { Content = new StringContent("{\"batch_id\":\"b\",\"accepted\":1,\"rejected\":0}") };
        }
    }

    private static FeralinClient Client(Capture handler, List<string>? warnings = null) =>
        new(new FeralinOptions
        {
            ProjectKey = Key,
            CollectUrl = "http://collector.test",
            FlushInterval = TimeSpan.Zero,
            HttpHandler = handler,
            Consent = new Consent(true),
            Log = (level, message) => warnings?.Add(message),
        });

    private static Dictionary<string, object?> Props(params (string Key, object? Value)[] pairs) => pairs.ToDictionary(p => p.Key, p => p.Value);

    private static async Task<List<JsonElement>> Events(FeralinClient client, Capture handler)
    {
        await client.FlushAsync();
        return handler.Bodies.SelectMany(body => JsonDocument.Parse(body).RootElement.GetProperty("events").EnumerateArray().Select(e => e.Clone())).ToList();
    }

    [Theory]
    [InlineData("email", true)]
    [InlineData("userEmail", true)]
    [InlineData("contact_email_address", true)]
    [InlineData("phone_number", true)]
    [InlineData("phoneNumber", true)]
    [InlineData("userIP", true)]
    [InlineData("ipv4", true)]
    [InlineData("first_name", true)]
    [InlineData("lastName", true)]
    [InlineData("name", true)]
    [InlineData("username", true)]
    [InlineData("ad", true)]
    [InlineData("soyadi", true)]
    [InlineData("home_address", true)]
    [InlineData("tckn", true)]
    [InlineData("plan", false)]
    [InlineData("plan_name", false)]
    [InlineData("zip", false)]
    [InlineData("hotel_tier", false)]
    [InlineData("membership", false)]
    [InlineData("ad_network", false)]
    public void Kisisel_veri_anahtari_kurali_toplayiciyla_ayni(string key, bool pii)
    {
        Assert.Equal(pii, ProfileRules.IsPiiLikeKey(key));
    }

    [Fact]
    public async Task SetUserProperties_kisisel_veri_ayrilmis_ve_sozlesme_disi_degeri_duser()
    {
        var handler = new Capture();
        var warnings = new List<string>();
        await using var client = Client(handler, warnings);
        var tracked = client.SetUserProperties(
            Props(("plan", "pro"), ("tier", 2), ("beta", true), ("email", "a@b.co"), ("verified", true), ("note", new string('x', 257)),
                ("nested", new Dictionary<string, object?> { ["a"] = 1 }), ("list", new[] { 1 }), ("ratio", double.NaN), ("contact", "x@y.io"), ("bad-key", 1)),
            new TrackOptions { UserId = "u_1" });
        Assert.NotNull(tracked);
        Assert.Equal("fr_user_properties", tracked!.EventName);
        Assert.Equal(new[] { "beta", "plan", "tier" }, tracked.Properties.Keys.OrderBy(k => k, StringComparer.Ordinal));
        Assert.Contains(warnings, w => w.Contains("8 özellik"));
        var events = await Events(client, handler);
        var props = events.Single().GetProperty("properties");
        Assert.Equal("pro", props.GetProperty("plan").GetString());
        Assert.Equal("u_1", events.Single().GetProperty("user_id").GetString());
    }

    [Fact]
    public void SetUserProperties_gecerli_ozellik_yoksa_olay_uretmez()
    {
        using var client = Client(new Capture());
        Assert.Null(client.SetUserProperties(Props(("email", "x"), ("phone", "1"))));
        Assert.Null(client.SetUserProperties(Props()));
    }

    [Fact]
    public void SetUserProperties_cagri_basina_elli_ozellik()
    {
        using var client = Client(new Capture());
        var many = Enumerable.Range(0, 70).Select(i => new KeyValuePair<string, object?>($"k{i}", i));
        Assert.Equal(ProfileRules.MaxProperties, client.SetUserProperties(many)!.Properties.Count);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("ekip@acme.com")]
    [InlineData("a\u0001b")]
    public void Group_gecersiz_kimlikte_olay_uretmez(string groupId)
    {
        using var client = Client(new Capture());
        Assert.Null(client.Group(groupId));
        Assert.Null(client.Group(new string('g', 129)));
    }

    [Fact]
    public async Task Group_group_id_ve_temiz_ozellik_tasir()
    {
        var handler = new Capture();
        await using var client = Client(handler);
        var tracked = client.Group("acme-team", Props(("plan", "team"), ("group_id", "sahte"), ("owner_email", "x"), ("seats", 12)));
        Assert.NotNull(tracked);
        Assert.Equal("fr_group", tracked!.EventName);
        Assert.Equal("acme-team", tracked.Properties["group_id"]);
        Assert.False(tracked.Properties.ContainsKey("owner_email"));
        var props = (await Events(client, handler)).Single().GetProperty("properties");
        Assert.Equal("team", props.GetProperty("plan").GetString());
        Assert.Equal(12, props.GetProperty("seats").GetInt32());
    }

    [Fact]
    public async Task Global_ozellikler_birlesir_olay_ozelligi_ezer_null_siler_fr_olayina_eklenmez()
    {
        var handler = new Capture();
        await using var client = Client(handler);
        client.SetGlobalProperties(Props(("app_release", "1.2.0"), ("region", "eu"), ("email", "x")));
        client.SetGlobalProperties(Props(("region", null), ("channel", "web")));
        var plain = client.Track("checkout_started", Props(("channel", "api")))!;
        var profile = client.SetUserProperties(Props(("plan", "pro")))!;
        var group = client.Group("acme")!;
        Assert.Equal("1.2.0", plain.Properties["app_release"]);
        Assert.Equal("api", plain.Properties["channel"]);
        Assert.False(plain.Properties.ContainsKey("region"));
        Assert.False(plain.Properties.ContainsKey("email"));
        Assert.False(profile.Properties.ContainsKey("app_release"));
        Assert.False(group.Properties.ContainsKey("app_release"));
        client.ClearGlobalProperties();
        var after = client.Track("checkout_started")!;
        Assert.False(after.Properties.ContainsKey("app_release"));
        Assert.Equal(4, (await Events(client, handler)).Count);
    }

    [Fact]
    public void Global_ozellik_toplami_elliyi_asmaz()
    {
        using var client = Client(new Capture());
        client.SetGlobalProperties(Enumerable.Range(0, 40).Select(i => new KeyValuePair<string, object?>($"a{i}", i)));
        client.SetGlobalProperties(Enumerable.Range(0, 40).Select(i => new KeyValuePair<string, object?>($"b{i}", i)));
        var tracked = client.Track("page_view")!;
        Assert.Equal(ProfileRules.MaxProperties, tracked.Properties.Count);
    }
}
