using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Feralin.Unity
{
    /// <summary>Yönlendiricinin kısa link çözümleme yanıtı.</summary>
    public sealed class ResolvedShortLink
    {
        internal ResolvedShortLink(string code, string deepLinkPath, IReadOnlyDictionary<string, string> utm, string clickId)
        {
            Code = code;
            DeepLinkPath = deepLinkPath;
            Utm = utm;
            ClickId = clickId;
        }

        /// <summary>Kısa kod.</summary>
        public string Code { get; }
        /// <summary>Açılacak yol; link yol taşımıyorsa <c>null</c>.</summary>
        public string DeepLinkPath { get; }
        /// <summary>Anahtarlar <c>source</c>, <c>medium</c>, <c>campaign</c>, <c>term</c>, <c>content</c>.</summary>
        public IReadOnlyDictionary<string, string> Utm { get; }
        /// <summary>Yönlendiricinin yazdığı tıklama kimliği; reklam ölçümü izni yoksa ya da attribution kapalı linkte <c>null</c>.</summary>
        public string ClickId { get; }
    }

    /// <summary>
    /// Fera Fly kısa link çözümlemesi. Oyun <c>https://marka.fera.fly/kod</c> gibi bir App Link / Universal Link ile doğrudan açıldığında
    /// işletim sistemi yönlendiriciye uğramaz; istemci aynı adresi <c>application/vnd.feralin.link+json</c> türüyle ister. Yönlendirici linkin
    /// derin yolunu, UTM'sini ve (izin varsa) tıklama kimliğini döner; bu bilgi tarayıcı yönlendirmesinde zaten herkese açıktır.
    /// </summary>
    public static class ShortLinks
    {
        /// <summary>Çözümleme isteğinin Accept türü.</summary>
        public const string Accept = "application/vnd.feralin.link+json";

        private static readonly Regex ClickPattern = new Regex("^[A-Za-z0-9_-]{16,64}$", RegexOptions.CultureInvariant);
        private static readonly Regex CodePattern = new Regex("^[A-Za-z0-9_-]{1,64}$", RegexOptions.CultureInvariant);
        private static readonly HashSet<string> UtmKeys = new HashSet<string>(StringComparer.Ordinal) { "source", "medium", "campaign", "term", "content" };
        private const int MaxUtmValue = 256;
        private const int MaxPath = 200;

        /// <summary><c>https</c> ve host listedeki bir host ya da onun alt alanı. Benzer adlı host (<c>sahtefera.fly</c>) kabul edilmez.</summary>
        public static bool IsShortLink(string raw, IEnumerable<string> hosts)
        {
            if (string.IsNullOrWhiteSpace(raw) || hosts == null || !Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri))
            {
                return false;
            }
            if (uri.Scheme != Uri.UriSchemeHttps || string.IsNullOrEmpty(uri.Host))
            {
                return false;
            }
            var host = uri.Host.ToLowerInvariant();
            foreach (var candidate in hosts)
            {
                var allowed = candidate?.Trim().ToLowerInvariant();
                if (!string.IsNullOrEmpty(allowed) && (host == allowed || host.EndsWith("." + allowed, StringComparison.Ordinal)))
                {
                    return true;
                }
            }
            return false;
        }

        /// <summary>
        /// Çözümleme isteğinin başlıkları. Kullanıcı-ajanı yalnız cihaz sınıfını verir; cihaz modeli gönderilmez. Reklam ölçümü izni yoksa
        /// <c>Feralin-Attribution: off</c>: yönlendirici tıklamayı toplam sayar, IP içeren kanıt yazmaz.
        /// </summary>
        public static Dictionary<string, string> Headers(string device, bool attribution)
        {
            string agent;
            switch (device)
            {
                case "ios":
                    agent = "FeralinSDK (iPhone; CPU iPhone OS 17_0 like Mac OS X)";
                    break;
                case "desktop":
                    agent = "FeralinSDK (Windows NT 10.0; Win64; x64)";
                    break;
                default:
                    agent = "FeralinSDK (Linux; Android 14)";
                    break;
            }
            var headers = new Dictionary<string, string>(StringComparer.Ordinal) { ["Accept"] = Accept, ["User-Agent"] = agent };
            if (!attribution)
            {
                headers["Feralin-Attribution"] = "off";
            }
            return headers;
        }

        /// <summary>Yanıtı çözer; biçim bozuksa <c>null</c> (istemci çözümlemesiz açılışa düşer).</summary>
        public static ResolvedShortLink Parse(string body)
        {
            if (string.IsNullOrEmpty(body))
            {
                return null;
            }
            Dictionary<string, object> json;
            try
            {
                json = MiniJson.Parse(body) as Dictionary<string, object>;
            }
            catch (FormatException)
            {
                return null;
            }
            if (json == null || !(json.TryGetValue("code", out var rawCode) && rawCode is string code) || !CodePattern.IsMatch(code))
            {
                return null;
            }
            string path = null;
            if (json.TryGetValue("deep_link_path", out var rawPath) && rawPath is string p && p.StartsWith("/", StringComparison.Ordinal)
                && !p.StartsWith("//", StringComparison.Ordinal) && p.Length <= MaxPath)
            {
                path = p;
            }
            string click = null;
            if (json.TryGetValue("click_id", out var rawClick) && rawClick is string c && ClickPattern.IsMatch(c))
            {
                click = c;
            }
            var utm = new Dictionary<string, string>(StringComparer.Ordinal);
            if (json.TryGetValue("utm", out var rawUtm) && rawUtm is Dictionary<string, object> map)
            {
                foreach (var entry in map)
                {
                    if (UtmKeys.Contains(entry.Key) && entry.Value is string value && value.Length > 0)
                    {
                        utm[entry.Key] = value.Length > MaxUtmValue ? value.Substring(0, MaxUtmValue) : value;
                    }
                }
            }
            return new ResolvedShortLink(code, path, utm, click);
        }

        /// <summary>
        /// Çözülen linki mevcut derin bağlantı akışına verilecek adrese çevirir: aynı host, derin yol (yoksa <c>/</c>), <c>fr_click</c> ve
        /// <c>utm_*</c>. Böylece izin kuralları (reklam izni yoksa tıklama kimliği gönderilmez) tek yerde uygulanır.
        /// </summary>
        public static string SyntheticUrl(string original, ResolvedShortLink resolved)
        {
            if (resolved == null || !Uri.TryCreate(original?.Trim() ?? "", UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host))
            {
                return null;
            }
            var query = new List<string>();
            if (resolved.ClickId != null)
            {
                query.Add("fr_click=" + Uri.EscapeDataString(resolved.ClickId));
            }
            foreach (var entry in resolved.Utm)
            {
                query.Add("utm_" + entry.Key + "=" + Uri.EscapeDataString(entry.Value));
            }
            var path = resolved.DeepLinkPath == null ? "/" : resolved.DeepLinkPath.Split('?')[0];
            return "https://" + uri.Host + path + (query.Count == 0 ? "" : "?" + string.Join("&", query));
        }

        /// <summary>Adresin yolu; ayrıştırılamazsa <c>/</c>.</summary>
        public static string PathOf(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw) || !Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri))
            {
                return "/";
            }
            var path = uri.AbsolutePath;
            return string.IsNullOrEmpty(path) ? "/" : path;
        }
    }

    public sealed partial class FeralinClient
    {
        private static readonly TimeSpan ShortLinkTimeout = TimeSpan.FromSeconds(5);
        private ResolvedShortLink _lastShortLink;

        /// <summary>Son çözümlenen kısa link (otomatik yakalamada oyunun gideceği yol); yoksa <c>null</c>. Bellekte tutulur, diske yazılmaz.</summary>
        public ResolvedShortLink LastShortLink
        {
            get
            {
                lock (_gate)
                {
                    return _lastShortLink;
                }
            }
        }

        /// <summary>
        /// Fera Fly kısa linkiyle (ör. <c>https://marka.fera.fly/kod</c>) açılışı işler ve oyunun açacağı yolu verir. Bağlantı doğrudan
        /// açıldığında yönlendirici atlandığı için istemci linki çözümler: derin yol, UTM ve (reklam izni varsa) tıklama kimliği
        /// <c>deep_link_opened</c> olayına eklenir. Adres kısa link değilse, çözümlenemezse ya da analitik izni yoksa adresin kendi yolu döner.
        /// <see cref="HandleDeepLink"/> ile aynı açılışı sayar: ikisinden yalnız biri çağrılır (FeralinBehaviour kendisi
        /// <see cref="HandleDeepLink"/> çağırır; yolu o durumda <see cref="LastShortLink"/> verir). Geri çağrı taşıyıcının iş parçacığında çalışır.
        /// </summary>
        public void HandleShortLink(string url, Action<ShortLinkOpen> onResult)
        {
            var fallback = new ShortLinkOpen(ShortLinks.PathOf(url), null, false);
            HandleLink(url, resolved =>
            {
                if (onResult == null)
                {
                    return;
                }
                try
                {
                    onResult(resolved == null ? fallback : new ShortLinkOpen(resolved.DeepLinkPath ?? "/", resolved.Code, resolved.ClickId != null));
                }
                catch (Exception ex)
                {
                    Warn("geri çağrı hatası: " + ex.GetType().Name);
                }
            });
        }

        // Bağlantı girişi: kısa linkse önce yönlendiriciden çözümlenir. Adreste zaten tıklama kimliği varsa (yönlendiriciden geçmiş), analitik
        // izni yoksa ya da izin henüz verilmediyse istek yapılmaz.
        private void HandleLink(string url, Action<ResolvedShortLink> onResult)
        {
            var link = DeepLink.Parse(url);
            if (link == null)
            {
                onResult?.Invoke(null);
                return;
            }
            bool resolve;
            bool advertising;
            lock (_gate)
            {
                resolve = !_closed && _consentDecided && _consent.Analytics && link.Params.FrClick == null
                    && ShortLinks.IsShortLink(url, _shortLinkHosts);
                advertising = resolve && EffectiveAdvertising(_consent);
            }
            if (!resolve)
            {
                AcceptLink(link);
                onResult?.Invoke(null);
                return;
            }
            var responded = 0;
            Action<TransportResponse> onResponse = response =>
            {
                if (System.Threading.Interlocked.Exchange(ref responded, 1) != 0)
                {
                    return;
                }
                var resolved = response != null && response.Status == 200 ? ShortLinks.Parse(response.Body) : null;
                lock (_gate)
                {
                    _lastShortLink = resolved;
                }
                var synthetic = resolved == null ? null : DeepLink.Parse(ShortLinks.SyntheticUrl(url, resolved));
                AcceptLink(synthetic ?? link);
                onResult?.Invoke(resolved);
            };
            try
            {
                var request = new TransportRequest(url.Trim(), Array.Empty<byte>(), ShortLinks.Headers(_shortLinkDevice, advertising), ShortLinkTimeout, "GET");
                _transport.Send(request, onResponse);
            }
            catch (Exception ex)
            {
                WriteDebug("taşıyıcı hatası: " + ex.GetType().Name);
                onResponse(TransportResponse.NetworkError);
            }
        }
    }
}
