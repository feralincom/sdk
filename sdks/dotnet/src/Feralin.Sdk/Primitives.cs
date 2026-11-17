using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace Feralin;

/// <summary>Tel üzerindeki Idempotency-Key değerini üretir.</summary>
public static class Idempotency
{
    private const ulong Offset = 0xcbf29ce484222325UL;
    private const ulong Prime = 0x100000001b3UL;

    /// <summary>
    /// Web, Node, Android ve Flutter SDK'larıyla aynı anahtar: sıralı tüm event_id'lerin FNV-1a 64 özeti ve olay sayısı.
    /// Sıradan bağımsızdır; farklı içerik farklı anahtar üretir.
    /// </summary>
    public static string KeyFor(IEnumerable<string> eventIds)
    {
        var sorted = eventIds.ToArray();
        Array.Sort(sorted, StringComparer.Ordinal);
        var hash = Offset;
        foreach (var ch in string.Join(',', sorted))
        {
            hash = unchecked((hash ^ ch) * Prime);
        }
        return $"{hash:x16}-{sorted.Length}";
    }
}

internal static class Ulid
{
    private const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    /// <summary>26 karakter Crockford base32: 48 bit zaman, 80 bit güvenli rastgele.</summary>
    public static string New(DateTimeOffset now)
    {
        Span<char> chars = stackalloc char[26];
        var time = Math.Max(0, now.ToUnixTimeMilliseconds());
        for (var i = 9; i >= 0; i--)
        {
            chars[i] = Alphabet[(int)(time % 32)];
            time /= 32;
        }
        Span<byte> random = stackalloc byte[16];
        RandomNumberGenerator.Fill(random);
        for (var i = 0; i < 16; i++)
        {
            chars[10 + i] = Alphabet[random[i] % 32];
        }
        return new string(chars);
    }
}

/// <summary>Şema sınırları istemcide uygulanır, çünkü tek geçersiz alan toplayıcıda tüm batch'i 400 ile düşürür.</summary>
internal static partial class EventRules
{
    public const int MaxProperties = 100;
    public const int MaxIdentifierLength = 128;
    public const string ClickProperty = "fr_click";
    /// <summary>Kurulum eşleştirme kodu özelliği (toplayıcı <c>services/collect/internal/worker/installcode.go</c> ile aynı).</summary>
    public const string InstallCodeProperty = "fr_install_code";

    private static readonly string[] UtmKeys = { "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content" };
    private const int MaxUtmLength = 256;

    [GeneratedRegex("^[a-z][a-z0-9_]*$", RegexOptions.CultureInvariant)]
    private static partial Regex EventNamePattern();

    [GeneratedRegex("^[a-zA-Z][a-zA-Z0-9_]{0,63}$", RegexOptions.CultureInvariant)]
    private static partial Regex PropertyKeyPattern();

    // Sunucudaki kanonik biçimle aynı alfabe (Crockford Base32, I/L/O/U yok); tire, boşluk ve alt çizgi ayraçtır.
    [GeneratedRegex("^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$", RegexOptions.CultureInvariant)]
    private static partial Regex InstallCodePattern();

    public static bool ValidInstallCode(string? code) => !string.IsNullOrEmpty(code) && InstallCodePattern().IsMatch(code);

    public static bool ValidEventName(string? name) => !string.IsNullOrEmpty(name) && name.Length <= 100 && EventNamePattern().IsMatch(name);

    public static Dictionary<string, object?> SanitizeProperties(IEnumerable<KeyValuePair<string, object?>>? properties)
    {
        var result = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (properties is null)
        {
            return result;
        }
        foreach (var (key, value) in properties)
        {
            if (result.Count >= MaxProperties)
            {
                break;
            }
            if (key is not null && PropertyKeyPattern().IsMatch(key))
            {
                result[key] = value;
            }
        }
        return result;
    }

    /// <summary>Bağlamı şemaya indirger; ayrıştırılamayan URL gönderilmez, sorgu dizgisi hiç çıkmaz.</summary>
    public static Dictionary<string, object?>? NormalizeContext(EventContext? context, Dictionary<string, object?> properties)
    {
        if (context is null)
        {
            return null;
        }
        var result = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (TryParseHttpUrl(context.PageUrl, out var page))
        {
            CopyUtm(page, properties);
            var clean = $"{page.Scheme}://{page.Authority}{page.AbsolutePath}";
            if (clean.Length <= 2048)
            {
                result["page_url"] = clean;
            }
        }
        if (Clip(context.PageTitle, 512) is { } title)
        {
            result["page_title"] = title;
        }
        if (TryParseHttpUrl(context.Referrer, out var referrer))
        {
            result["referrer"] = $"{referrer.Scheme}://{referrer.Authority}";
        }
        if (Clip(context.Locale, 16) is { } locale)
        {
            result["locale"] = locale;
        }
        if (Clip(context.Timezone, 64) is { } timezone)
        {
            result["timezone"] = timezone;
        }
        var version = Clip(context.AppVersion, 32);
        var build = Clip(context.AppBuild, 32);
        if (version is not null || build is not null)
        {
            var app = new Dictionary<string, object?>(StringComparer.Ordinal);
            if (version is not null)
            {
                app["version"] = version;
            }
            if (build is not null)
            {
                app["build"] = build;
            }
            result["app"] = app;
        }
        return result.Count > 0 ? result : null;
    }

    private static bool TryParseHttpUrl(string? raw, out Uri uri)
    {
        uri = null!;
        if (string.IsNullOrWhiteSpace(raw) || !Uri.TryCreate(raw, UriKind.Absolute, out var parsed))
        {
            return false;
        }
        if (string.IsNullOrEmpty(parsed.Host) || parsed.Scheme is not ("http" or "https"))
        {
            return false;
        }
        uri = parsed;
        return true;
    }

    private static void CopyUtm(Uri page, Dictionary<string, object?> properties)
    {
        var query = page.Query.TrimStart('?');
        if (query.Length == 0)
        {
            return;
        }
        foreach (var pair in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = pair.IndexOf('=');
            if (separator <= 0)
            {
                continue;
            }
            var key = pair[..separator];
            if (Array.IndexOf(UtmKeys, key) < 0 || properties.ContainsKey(key) || properties.Count >= MaxProperties)
            {
                continue;
            }
            var value = Uri.UnescapeDataString(pair[(separator + 1)..].Replace('+', ' ')).Trim();
            if (value.Length > 0)
            {
                properties[key] = value.Length > MaxUtmLength ? value[..MaxUtmLength] : value;
            }
        }
    }

    private static string? Clip(string? value, int max)
    {
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }
        return value.Length > max ? value[..max] : value;
    }
}
