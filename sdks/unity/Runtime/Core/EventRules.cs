using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Feralin.Unity
{
    /// <summary>Tel üzerindeki Idempotency-Key değerini üretir.</summary>
    public static class Idempotency
    {
        private const ulong Offset = 0xcbf29ce484222325UL;
        private const ulong Prime = 0x100000001b3UL;

        /// <summary>
        /// Diğer Feralin SDK'larıyla aynı anahtar: sıralı tüm event_id'lerin UTF-8 FNV-1a 64 özeti ve olay sayısı.
        /// Sıradan bağımsızdır; aynı batch her denemede aynı anahtarı üretir.
        /// </summary>
        public static string KeyFor(IEnumerable<string> eventIds)
        {
            var sorted = new List<string>(eventIds);
            sorted.Sort(StringComparer.Ordinal);
            var hash = Offset;
            foreach (var value in Encoding.UTF8.GetBytes(string.Join(",", sorted)))
            {
                hash = unchecked((hash ^ value) * Prime);
            }
            return hash.ToString("x16") + "-" + sorted.Count;
        }
    }

    internal static class Ulid
    {
        private const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
        private static readonly RandomNumberGenerator Rng = RandomNumberGenerator.Create();
        private static readonly object RngGate = new object();

        /// <summary>26 karakter Crockford base32: 48 bit zaman, 80 bit güvenli rastgele.</summary>
        public static string New(DateTimeOffset now)
        {
            var chars = new char[26];
            var time = Math.Max(0, now.ToUnixTimeMilliseconds());
            for (var i = 9; i >= 0; i--)
            {
                chars[i] = Alphabet[(int)(time % 32)];
                time /= 32;
            }
            var random = new byte[16];
            // Mono'da RandomNumberGenerator örneğinin iş parçacığı güvenliği garanti değildir.
            lock (RngGate)
            {
                Rng.GetBytes(random);
            }
            for (var i = 0; i < 16; i++)
            {
                chars[10 + i] = Alphabet[random[i] % 32];
            }
            return new string(chars);
        }
    }

    /// <summary>Şema sınırları istemcide uygulanır, çünkü tek geçersiz alan toplayıcıda tüm batch'i 400 ile düşürür.</summary>
    internal static class EventRules
    {
        public const int MaxProperties = 100;
        public const int MaxIdentifierLength = 128;
        public const string ClickProperty = "fr_click";

        private static readonly Regex EventNamePattern = new Regex("^[a-z][a-z0-9_]*$", RegexOptions.CultureInvariant);
        private static readonly Regex PropertyKeyPattern = new Regex("^[a-zA-Z][a-zA-Z0-9_]{0,63}$", RegexOptions.CultureInvariant);

        // Bu alanları yalnız sunucu üretir; istemci özelliği olarak da taşınmaz.
        private static readonly HashSet<string> ServerOnlyProperties = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "verified", "tenant_id", "project_id" };

        public static bool ValidEventName(string name) =>
            !string.IsNullOrEmpty(name) && name.Length <= 100 && EventNamePattern.IsMatch(name);

        public static bool ValidIdentifier(string value) => value == null || value.Length <= MaxIdentifierLength;

        public static Dictionary<string, object> SanitizeProperties(IEnumerable<KeyValuePair<string, object>> properties, out int removed)
        {
            removed = 0;
            var result = new Dictionary<string, object>(StringComparer.Ordinal);
            if (properties == null)
            {
                return result;
            }
            foreach (var pair in properties)
            {
                if (pair.Key == null || !PropertyKeyPattern.IsMatch(pair.Key) || ServerOnlyProperties.Contains(pair.Key) || result.Count >= MaxProperties)
                {
                    removed++;
                    continue;
                }
                result[pair.Key] = pair.Value;
            }
            return result;
        }

        public static Dictionary<string, object> ContextToWire(EventContext context)
        {
            if (context == null)
            {
                return null;
            }
            var result = new Dictionary<string, object>(StringComparer.Ordinal);
            var locale = Clip(context.Locale, 16);
            if (locale != null)
            {
                result["locale"] = locale;
            }
            var timezone = Clip(context.Timezone, 64);
            if (timezone != null)
            {
                result["timezone"] = timezone;
            }
            var version = Clip(context.AppVersion, 32);
            var build = Clip(context.AppBuild, 32);
            if (version != null || build != null)
            {
                var app = new Dictionary<string, object>(StringComparer.Ordinal);
                if (version != null)
                {
                    app["version"] = version;
                }
                if (build != null)
                {
                    app["build"] = build;
                }
                result["app"] = app;
            }
            return result.Count > 0 ? result : null;
        }

        private static string Clip(string value, int max)
        {
            if (string.IsNullOrEmpty(value))
            {
                return null;
            }
            return value.Length > max ? value.Substring(0, max) : value;
        }
    }
}
