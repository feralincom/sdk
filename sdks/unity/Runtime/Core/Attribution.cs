using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace Feralin.Unity
{
    /// <summary>Olaylardaki <c>properties.attribution_source</c> değerleri (Android SDK ile aynı).</summary>
    public static class AttributionSource
    {
        /// <summary>Google Play Install Referrer.</summary>
        public const string PlayInstallReferrer = "play_install_referrer";
        /// <summary>Uygulama bağlantısı (Android App Link, iOS Universal Link).</summary>
        public const string AppLink = "app_link";
        /// <summary>Kanıt yok ya da reklam izni yok.</summary>
        public const string None = "none";
    }

    /// <summary>
    /// Referrer veya URL'den alınmasına izin verilen tek veri: <c>fr_click</c> ve standart <c>utm_*</c>. Bilinmeyen parametre okunmaz ve
    /// hiçbir yerde saklanmaz. Kurallar Android SDK'daki <c>AttributionParams</c> ile aynıdır.
    /// </summary>
    public sealed class AttributionParams
    {
        /// <summary>Boş küme.</summary>
        public static readonly AttributionParams Empty = new AttributionParams(null, new Dictionary<string, string>(), null);

        private const string FrClickKey = "fr_click";
        private const string FrDeepLinkKey = "fr_dl";
        private const int MaxDeepLinkLength = 200;
        private const int MaxValueLength = 256;

        // Link-router ve saas-api ile aynı kural: şema ve host taşıyamaz, yalnız uygulama içi yol.
        private static readonly Regex DeepLinkPattern = new Regex("^/[A-Za-z0-9._~!$'()*+,;=:@%/?&-]*$", RegexOptions.CultureInvariant);

        // Kodlanmış nokta, bölü, ters bölü, kontrol karakteri ya da bozuk kaçış: %2e%2e birleştirmede üst dizine çıkar.
        private static readonly Regex DeepLinkUnsafeEscape = new Regex("%(?:2e|2f|5c|0[0-9a-f]|1[0-9a-f]|7f|[^0-9a-f]|[0-9a-f](?:[^0-9a-f]|$)|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        private static readonly Regex FrClickPattern = new Regex("^[A-Za-z0-9._~-]{1,256}$", RegexOptions.CultureInvariant);
        private static readonly HashSet<string> UtmKeys = new HashSet<string>(StringComparer.Ordinal) { "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content" };

        internal AttributionParams(string frClick, IReadOnlyDictionary<string, string> utm, string deepLinkPath)
        {
            FrClick = frClick;
            Utm = utm;
            DeepLinkPath = deepLinkPath;
        }

        /// <summary>Feralin link tıklama kimliği.</summary>
        public string FrClick { get; }
        /// <summary>İzin listesindeki <c>utm_*</c> değerleri.</summary>
        public IReadOnlyDictionary<string, string> Utm { get; }
        /// <summary>Ertelenmiş derin bağlantı yolu (yalnız <c>fr_click</c> ile birlikte).</summary>
        public string DeepLinkPath { get; }

        /// <summary>Kanıt yok.</summary>
        public bool IsEmpty => FrClick == null && Utm.Count == 0;

        /// <summary>Play'in tıklama yokken döndürdüğü varsayılan (<c>organic</c> / <c>(not set)</c>) kanıt sayılmaz.</summary>
        public bool IsPlayOrganicDefault =>
            FrClick == null && ((Utm.TryGetValue("utm_medium", out var medium) && string.Equals(medium, "organic", StringComparison.OrdinalIgnoreCase))
                || (Utm.TryGetValue("utm_source", out var source) && source == "(not set)"));

        /// <summary>Kanıtı olay özelliklerine yazar.</summary>
        public void WriteTo(IDictionary<string, object> target)
        {
            if (FrClick != null)
            {
                target[FrClickKey] = FrClick;
            }
            foreach (var pair in Utm)
            {
                target[pair.Key] = pair.Value;
            }
        }

        /// <summary><c>a=b&amp;c=d</c> dizgisini izin listesiyle ayrıştırır; bozuk kodlanmış parça yok sayılır, aynı anahtarın ilk değeri geçerlidir.</summary>
        public static AttributionParams ParseQuery(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw))
            {
                return Empty;
            }
            // Bazı kampanya araçları referrer'ın tamamını bir kez daha kodlar.
            var text = raw.IndexOf('=') < 0 && raw.IndexOf("%3D", StringComparison.OrdinalIgnoreCase) >= 0 ? Decode(raw) ?? raw : raw;
            string frClick = null;
            string deepLink = null;
            var utm = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var pair in text.Split('&'))
            {
                var eq = pair.IndexOf('=');
                if (eq <= 0)
                {
                    continue;
                }
                var key = Decode(pair.Substring(0, eq));
                if (key == null || (key != FrClickKey && key != FrDeepLinkKey && !UtmKeys.Contains(key)))
                {
                    continue;
                }
                var value = Decode(pair.Substring(eq + 1))?.Trim();
                if (string.IsNullOrEmpty(value))
                {
                    continue;
                }
                if (key == FrClickKey)
                {
                    if (frClick == null && FrClickPattern.IsMatch(value))
                    {
                        frClick = value;
                    }
                }
                else if (key == FrDeepLinkKey)
                {
                    if (deepLink == null && IsValidDeepLinkPath(value))
                    {
                        deepLink = value;
                    }
                }
                else if (!utm.ContainsKey(key))
                {
                    utm[key] = value.Length > MaxValueLength ? value.Substring(0, MaxValueLength) : value;
                }
            }
            // Yol tıklama kimliğiyle birlikte gelir; kimliksiz değer Feralin linkinden gelmemiştir.
            return new AttributionParams(frClick, utm, frClick != null ? deepLink : null);
        }

        internal static bool IsValidDeepLinkPath(string path)
        {
            if (path.Length > MaxDeepLinkLength || !DeepLinkPattern.IsMatch(path) || path.StartsWith("//", StringComparison.Ordinal) || DeepLinkUnsafeEscape.IsMatch(path))
            {
                return false;
            }
            var question = path.IndexOf('?');
            var pathOnly = question >= 0 ? path.Substring(0, question) : path;
            return Array.IndexOf(pathOnly.Split('/'), "..") < 0;
        }

        // Katı çözümleme: '+' boşluktur, bozuk %XX ya da geçersiz UTF-8 null döndürür (parça yok sayılır).
        internal static string Decode(string text)
        {
            var bytes = new List<byte>(text.Length);
            for (var i = 0; i < text.Length; i++)
            {
                var c = text[i];
                if (c == '+')
                {
                    bytes.Add((byte)' ');
                }
                else if (c == '%')
                {
                    if (i + 2 >= text.Length)
                    {
                        return null;
                    }
                    var hi = HexValue(text[i + 1]);
                    var lo = HexValue(text[i + 2]);
                    if (hi < 0 || lo < 0)
                    {
                        return null;
                    }
                    bytes.Add((byte)((hi << 4) | lo));
                    i += 2;
                }
                else if (c < 0x80)
                {
                    bytes.Add((byte)c);
                }
                else
                {
                    bytes.AddRange(Encoding.UTF8.GetBytes(c.ToString()));
                }
            }
            try
            {
                return new UTF8Encoding(false, true).GetString(bytes.ToArray());
            }
            catch (ArgumentException)
            {
                return null;
            }
        }

        private static int HexValue(char c)
        {
            if (c >= '0' && c <= '9')
            {
                return c - '0';
            }
            if (c >= 'a' && c <= 'f')
            {
                return c - 'a' + 10;
            }
            if (c >= 'A' && c <= 'F')
            {
                return c - 'A' + 10;
            }
            return -1;
        }
    }

    /// <summary>Temizlenmiş derin bağlantı: yalnız şema, host ve yol ile izin listesindeki parametreler kalır.</summary>
    public sealed class DeepLink
    {
        private const int MaxUrlLength = 2048;

        private DeepLink(string cleanUrl, AttributionParams parameters)
        {
            CleanUrl = cleanUrl;
            Params = parameters;
        }

        /// <summary>Sorgu ve parça olmadan URL.</summary>
        public string CleanUrl { get; }
        /// <summary>İzin listesinden geçmiş parametreler.</summary>
        public AttributionParams Params { get; }

        /// <summary>Yalnız http(s) kabul edilir; App Link ve Universal Link tanımı gereği özel şemalar kanıt sayılmaz.</summary>
        public static DeepLink Parse(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw) || !Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri))
            {
                return null;
            }
            if ((uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp) || string.IsNullOrEmpty(uri.Host))
            {
                return null;
            }
            var port = uri.IsDefaultPort ? "" : ":" + uri.Port.ToString(System.Globalization.CultureInfo.InvariantCulture);
            var clean = uri.Scheme + "://" + uri.Host + port + uri.AbsolutePath;
            if (clean.Length > MaxUrlLength)
            {
                return null;
            }
            var query = uri.Query.Length > 1 ? uri.Query.Substring(1) : "";
            return new DeepLink(clean, AttributionParams.ParseQuery(query));
        }
    }

    /// <summary>Google Play Install Referrer okuyucusu. Ham dizgi yalnız çekirdeğe verilir, izin listesinden geçer ve saklanmaz.</summary>
    public interface IInstallReferrerSource
    {
        /// <summary>Geri çağrı bir kez çağrılır; referrer yoksa ya da servis erişilemezse <c>null</c> ile. Herhangi bir iş parçacığından olabilir.</summary>
        void Read(Action<string> onResult);
    }

    /// <summary>AdServices token'ı okuma sonucu.</summary>
    public sealed class AdServicesTokenResult
    {
        private AdServicesTokenResult(string status, string token)
        {
            Status = status;
            Token = token;
        }

        /// <summary><c>token</c>, <c>unsupported</c> ya da <c>failed</c>.</summary>
        public string Status { get; }
        /// <summary>Token; yalnız <c>token</c> durumunda dolu. Loglanmaz.</summary>
        public string Token { get; }

        /// <summary>Token alındı.</summary>
        public static AdServicesTokenResult FromToken(string token) => new AdServicesTokenResult("token", token);

        /// <summary>Platform ya da sürüm desteklemiyor (iOS dışı, iOS 14.3 öncesi).</summary>
        public static AdServicesTokenResult Unsupported() => new AdServicesTokenResult("unsupported", null);

        /// <summary>Token alınamadı.</summary>
        public static AdServicesTokenResult Failed() => new AdServicesTokenResult("failed", null);
    }

    /// <summary>iOS <c>AAAttribution.attributionToken()</c> kaynağı; Unity'de yerel iOS eklentisi sağlar.</summary>
    public interface IAdServicesTokenSource
    {
        /// <summary>Token'ı okur; sonuç herhangi bir iş parçacığında bildirilebilir.</summary>
        void GetToken(Action<AdServicesTokenResult> onResult);
    }

    /// <summary>iOS App Tracking Transparency durumu.</summary>
    public enum TrackingStatus
    {
        /// <summary>Henüz sorulmadı.</summary>
        NotDetermined = 0,
        /// <summary>Kısıtlı.</summary>
        Restricted = 1,
        /// <summary>Reddedildi.</summary>
        Denied = 2,
        /// <summary>İzin verildi.</summary>
        Authorized = 3,
        /// <summary>Platformda ATT yok.</summary>
        Unavailable = 4,
    }

    /// <summary><see cref="InstallBinding.Status"/> değerleri (Swift, Flutter ve React Native ile aynı adlar).</summary>
    public static class InstallBindingStatus
    {
        /// <summary>Token sunucuya iletildi (kabul).</summary>
        public const string Received = "received";
        /// <summary>Analitik ve reklam izni birlikte yok (ya da ATT reddetti).</summary>
        public const string SkippedNoConsent = "skipped_no_consent";
        /// <summary><see cref="FeralinOptions.AttributionApiUrl"/> veya <see cref="FeralinOptions.ProjectId"/> verilmemiş.</summary>
        public const string NotConfigured = "not_configured";
        /// <summary>Platform AdServices'i desteklemiyor.</summary>
        public const string Unsupported = "unsupported";
        /// <summary>Token alınamadı.</summary>
        public const string TokenUnavailable = "token_unavailable";
        /// <summary>Sunucu kalıcı olarak reddetti.</summary>
        public const string Rejected = "rejected";
        /// <summary>Geçici hata (ağ, 429, 5xx); sonra yeniden denenebilir.</summary>
        public const string TemporaryFailure = "temporary_failure";
    }

    /// <summary>
    /// <see cref="FeralinClient.BindInstall"/> sonucu (ADR-0007). <see cref="InstallId"/> müşterinin kendi sunucusuna iletilir; sunucu gizli
    /// API anahtarıyla <c>POST /v1/projects/{id}/attribution/account-links</c> (<c>surface=app</c>, <c>subject_id=installId</c>) çağırır.
    /// SDK hesap kimliği yazmaz: proje anahtarı uygulamadan okunabildiğinden hesap bağı yalnız müşteri sunucusundan kurulur.
    /// Apple tarafında kesin tekil atıf iddia edilmez: sunucu bugün Apple'a sormaz, token yalnız saklanır.
    /// </summary>
    public sealed class InstallBinding
    {
        internal InstallBinding(string status, string installId)
        {
            Status = status;
            InstallId = installId;
        }

        /// <summary><see cref="InstallBindingStatus"/> değerlerinden biri.</summary>
        public string Status { get; }
        /// <summary>Rastgele kurulum kimliği (cihaz kimliği değildir); reklam izni yoksa <c>null</c>.</summary>
        public string InstallId { get; }
    }
}
