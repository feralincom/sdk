using System.Security.Cryptography;
using System.Text.Json;
using Feralin.Unity;
using Xunit;

namespace Feralin.Unity.Core.Tests;

/// <summary>SDK imzası (<c>fr_sig</c>), emülatör işareti (<c>device_emulator</c>) ve Huawei AppGallery kurulum yönlendiricisi.</summary>
public class EventSignerTests
{
    [Fact]
    public void SignatureMatchesServer()
    {
        // Beklenen değer sunucu uygulamasıyla (Node, HMAC-SHA256) aynı girdiden hesaplandı.
        Assert.Equal(
            "v1.sgn_0123456789abcdef.1795000000.6f939a78369f2fb6cb3aa73fcc800d17e783292a926b865e2becac05f6b6def7",
            EventSigner.Sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-1", "app_first_open", "anon-1"));
    }

    [Fact]
    public void SignatureIsBoundToEventInstallAndKey()
    {
        var signed = EventSigner.Sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-1", "app_first_open", "anon-1");
        Assert.NotEqual(signed, EventSigner.Sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-2", "app_first_open", "anon-1"));
        Assert.NotEqual(signed, EventSigner.Sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-1", "app_first_open", "anon-2"));
        Assert.NotEqual(signed, EventSigner.Sign("sgn_0123456789abcdef", "fsk_baska", 1_795_000_000L, "evt-1", "app_first_open", "anon-1"));
        // Kimliksiz olayda boş dizgi imzalanır.
        Assert.Equal(
            EventSigner.Sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-1", "app_first_open", ""),
            EventSigner.Sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-1", "app_first_open", null));
    }

    [Fact]
    public void SignatureDoesNotDependOnCulture()
    {
        var previous = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("ar-SA");
            Assert.Equal(
                "v1.sgn_0123456789abcdef.1795000000.6f939a78369f2fb6cb3aa73fcc800d17e783292a926b865e2becac05f6b6def7",
                EventSigner.Sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-1", "app_first_open", "anon-1"));
        }
        finally
        {
            System.Globalization.CultureInfo.CurrentCulture = previous;
        }
    }

    [Fact]
    public void SigningKeyFormatIsCheckedAndSecretIsNeverPrinted()
    {
        Assert.Null(new SigningKey("sgn_0123456789abcdef", "fsk_gizli_anahtar_degeri").ValidationError());
        Assert.NotNull(new SigningKey("anahtar", "fsk_gizli_anahtar_degeri").ValidationError());
        Assert.NotNull(new SigningKey("sgn_KISA", "fsk_gizli_anahtar_degeri").ValidationError());
        Assert.NotNull(new SigningKey("sgn_0123456789abcdef\n", "fsk_gizli_anahtar_degeri").ValidationError());
        Assert.NotNull(new SigningKey(null, "fsk_gizli_anahtar_degeri").ValidationError());
        Assert.NotNull(new SigningKey("sgn_0123456789abcdef", "kisa").ValidationError());
        Assert.NotNull(new SigningKey("sgn_0123456789abcdef", new string('x', 201)).ValidationError());
        Assert.NotNull(new SigningKey("sgn_0123456789abcdef", null).ValidationError());
        Assert.DoesNotContain("fsk_", new SigningKey("sgn_0123456789abcdef", "fsk_gizli_anahtar_degeri").ToString());
    }
}

public class EmulatorCheckTests
{
    [Fact]
    public void CommonEmulatorsAreRecognized()
    {
        // Android Studio emülatörü (API 34, Google API'li görüntü).
        Assert.True(EmulatorCheck.IsEmulator("google/sdk_gphone64_x86_64/emu64xa:14/UE1A.230829.036/11228894:userdebug/dev-keys", "sdk_gphone64_x86_64", "Google", "google", "emu64xa", "sdk_gphone64_x86_64", "ranchu"));
        // Eski AOSP emülatörü.
        Assert.True(EmulatorCheck.IsEmulator("generic/sdk/generic:4.4.2/KK/eng.build:eng/test-keys", "Android SDK built for x86", "unknown", "generic", "generic", "sdk", "goldfish"));
        Assert.True(EmulatorCheck.IsEmulator("x", "Custom Phone", "Genymotion", "x", "x", "vbox86p", "vbox86"));
    }

    [Fact]
    public void RealDevicesAreNotEmulators()
    {
        Assert.False(EmulatorCheck.IsEmulator("samsung/a54xnaeea/a54x:14/UP1A.231005.007/A546BXXS7CXE4:user/release-keys", "SM-A546B", "samsung", "samsung", "a54x", "a54xnaeea", "s5e8835"));
        Assert.False(EmulatorCheck.IsEmulator("google/husky/husky:14/AP1A.240405.002/11480754:user/release-keys", "Pixel 8 Pro", "Google", "google", "husky", "husky", "husky"));
        Assert.False(EmulatorCheck.IsEmulator(null, null, null, null, null, null, null));
    }

    [Theory]
    [InlineData("generic_x86/x:1/a/b:user/keys", null, null, null, null, null, null)]
    [InlineData("unknown", null, null, null, null, null, null)]
    [InlineData("x/vbox86p/y", null, null, null, null, null, null)]
    [InlineData(null, "google_sdk", null, null, null, null, null)]
    [InlineData(null, "Android Emulator", null, null, null, null, null)]
    [InlineData(null, null, null, "generic_x86", "generic_x86", null, null)]
    [InlineData(null, null, null, null, null, "google_sdk", null)]
    [InlineData(null, null, null, null, null, "sdk_google_phone_x86", null)]
    [InlineData(null, null, null, null, null, "full_emulator_x86", null)]
    [InlineData(null, null, null, null, null, "ios_simulator", null)]
    [InlineData(null, null, null, null, null, null, "goldfish")]
    [InlineData(null, null, null, null, null, null, "ranchu")]
    public void EachRuleIsEnoughOnItsOwn(string fingerprint, string model, string manufacturer, string brand, string device, string product, string hardware)
    {
        Assert.True(EmulatorCheck.IsEmulator(fingerprint, model, manufacturer, brand, device, product, hardware));
    }

    [Fact]
    public void GenericBrandAloneIsNotEnough()
    {
        // Marka ve cihaz birlikte "generic" olmalı; yalnız biri gerçek cihazda da görülebilir.
        Assert.False(EmulatorCheck.IsEmulator(null, null, null, "generic", "a54x", null, null));
        Assert.False(EmulatorCheck.IsEmulator(null, "emulator", null, null, null, null, null));
    }
}

public class HuaweiInstallReferrerTests
{
    private sealed class FakeHuawei : IHuaweiReferrerSource
    {
        public int Reads { get; private set; }
        public string Value { get; set; }
        public bool Throw { get; set; }

        public string Read()
        {
            Reads++;
            if (Throw)
            {
                throw new InvalidOperationException("sağlayıcı görünmüyor");
            }
            return Value;
        }
    }

    [Fact]
    public void ReferrerGoesThroughAllowlistAndSourceIsHuawei()
    {
        var p = HuaweiInstallReferrer.Parse("fr_click=clk_hw_1&utm_source=petal&fr_dl=%2Furun%2F42&email=a%40b.c");
        Assert.Equal("clk_hw_1", p.FrClick);
        Assert.Equal("petal", Assert.Single(p.Utm).Value);
        Assert.Equal("/urun/42", p.DeepLinkPath);
        Assert.Equal("huawei_install_referrer", p.Source);
    }

    [Fact]
    public void NoEvidenceIsNull()
    {
        Assert.Null(HuaweiInstallReferrer.Parse(null));
        Assert.Null(HuaweiInstallReferrer.Parse(""));
        // İzin listesinde hiçbir alan yok: kanıt sayılmaz.
        Assert.Null(HuaweiInstallReferrer.Parse("channel=abc&taskid=7"));
        Assert.Null(HuaweiInstallReferrer.Parse("fr_click=" + new string('a', 3000)));
    }

    [Fact]
    public void HuaweiIsNotAskedWhenPlayHasEvidence()
    {
        var huawei = new FakeHuawei { Value = "fr_click=clk_hw" };
        var result = StoreReferrerChain.Resolve("fr_click=clk_play&utm_source=ads", huawei);
        Assert.Equal("clk_play", result.FrClick);
        Assert.Equal("play_install_referrer", result.Source);
        Assert.Equal(0, huawei.Reads);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("gclid=x")]
    [InlineData("utm_source=google-play&utm_medium=organic")]
    public void HuaweiIsReadWhenPlayHasNoEvidence(string play)
    {
        var huawei = new FakeHuawei { Value = "fr_click=clk_hw" };
        var result = StoreReferrerChain.Resolve(play, huawei);
        Assert.Equal("clk_hw", result.FrClick);
        Assert.Equal("huawei_install_referrer", result.Source);
        Assert.Equal(1, huawei.Reads);
    }

    [Fact]
    public void PlayResultIsKeptWhenNeitherHasEvidence()
    {
        var organic = StoreReferrerChain.Resolve("utm_medium=organic", new FakeHuawei());
        Assert.True(organic.IsPlayOrganicDefault);
        Assert.Equal("play_install_referrer", organic.Source);
        Assert.Null(StoreReferrerChain.Resolve(null, new FakeHuawei()));
        Assert.Null(StoreReferrerChain.Resolve(null, null));
        // Sağlayıcı hatası kanıt yok sayılır.
        Assert.Null(StoreReferrerChain.Resolve(null, new FakeHuawei { Throw = true }));
    }
}

public class FraudSignalsClientTests : IDisposable
{
    private const string Key = "pk_test_unity_key_0001";
    private static readonly SigningKey Signing = new("sgn_0123456789abcdef", "fsk_gizli_anahtar_degeri");
    private readonly List<string> _dirs = new();
    private readonly List<string> _logs = new();
    private readonly DateTimeOffset _now = new(2026, 11, 18, 10, 0, 0, TimeSpan.Zero);

    public void Dispose()
    {
        foreach (var dir in _dirs)
        {
            try
            {
                Directory.Delete(dir, true);
            }
            catch (IOException)
            {
            }
        }
    }

    private sealed class FakeReferrer : IInstallReferrerSource
    {
        public int Reads { get; private set; }
        public string Referrer { get; set; }

        public void Read(Action<string> onResult)
        {
            Reads++;
            onResult(Referrer);
        }
    }

    private sealed class FakeHuawei : IHuaweiReferrerSource
    {
        public int Reads { get; private set; }
        public string Value { get; set; }

        public string Read()
        {
            Reads++;
            return Value;
        }
    }

    private sealed class FakeEmulator : IEmulatorSource
    {
        public int Reads { get; private set; }
        public bool Value { get; set; }
        public bool Throw { get; set; }

        public bool Read()
        {
            Reads++;
            if (Throw)
            {
                throw new InvalidOperationException("Build okunamadı");
            }
            return Value;
        }
    }

    // Her istemci ayrı dizinde: bir testteki ikinci kurulum ilkinin ilk açılış işaretini görmez.
    private FeralinClient Make(FakeTransport transport, Consent consent, Action<FeralinOptions> edit = null)
    {
        var dir = Path.Combine(Path.GetTempPath(), "feralin-unity-fraud-" + Guid.NewGuid().ToString("N"));
        _dirs.Add(dir);
        var options = new FeralinOptions
        {
            ProjectKey = Key,
            CollectUrl = "https://collect.example.test/",
            Transport = transport,
            Consent = consent,
            Clock = () => _now,
            Random = () => 1.0,
            Store = new EncryptedEventStore(new FileEventStore(dir), new AesGcmPayloadCipher(RandomNumberGenerator.GetBytes(32))),
            Log = (_, message) => _logs.Add(message),
        };
        edit?.Invoke(options);
        return new FeralinClient(options);
    }

    private static JsonElement[] SentEvents(FeralinClient client, FakeTransport transport)
    {
        client.Flush();
        return transport.Requests
            .SelectMany(r => JsonDocument.Parse(r.Body).RootElement.GetProperty("events").EnumerateArray().Select(e => e.Clone()).ToArray())
            .ToArray();
    }

    private static string ExpectedSignature(JsonElement e) => EventSigner.Sign(
        Signing.Id,
        Signing.Secret,
        e.GetProperty("occurred_at").GetDateTimeOffset().ToUnixTimeSeconds(),
        e.GetProperty("event_id").GetString(),
        e.GetProperty("event_name").GetString(),
        e.TryGetProperty("anonymous_id", out var anonymous) ? anonymous.GetString() : "");

    [Fact]
    public void OnlyFirstOpenAndDeepLinkAreSigned()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true), o => o.SigningKey = Signing);
        client.SetAnonymousId("anon-1");
        client.StartAttribution(new FakeReferrer { Referrer = "fr_click=clk_1" });
        client.HandleDeepLink("https://go.example.com/o?fr_click=clk_2");
        client.Track("purchase", new Dictionary<string, object> { ["value"] = 1 });
        var events = SentEvents(client, transport);
        Assert.Equal(new[] { "app_first_open", "deep_link_opened", "purchase" }, events.Select(e => e.GetProperty("event_name").GetString()).ToArray());
        foreach (var e in events.Take(2))
        {
            Assert.Equal("anon-1", e.GetProperty("anonymous_id").GetString());
            var signature = e.GetProperty("properties").GetProperty("fr_sig").GetString();
            Assert.Equal(ExpectedSignature(e), signature);
            Assert.StartsWith("v1.sgn_0123456789abcdef." + _now.ToUnixTimeSeconds() + ".", signature);
        }
        Assert.False(events[2].GetProperty("properties").TryGetProperty("fr_sig", out _));
        // Anahtar değeri gövdeye ve loglara düşmez.
        Assert.All(transport.Requests, r => Assert.DoesNotContain(Signing.Secret, System.Text.Encoding.UTF8.GetString(r.Body)));
        Assert.All(_logs, message => Assert.DoesNotContain(Signing.Secret, message));
    }

    [Fact]
    public void EventWithoutAnonymousIdSignsEmptyString()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, false), o => o.SigningKey = Signing);
        client.StartAttribution(new FakeReferrer());
        var open = Assert.Single(SentEvents(client, transport));
        Assert.False(open.TryGetProperty("anonymous_id", out _));
        Assert.Equal(ExpectedSignature(open), open.GetProperty("properties").GetProperty("fr_sig").GetString());
    }

    [Fact]
    public void NoSigningKeyMeansNoSignature()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true));
        client.StartAttribution(new FakeReferrer { Referrer = "fr_click=clk_1" });
        client.HandleDeepLink("https://go.example.com/o?fr_click=clk_2");
        Assert.All(SentEvents(client, transport), e => Assert.False(e.GetProperty("properties").TryGetProperty("fr_sig", out _)));
    }

    [Theory]
    [InlineData("anahtar", "fsk_gizli_anahtar_degeri")]
    [InlineData("sgn_0123456789abcdef", "kisa_gizli")]
    [InlineData("", "")]
    public void InvalidSigningKeyIsAConfigurationErrorWithoutTheSecret(string id, string secret)
    {
        var error = Assert.Throws<ArgumentException>(() => Make(new FakeTransport(), new Consent(true, true), o => o.SigningKey = new SigningKey(id, secret)));
        if (secret.Length > 0)
        {
            Assert.DoesNotContain(secret, error.Message);
        }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void EmulatorFlagIsAddedToFirstOpenOnlyWhenTrue(bool advertising)
    {
        var emulator = new FakeEmulator { Value = true };
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, advertising), o => o.EmulatorSource = emulator);
        client.StartAttribution(new FakeReferrer());
        client.Track("purchase", new Dictionary<string, object> { ["value"] = 1 });
        var events = SentEvents(client, transport);
        Assert.True(events[0].GetProperty("properties").GetProperty("device_emulator").GetBoolean());
        Assert.False(events[1].GetProperty("properties").TryGetProperty("device_emulator", out _));
        Assert.Equal(1, emulator.Reads);

        var real = new FakeEmulator { Value = false };
        var realTransport = new FakeTransport();
        var realClient = Make(realTransport, new Consent(true, advertising), o => o.EmulatorSource = real);
        realClient.StartAttribution(new FakeReferrer());
        Assert.False(Assert.Single(SentEvents(realClient, realTransport)).GetProperty("properties").TryGetProperty("device_emulator", out _));
        Assert.Equal(1, real.Reads);
    }

    [Fact]
    public void EmulatorReadFailureDoesNotBlockFirstOpen()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true), o => o.EmulatorSource = new FakeEmulator { Throw = true });
        client.StartAttribution(new FakeReferrer { Referrer = "fr_click=clk_1" });
        var props = Assert.Single(SentEvents(client, transport)).GetProperty("properties");
        Assert.False(props.TryGetProperty("device_emulator", out _));
        Assert.Equal("play_install_referrer", props.GetProperty("attribution_source").GetString());

        // Kaynak verilmemiş (iOS, Editor): alan yok.
        var bareTransport = new FakeTransport();
        var bare = Make(bareTransport, new Consent(true, true));
        bare.StartAttribution(new FakeReferrer());
        Assert.False(Assert.Single(SentEvents(bare, bareTransport)).GetProperty("properties").TryGetProperty("device_emulator", out _));
    }

    [Fact]
    public void FirstOpenUsesHuaweiReferrerWhenPlayHasNoEvidence()
    {
        var huawei = new FakeHuawei { Value = "fr_click=clk_hw_1&utm_source=petal&fr_dl=%2Furun%2F42&email=a%40b.c" };
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true), o => o.HuaweiReferrerSource = huawei);
        client.StartAttribution(new FakeReferrer());
        var open = Assert.Single(SentEvents(client, transport));
        var props = open.GetProperty("properties");
        Assert.Equal("huawei_install_referrer", props.GetProperty("attribution_source").GetString());
        Assert.Equal("clk_hw_1", props.GetProperty("fr_click").GetString());
        Assert.Equal("petal", props.GetProperty("utm_source").GetString());
        Assert.DoesNotContain("a@b.c", open.GetRawText());
        Assert.Equal(1, huawei.Reads);
        // Ertelenmiş derin bağlantı yolu AppGallery kanıtından da teslim edilir.
        Assert.Equal("/urun/42", client.ConsumeDeferredDeepLink());
    }

    [Fact]
    public void PlayEvidenceWinsAndHuaweiIsNotRead()
    {
        var huawei = new FakeHuawei { Value = "fr_click=clk_hw" };
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, true), o => o.HuaweiReferrerSource = huawei);
        client.StartAttribution(new FakeReferrer { Referrer = "fr_click=clk_play" });
        var props = Assert.Single(SentEvents(client, transport)).GetProperty("properties");
        Assert.Equal("play_install_referrer", props.GetProperty("attribution_source").GetString());
        Assert.Equal("clk_play", props.GetProperty("fr_click").GetString());
        Assert.Equal(0, huawei.Reads);
    }

    [Fact]
    public void HuaweiIsNotReadWithoutAdvertisingConsentAndFollowsUpWhenConsentArrives()
    {
        var huawei = new FakeHuawei { Value = "fr_click=clk_hw" };
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true, false), o => o.HuaweiReferrerSource = huawei);
        client.StartAttribution(new FakeReferrer());
        var open = Assert.Single(SentEvents(client, transport));
        Assert.Equal("none", open.GetProperty("properties").GetProperty("attribution_source").GetString());
        Assert.Equal(0, huawei.Reads);

        client.SetConsent(new Consent(true, true));
        var followUp = SentEvents(client, transport).Last();
        Assert.Equal("deep_link_opened", followUp.GetProperty("event_name").GetString());
        var props = followUp.GetProperty("properties");
        Assert.Equal("huawei_install_referrer", props.GetProperty("attribution_source").GetString());
        Assert.Equal("clk_hw", props.GetProperty("fr_click").GetString());
        Assert.True(props.GetProperty("consent_followup").GetBoolean());
        Assert.Equal(1, huawei.Reads);
    }
}
