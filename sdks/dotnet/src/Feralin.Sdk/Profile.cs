using System.Text;
using System.Text.RegularExpressions;

namespace Feralin;

/// <summary>
/// UTP §8.2 kimlik yöntemlerinin (<c>group</c>, <c>setUserProperties</c>, <c>setGlobalProperties</c>) istemci kuralları. Bütün SDK'larda ve
/// toplayıcıda (<c>services/collect/internal/httpapi/profile_filter.go</c>) birebir aynıdır; toplayıcı ayrıca projenin izin listesini uygular.
/// </summary>
public static partial class ProfileRules
{
    /// <summary>Grup olayı adı; React Native, Unity ve Android ile aynı.</summary>
    public const string GroupEventName = "fr_group";
    /// <summary>Kullanıcı özellikleri olayı adı.</summary>
    public const string UserPropertiesEventName = "fr_user_properties";
    /// <summary>Çağrı başına ve global haritada en çok özellik sayısı.</summary>
    public const int MaxProperties = 50;
    /// <summary>Dizge değerin en çok karakter sayısı.</summary>
    public const int MaxValueLength = 256;
    /// <summary>Grup kimliğinin en çok karakter sayısı.</summary>
    public const int MaxGroupIdLength = 128;

    // İstemci doğrulama beyan edemez: bu anahtarlar düşer, toplayıcı da düşürür.
    private static readonly HashSet<string> ReservedKeys = new(StringComparer.Ordinal)
    {
        "verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt",
    };

    // Kişisel veri anahtar kuralı (toplayıcıdaki piiTokens, piiFragments, piiExact ile aynı listeler).
    private static readonly HashSet<string> PiiTokens = new(StringComparer.Ordinal)
    {
        "email", "mail", "phone", "tel", "telephone", "mobile", "msisdn", "gsm",
        "ip", "ipv4", "ipv6", "ssn", "tckn", "passport", "password", "iban",
        "address", "adres", "eposta", "telefon", "soyad", "surname", "firstname",
        "lastname", "fullname", "birthdate", "birthday", "dob",
    };

    private static readonly string[] PiiFragments =
    {
        "email", "phonenumber", "ipaddress", "firstname", "lastname", "fullname", "surname", "soyad", "eposta", "telefon", "password", "birthdate",
    };

    private static readonly HashSet<string> PiiExact = new(StringComparer.Ordinal) { "name", "username", "displayname", "isim", "ad" };

    [GeneratedRegex("^[a-zA-Z][a-zA-Z0-9_]{0,63}$", RegexOptions.CultureInvariant)]
    private static partial Regex KeyPattern();

    [GeneratedRegex(@"[^\s@]+@[^\s@]+\.[^\s@]+", RegexOptions.CultureInvariant)]
    private static partial Regex EmailPattern();

    /// <summary>Sistem olayı (<c>fr_</c> önekli) mı; global özellikler bunlara eklenmez.</summary>
    public static bool IsSystemEvent(string? eventName) => eventName is not null && eventName.StartsWith("fr_", StringComparison.Ordinal);

    /// <summary>Anahtarı sözcüklere böler: küçük harf ya da rakamdan sonra gelen büyük harf yeni sözcük başlatır; alt çizgi ayırır.</summary>
    public static IReadOnlyList<string> KeyTokens(string key)
    {
        var builder = new StringBuilder(key.Length + 4);
        for (var i = 0; i < key.Length; i++)
        {
            var c = key[i];
            if (i > 0 && char.IsUpper(c) && (char.IsLower(key[i - 1]) || char.IsDigit(key[i - 1])))
            {
                builder.Append('_');
            }
            builder.Append(char.ToLowerInvariant(c));
        }
        return builder.ToString().Split('_', StringSplitOptions.RemoveEmptyEntries);
    }

    /// <summary>Anahtar kişisel veriye (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) benziyor mu.</summary>
    public static bool IsPiiLikeKey(string key)
    {
        var tokens = KeyTokens(key);
        foreach (var token in tokens)
        {
            if (PiiTokens.Contains(token))
            {
                return true;
            }
        }
        var joined = string.Concat(tokens);
        if (PiiExact.Contains(joined))
        {
            return true;
        }
        foreach (var fragment in PiiFragments)
        {
            if (joined.Contains(fragment, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>Grup kimliği kuralı: 1-128 karakter, yalnız boşluk değil, <c>@</c> ve kontrol karakteri yok.</summary>
    public static bool ValidGroupId(string? groupId)
    {
        if (string.IsNullOrWhiteSpace(groupId) || groupId.Length > MaxGroupIdLength || groupId.Contains('@'))
        {
            return false;
        }
        foreach (var c in groupId)
        {
            if (char.IsControl(c))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>Anahtar sözleşmeye uyuyor mu (biçim, ayrılmış alan, kişisel veri).</summary>
    public static bool ValidKey(string? key) =>
        key is not null && KeyPattern().IsMatch(key) && !ReservedKeys.Contains(key) && !IsPiiLikeKey(key);

    /// <summary>Değer dizge (≤256, kontrol karakteri ve e-posta biçimi yok), sonlu sayı ya da mantıksal mı; kabul edilirse yazılacak değer.</summary>
    public static bool TryValue(object? value, out object? clean)
    {
        clean = null;
        switch (value)
        {
            case string text:
                if (text.Length > MaxValueLength || EmailPattern().IsMatch(text))
                {
                    return false;
                }
                foreach (var c in text)
                {
                    if (char.IsControl(c))
                    {
                        return false;
                    }
                }
                clean = text;
                return true;
            case bool flag:
                clean = flag;
                return true;
            case double d:
                if (!double.IsFinite(d))
                {
                    return false;
                }
                clean = d;
                return true;
            case float f:
                if (!float.IsFinite(f))
                {
                    return false;
                }
                clean = f;
                return true;
            case int or long or short or byte or sbyte or uint or ulong or ushort or decimal:
                clean = value;
                return true;
            default:
                return false;
        }
    }

    /// <summary>
    /// Özellikleri sözleşmeye indirger; uymayan anahtarlar düşer ve sayısı <paramref name="dropped"/> ile döner. Çağrı başına en çok 50
    /// özellik tutulur. <paramref name="allowNull"/> yalnız global haritada kullanılır: null değer anahtarı silme isteğidir.
    /// </summary>
    public static Dictionary<string, object?> Sanitize(IEnumerable<KeyValuePair<string, object?>>? properties, out int dropped, bool allowNull = false)
    {
        dropped = 0;
        var result = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (properties is null)
        {
            return result;
        }
        foreach (var (key, value) in properties)
        {
            if (!ValidKey(key))
            {
                dropped++;
                continue;
            }
            object? clean = null;
            if (!(allowNull && value is null) && !TryValue(value, out clean))
            {
                dropped++;
                continue;
            }
            if (result.Count >= MaxProperties && !result.ContainsKey(key))
            {
                dropped++;
                continue;
            }
            result[key] = clean;
        }
        return result;
    }
}
