using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Feralin.Unity
{
    /// <summary>Hata kaynağı (<c>fr_error.source</c>).</summary>
    public static class ErrorSource
    {
        /// <summary>Oyunun <see cref="FeralinClient.CaptureError"/> çağrısı.</summary>
        public const string Manual = "manual";
        /// <summary><c>Application.logMessageReceived</c> istisna kaydı (yakalanmamış istisna).</summary>
        public const string LogException = "log_exception";
        /// <summary><c>Application.logMessageReceived</c> hata ya da assert kaydı.</summary>
        public const string LogError = "log_error";
        /// <summary><c>AppDomain.UnhandledException</c>.</summary>
        public const string UnhandledException = "unhandled_exception";
        /// <summary><c>TaskScheduler.UnobservedTaskException</c>.</summary>
        public const string UnobservedTask = "unobserved_task";
    }

    /// <summary>
    /// Hata yakalama ayarları. Varsayılanlar gürültüyü ve veri hacmini sınırlar: saniyede değil dakikada sayılan hız sınırı,
    /// aynı hata için ayrı üst sınır ve isteğe bağlı örnekleme.
    /// </summary>
    public sealed class ErrorOptions
    {
        /// <summary>Örnekleme oranı (0…1); 1 hepsini alır. Oran 1'in altındaysa olaya <c>sample_rate</c> yazılır, sunucu ölçekleyebilir.</summary>
        public double SampleRate { get; set; } = 1.0;
        /// <summary>Bir dakikada gönderilecek en çok hata olayı (tüm hatalar toplamı).</summary>
        public int MaxPerMinute { get; set; } = 10;
        /// <summary>Bir dakikada aynı parmak izli en çok hata olayı.</summary>
        public int MaxPerFingerprintPerMinute { get; set; } = 2;
        /// <summary>İleti uzunluk sınırı (karakter; şema ve toplayıcı üst sınırı 200).</summary>
        public int MaxMessageLength { get; set; } = 200;
        /// <summary>Olaya yazılacak en çok yığın çerçevesi.</summary>
        public int MaxFrames { get; set; } = 12;
    }

    /// <summary>Hata verisinden kişisel veri ve değişken parçaları ayıklar, yığın çerçevelerini normalleştirip parmak izi özeti çıkarır.</summary>
    internal static class ErrorSanitizer
    {
        private static readonly Regex Email = new Regex(@"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}", RegexOptions.CultureInvariant);
        private static readonly Regex UrlQuery = new Regex(@"(https?://[^\s?#""'<>]+)[?#][^\s""'<>]*", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
        private static readonly Regex Jwt = new Regex(@"eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]*", RegexOptions.CultureInvariant);
        private static readonly Regex Secret = new Regex(@"(?i)\b(password|passwd|pwd|secret|token|api[_\-]?key|authorization)\b\s*[=:]\s*[^\s,;""']+", RegexOptions.CultureInvariant);
        private static readonly Regex Bearer = new Regex(@"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]+", RegexOptions.CultureInvariant);
        private static readonly Regex Ipv4 = new Regex(@"\b(?:\d{1,3}\.){3}\d{1,3}\b", RegexOptions.CultureInvariant);
        private static readonly Regex Ipv6 = new Regex(@"\b(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}\b", RegexOptions.CultureInvariant);
        private static readonly Regex LongHex = new Regex(@"\b[0-9a-fA-F]{32,}\b", RegexOptions.CultureInvariant);
        private static readonly Regex LongToken = new Regex(@"\b[A-Za-z0-9_\-]{40,}\b", RegexOptions.CultureInvariant);
        private static readonly Regex Phone = new Regex(@"\+?\d[\d\s().\-]{8,}\d", RegexOptions.CultureInvariant);
        private static readonly Regex WindowsUser = new Regex(@"(?i)([A-Za-z]:\\Users\\)[^\\\s]+", RegexOptions.CultureInvariant);
        private static readonly Regex UnixUser = new Regex(@"(/(?:Users|home)/)[^/\s]+", RegexOptions.CultureInvariant);

        // Çerçeve normalleştirme: dosya yolu/satır, mono adresleri, bağımsız değişken listeleri ve derleme özetleri değişken ya da kişiseldir.
        private static readonly Regex FrameLocation = new Regex(@"\s*\(at [^)]*\)|\s+in\s+<[^>]*>:\d+|\s+in\s+\S+:\d+|\s*\[0x[0-9a-fA-F]+\]|\s+\[at [^\]]*\]", RegexOptions.CultureInvariant);
        private static readonly Regex FrameArguments = new Regex(@"\([^()]*\)", RegexOptions.CultureInvariant);
        private static readonly Regex FramePrefix = new Regex(@"^\s*(?:at\s+)?", RegexOptions.CultureInvariant);
        private static readonly Regex Hexadecimal = new Regex(@"0x[0-9a-fA-F]+", RegexOptions.CultureInvariant);
        private static readonly Regex Digits = new Regex(@"\d+", RegexOptions.CultureInvariant);

        /// <summary>Kişisel veri ve gizli değer ayıklanmış, sınırlandırılmış metin; boş girdide boş metin.</summary>
        public static string Scrub(string text, int maxLength)
        {
            if (string.IsNullOrEmpty(text))
            {
                return "";
            }
            var s = text.Length > maxLength * 4 ? text.Substring(0, maxLength * 4) : text;
            s = UrlQuery.Replace(s, "$1?[redacted]");
            s = Jwt.Replace(s, "[token]");
            s = Secret.Replace(s, m => m.Groups[1].Value + "=[redacted]");
            s = Bearer.Replace(s, "Bearer [token]");
            s = Email.Replace(s, "[email]");
            s = WindowsUser.Replace(s, "$1[user]");
            s = UnixUser.Replace(s, "$1[user]");
            s = Ipv4.Replace(s, "[ip]");
            s = Ipv6.Replace(s, "[ip]");
            s = LongHex.Replace(s, "[token]");
            s = LongToken.Replace(s, "[token]");
            s = Phone.Replace(s, "[number]");
            s = s.Replace("\r", " ").Replace("\n", " ").Trim();
            return s.Length > maxLength ? s.Substring(0, maxLength) : s;
        }

        /// <summary>Yığın izini normalleştirilmiş çerçeve listesine çevirir (dosya yolu, satır, adres ve bağımsız değişken yok).</summary>
        public static List<string> NormalizeFrames(string stackTrace, int maxFrames)
        {
            var frames = new List<string>();
            if (string.IsNullOrEmpty(stackTrace))
            {
                return frames;
            }
            foreach (var raw in stackTrace.Split('\n'))
            {
                var line = raw.Trim('\r', ' ', '\t');
                if (line.Length == 0)
                {
                    continue;
                }
                line = FrameLocation.Replace(line, "");
                line = FramePrefix.Replace(line, "");
                // İç içe bağımsız değişken listeleri için tekrarlı sadeleştirme.
                for (var i = 0; i < 3; i++)
                {
                    var next = FrameArguments.Replace(line, "");
                    if (next == line)
                    {
                        break;
                    }
                    line = next;
                }
                line = Hexadecimal.Replace(line, "0x");
                line = Digits.Replace(line, "#");
                line = Scrub(line, 200);
                if (line.Length == 0)
                {
                    continue;
                }
                frames.Add(line);
                if (frames.Count >= maxFrames)
                {
                    break;
                }
            }
            return frames;
        }

        /// <summary>Hata türü ve ilk altı normalleştirilmiş çerçevenin SHA-256 özetinin ilk 16 onaltılık karakteri.</summary>
        public static string Fingerprint(string errorType, IReadOnlyList<string> frames)
        {
            var builder = new StringBuilder(errorType ?? "");
            for (var i = 0; i < frames.Count && i < 6; i++)
            {
                builder.Append('\n').Append(frames[i]);
            }
            using (var sha = SHA256.Create())
            {
                var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(builder.ToString()));
                var chars = new char[16];
                const string hex = "0123456789abcdef";
                for (var i = 0; i < 8; i++)
                {
                    chars[i * 2] = hex[hash[i] >> 4];
                    chars[(i * 2) + 1] = hex[hash[i] & 0xF];
                }
                return new string(chars);
            }
        }
    }
}
