using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

namespace Feralin;

/// <summary><c>fr_error</c> kaynakları (<c>properties.origin</c>).</summary>
public static class ErrorOrigin
{
    /// <summary>Yakalanan (<c>try/catch</c>) hata; varsayılan.</summary>
    public const string Handled = "handled";
    /// <summary>Uygulamanın elle bildirdiği durum.</summary>
    public const string Manual = "manual";
    /// <summary>Yakalanmamış istisna (<c>AppDomain.UnhandledException</c> gibi).</summary>
    public const string UncaughtException = "uncaught_exception";
}

/// <summary>
/// <c>fr_error</c> sözleşmesi (X4): hata sınıfı adı, temizlenmiş kısa mesaj, normalize edilmiş çerçevelerin özeti olan parmak izi ve en
/// üst çerçeve. Ham yığın izi, dosya yolu, satır numarası ve kullanıcı verisi GİTMEZ. Kurallar Android (<c>ErrorEvent.kt</c>), React Native
/// (<c>signals.ts</c>), Go ve Python SDK ile aynıdır; toplayıcı mesajı ayrıca temizler ve izin listesi dışı alanı düşürür.
/// </summary>
public static class ErrorRules
{
    /// <summary>Ayrılmış olay adı.</summary>
    public const string EventName = "fr_error";
    /// <summary>Mesaj üst sınırı.</summary>
    public const int MaxMessage = 200;
    private const int MaxType = 64;
    private const int MaxFrame = 160;
    private const int MaxAppVersion = 32;
    private const int FingerprintFrames = 5;

    // ECMAScript seçeneği \b, \d ve \s'yi ASCII kurallarıyla çalıştırır: Web ve Android SDK'larındaki desenlerle aynı sonuç.
    private const RegexOptions Ascii = RegexOptions.ECMAScript | RegexOptions.CultureInvariant;
    private static readonly Regex Url = new(@"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s""'<>]+", Ascii);
    private static readonly Regex Email = new(@"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", Ascii);
    private static readonly Regex Uuid = new(@"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", Ascii);
    private static readonly Regex Token = new(@"\b[A-Za-z0-9_\-+/=]{24,}\b", Ascii);
    private static readonly Regex Number = new(@"\+?\d[\d\s\-().]{5,}\d", Ascii);
    private static readonly Regex Space = new(@"\s+", Ascii);
    private static readonly Regex DigitRun = new(@"\d+", Ascii);
    // Derleyicinin ürettiği ekler: async durum makinesi (<Ad>d__3), lambda kapanışı (<>c, <>c__DisplayClass0_0), yerel işlev (<Ad>g__Yerel|0_0).
    private static readonly Regex StateMachine = new(@"^<([^>]+)>d__\d+$", Ascii);
    private static readonly Regex Closure = new(@"^<>c(__DisplayClass[\d_]+)?$", Ascii);
    private static readonly Regex LambdaMethod = new(@"^<([^>]*)>[bgd]__.*$", Ascii);

    /// <summary>Mesajdan URL, e-posta, UUID, rakam içeren uzun belirteç ve en az 7 haneli sayı dizilerini çıkarır; 200 karaktere kırpar.</summary>
    public static string Scrub(string? message)
    {
        if (string.IsNullOrEmpty(message))
        {
            return "";
        }
        var text = Url.Replace(message, "[url]");
        text = Email.Replace(text, "[email]");
        text = Uuid.Replace(text, "[id]");
        text = Token.Replace(text, m => m.Value.Any(char.IsAsciiDigit) ? "[token]" : m.Value);
        text = Number.Replace(text, m => m.Value.Count(char.IsAsciiDigit) >= 7 ? "[num]" : m.Value);
        text = Space.Replace(text, " ").Trim();
        return text.Length > MaxMessage ? text[..MaxMessage] : text;
    }

    /// <summary>FNV-1a 64 (UTF-8 baytları üzerinde): 16 küçük harf onaltılı; Web, React Native, Go ve Python SDK ile aynı özet.</summary>
    public static string Fnv1a64(string text)
    {
        var hash = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(text))
        {
            hash = unchecked((hash ^ b) * 0x100000001b3UL);
        }
        return hash.ToString("x16");
    }

    /// <summary><c>tür|temel</c> özeti; temel ilk beş çerçevedir, çerçeve yoksa rakam dizileri <c>#</c> yapılmış mesajdır.</summary>
    public static string Fingerprint(string errorType, IReadOnlyList<string> frames, string message)
    {
        var basis = frames.Count > 0 ? string.Join("|", frames.Take(FingerprintFrames)) : DigitRun.Replace(message, "#");
        return Fnv1a64($"{errorType}|{basis}");
    }

    /// <summary>
    /// İstisnanın yığınını <c>Ad.Alanı.Tür.Yöntem</c> çerçevelerine çevirir (en içteki önce); dosya, satır ve bağımsız değişken gitmez. Uygulama
    /// çerçevesi varsa <c>System.*</c>, <c>Microsoft.*</c> ve SDK çerçeveleri atılır. Fırlatılmamış istisnada liste boştur.
    /// </summary>
    public static List<string> Frames(Exception error)
    {
        var all = new List<string>();
        var app = new List<string>();
        foreach (var frame in new StackTrace(error, false).GetFrames())
        {
            var method = frame.GetMethod();
            if (method is null)
            {
                continue;
            }
            var label = FrameLabel(method);
            all.Add(label);
            if (!IsFramework(method.DeclaringType))
            {
                app.Add(label);
            }
        }
        return app.Count > 0 ? app : all;
    }

    private static bool IsFramework(Type? type)
    {
        if (type is null)
        {
            return true;
        }
        if (type.Assembly == typeof(ErrorRules).Assembly)
        {
            return true;
        }
        var ns = type.Namespace ?? "";
        return ns is "System" or "Microsoft" || ns.StartsWith("System.", StringComparison.Ordinal) || ns.StartsWith("Microsoft.", StringComparison.Ordinal);
    }

    private static string FrameLabel(MethodBase method)
    {
        var name = method.Name;
        var type = method.DeclaringType;
        // async yöntem: MoveNext → dış türdeki özgün yöntem adı; lambda ve kapanış → onu tanımlayan yöntem.
        while (type is not null && type.IsNested)
        {
            var sm = StateMachine.Match(type.Name);
            if (sm.Success)
            {
                name = sm.Groups[1].Value;
                type = type.DeclaringType;
                continue;
            }
            if (Closure.IsMatch(type.Name))
            {
                type = type.DeclaringType;
                continue;
            }
            break;
        }
        var lambda = LambdaMethod.Match(name);
        if (lambda.Success && lambda.Groups[1].Value.Length > 0)
        {
            name = lambda.Groups[1].Value;
        }
        var typeName = type?.FullName?.Replace('+', '.') ?? "unknown";
        var label = $"{typeName}.{name}";
        return label.Length > MaxFrame ? label[..MaxFrame] : label;
    }

    /// <summary><c>fr_error</c> gövdesi: sözleşme alanlarının tamamı. <paramref name="appVersion"/> ≤ 32 karakterse eklenir.</summary>
    public static Dictionary<string, object?> Build(Exception error, string origin = ErrorOrigin.Handled, bool fatal = false, string? appVersion = null)
    {
        ArgumentNullException.ThrowIfNull(error);
        var type = error.GetType().Name;
        type = type.Length == 0 ? "Error" : type.Length > MaxType ? type[..MaxType] : type;
        return Build(type, Scrub(error.Message), Frames(error), origin, fatal, appVersion);
    }

    internal static Dictionary<string, object?> Build(string type, string message, IReadOnlyList<string> frames, string origin, bool fatal, string? appVersion)
    {
        var props = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["error_type"] = type,
            ["fingerprint"] = Fingerprint(type, frames, message),
        };
        if (message.Length > 0)
        {
            props["message"] = message;
        }
        if (frames.Count > 0)
        {
            props["top_frame"] = frames[0].Length > MaxFrame ? frames[0][..MaxFrame] : frames[0];
        }
        props["frame_count"] = Math.Min(frames.Count, 1000);
        if (!string.IsNullOrEmpty(appVersion) && appVersion.Length <= MaxAppVersion)
        {
            props["app_version"] = appVersion;
        }
        props["handled"] = origin is ErrorOrigin.Handled or ErrorOrigin.Manual;
        props["fatal"] = fatal;
        props["origin"] = origin;
        return props;
    }

    internal static bool ValidOrigin(string? origin) => origin is ErrorOrigin.Handled or ErrorOrigin.Manual or ErrorOrigin.UncaughtException;
}

/// <summary>Hata fırtınası sınırı: süreç başına en çok 20 olay, aynı parmak izi için en çok 3; örnekleme oranı 0…1.</summary>
internal sealed class ErrorLimiter
{
    private readonly object _gate = new();
    private readonly double _sampleRate;
    private readonly int _maxEvents;
    private readonly int _maxPerFingerprint;
    private readonly Func<double> _random;
    private readonly Dictionary<string, int> _perFingerprint = new(StringComparer.Ordinal);
    private int _total;

    internal ErrorLimiter(double sampleRate, Func<double> random, int maxEvents = 20, int maxPerFingerprint = 3)
    {
        _sampleRate = double.IsNaN(sampleRate) ? 0 : Math.Clamp(sampleRate, 0, 1);
        _random = random;
        _maxEvents = maxEvents;
        _maxPerFingerprint = maxPerFingerprint;
    }

    internal bool Allow(string fingerprint)
    {
        lock (_gate)
        {
            if (_total >= _maxEvents)
            {
                return false;
            }
            if (_sampleRate < 1 && _random() >= _sampleRate)
            {
                return false;
            }
            _perFingerprint.TryGetValue(fingerprint, out var seen);
            if (seen >= _maxPerFingerprint)
            {
                return false;
            }
            _perFingerprint[fingerprint] = seen + 1;
            _total++;
            return true;
        }
    }
}
