using System;
using System.Collections.Generic;
using System.Globalization;

namespace Feralin.Unity
{
    // Diğer mobil SDK'larla ortak olay sözleşmeleri: gelir (feralin_purchase), reklam geliri (fr_ad_revenue), grup (fr_group),
    // kullanıcı özellikleri (fr_user_properties), hata (fr_error) ve otomatik oturum.
    public sealed partial class FeralinClient
    {
        /// <summary>Grup olayı adı (<c>fr_group</c>); React Native, Android ve Flutter ile aynı.</summary>
        public const string GroupEventName = "fr_group";
        /// <summary>Kullanıcı özellikleri olayı adı (<c>fr_user_properties</c>).</summary>
        public const string UserPropertiesEventName = "fr_user_properties";
        /// <summary>Hata olayı adı (<c>fr_error</c>).</summary>
        public const string ErrorEventName = "fr_error";
        /// <summary>Gelir olayı adı (<c>feralin_purchase</c>).</summary>
        public const string RevenueEventName = RevenueEvent.Name;
        /// <summary>Reklam geliri olayı adı (<c>fr_ad_revenue</c>).</summary>
        public const string AdRevenueEventName = AdRevenueEvent.Name;

        private static readonly TimeSpan ErrorWindow = TimeSpan.FromMinutes(1);
        private const int MaxFingerprintWindows = 64;

        private readonly List<DateTimeOffset> _errorTimes = new List<DateTimeOffset>();
        private readonly Dictionary<string, List<DateTimeOffset>> _errorTimesByFingerprint = new Dictionary<string, List<DateTimeOffset>>(StringComparer.Ordinal);
        private long _errorsSuppressed;
        private long _errorsSuppressedPending;

        /// <summary>
        /// Reklam kanıtı kullanılabilir mi: reklam izni var ve (varsa) iOS ATT durumu reddetmemiş. Kapalıysa <c>fr_click</c>, referrer ve
        /// AdServices kullanılmaz.
        /// </summary>
        private bool EffectiveAdvertising(Consent consent)
        {
            if (consent == null || !consent.Advertising)
            {
                return false;
            }
            var provider = _trackingStatus;
            if (provider == null)
            {
                return true;
            }
            try
            {
                var status = provider();
                return status != TrackingStatus.Denied && status != TrackingStatus.Restricted;
            }
            catch (Exception)
            {
                // Durum okunamıyorsa kanıt kullanılmaz.
                return false;
            }
        }

        /// <summary>Oyun arka plana geçti; ön plana dönüşte süre dolmuşsa yeni oturum başlar. <c>FeralinBehaviour</c> bunu çağırır.</summary>
        public void NotifyBackground()
        {
            lock (_gate)
            {
                // Duraklama ve odak kaybı art arda gelebilir; ilk arka plan anı korunur.
                if (!_lastBackground.HasValue)
                {
                    _lastBackground = _now();
                }
            }
        }

        /// <summary>Oyun ön plana döndü; arka planda <see cref="FeralinOptions.SessionTimeout"/> kadar kalındıysa yeni <c>session_id</c> üretilir.</summary>
        public void NotifyForeground()
        {
            lock (_gate)
            {
                var now = _now();
                if (_sessionTimeout > TimeSpan.Zero && _lastBackground.HasValue && now - _lastBackground.Value >= _sessionTimeout)
                {
                    _sessionId = Ulid.New(now);
                }
                _lastBackground = null;
            }
        }

        /// <summary>
        /// Satın alma ya da abonelik beyanı (<c>feralin_purchase</c>). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı
        /// onaylarsa REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; <c>verified</c> hiçbir zaman gönderilmez. Sözleşme dışı girdide
        /// (tutar tam sayı küçük birim değil, para birimi ISO 4217 değil, işlem kimliği yok vb.) olay üretilmez ve <c>null</c> döner.
        /// </summary>
        public TrackedEvent TrackRevenue(RevenueInput input)
        {
            var props = RevenueEvent.Properties(input);
            if (props == null)
            {
                Warn("feralin_purchase: girdi sözleşmeye uymuyor, olay üretilmedi");
                return null;
            }
            return Track(RevenueEvent.Name, props);
        }

        /// <summary>
        /// Reklam geliri (<c>fr_ad_revenue</c>): ağ, birim, biçim, küçük birimde gelir ve para birimi. Satın alma gelirinden ayrıdır;
        /// deftere <c>feralin_purchase</c> olarak girmez. Sözleşme dışı girdide <c>null</c> döner.
        /// </summary>
        public TrackedEvent TrackAdRevenue(AdRevenueInput input)
        {
            var props = AdRevenueEvent.Properties(input);
            if (props == null)
            {
                Warn("fr_ad_revenue: girdi sözleşmeye uymuyor, olay üretilmedi");
                return null;
            }
            return Track(AdRevenueEvent.Name, props);
        }

        /// <summary>
        /// Kullanıcıyı bir gruba (hesap, ekip, klan) bağlar: <c>fr_group</c> olayı, <c>group_id</c> ve isteğe bağlı özellikler. Grup kimliği
        /// en çok 128 karakter olmalı ve kişisel veri taşımamalıdır. Sunucuda ayrı grup profili tutulmaz; olay olarak saklanır.
        /// </summary>
        public TrackedEvent Group(string groupId, IEnumerable<KeyValuePair<string, object>> traits = null)
        {
            if (string.IsNullOrEmpty(groupId) || groupId.Length > EventRules.MaxIdentifierLength)
            {
                Warn("fr_group: geçersiz group_id, olay üretilmedi");
                return null;
            }
            var props = EventRules.SanitizeProperties(traits, out _);
            props["group_id"] = groupId;
            return Track(GroupEventName, props);
        }

        /// <summary>
        /// Kullanıcı özelliklerini bildirir: <c>fr_user_properties</c> olayı. Geçerli özellik yoksa olay üretilmez. E-posta, telefon gibi
        /// kişisel veri vermeyin. Sunucuda ayrı profil deposu yoktur; olay olarak saklanır.
        /// </summary>
        public TrackedEvent SetUserProperties(IEnumerable<KeyValuePair<string, object>> properties)
        {
            var props = EventRules.SanitizeProperties(properties, out _);
            if (props.Count == 0)
            {
                Warn("fr_user_properties: geçerli özellik yok, olay üretilmedi");
                return null;
            }
            return Track(UserPropertiesEventName, props);
        }

        /// <summary>
        /// Hata olayı (<c>fr_error</c>). İleti ve yığın kişisel veriden (e-posta, IP, belirteç, kullanıcı yolu, URL sorgusu) arındırılır; çerçeveler
        /// dosya yolu, satır ve adres olmadan normalleştirilir ve hata türüyle birlikte parmak izi özeti (<c>fingerprint</c>) üretilir.
        /// Örnekleme (<see cref="ErrorOptions.SampleRate"/>) ve hız sınırı (dakikada toplam ve parmak izi başına) uygulanır; sınıra takılan
        /// hatalar sayılır ve sonraki hata olayına <c>suppressed_count</c> olarak yazılır. Gönderilmeyen hata için <c>null</c> döner.
        /// </summary>
        public TrackedEvent CaptureError(string errorType, string message, string stackTrace = null, bool handled = true, string source = ErrorSource.Manual)
        {
            try
            {
                Consent consent;
                lock (_gate)
                {
                    if (_closed)
                    {
                        return null;
                    }
                    consent = _consent;
                }
                if (!consent.Analytics)
                {
                    return null;
                }
                var options = _errors;
                if (options.SampleRate <= 0 || (options.SampleRate < 1 && _random() >= options.SampleRate))
                {
                    return null;
                }
                var type = ErrorSanitizer.Scrub(string.IsNullOrEmpty(errorType) ? "Error" : errorType, 64);
                if (type.Length == 0)
                {
                    type = "Error";
                }
                var frames = ErrorSanitizer.NormalizeFrames(stackTrace, Math.Max(1, options.MaxFrames));
                var fingerprint = ErrorSanitizer.Fingerprint(type, frames);

                long suppressed;
                lock (_gate)
                {
                    if (!AdmitErrorLocked(fingerprint, options))
                    {
                        _errorsSuppressed++;
                        _errorsSuppressedPending++;
                        return null;
                    }
                    suppressed = _errorsSuppressedPending;
                    _errorsSuppressedPending = 0;
                }

                // Alan adları ve türleri packages/schemas/utp/v1/event.schema.json fr_error ile aynıdır; toplayıcı bunun dışındaki alanı düşürür.
                // Bastırılan hata sayısı (suppressed) ve örnekleme oranı tel üzerinde taşınmaz, yalnız GetStatus().ErrorsSuppressed'da görünür.
                var props = new Dictionary<string, object>(StringComparer.Ordinal)
                {
                    ["error_type"] = type,
                    ["fingerprint"] = fingerprint,
                    ["frame_count"] = frames.Count,
                    ["handled"] = handled,
                    ["fatal"] = source == ErrorSource.UnhandledException,
                    ["origin"] = ErrorOrigin(source, handled),
                };
                var cleanMessage = ErrorSanitizer.Scrub(message, Math.Min(200, Math.Max(16, options.MaxMessageLength)));
                if (cleanMessage.Length > 0)
                {
                    props["message"] = cleanMessage;
                }
                if (frames.Count > 0)
                {
                    props["top_frame"] = frames[0].Length > 160 ? frames[0].Substring(0, 160) : frames[0];
                }
                var version = _defaultContext?.AppVersion;
                if (!string.IsNullOrEmpty(version) && version.Length <= 32)
                {
                    props["app_version"] = version;
                }
                _ = suppressed;
                return Track(ErrorEventName, props);
            }
            catch (Exception ex)
            {
                // Hata yakalayıcısı hiçbir koşulda oyunu düşürmez.
                Warn("hata olayı üretilemedi: " + ex.GetType().Name);
                return null;
            }
        }

        // Şema origin değerleri: window_onerror, unhandledrejection, uncaught_exception, handled, manual.
        private static string ErrorOrigin(string source, bool handled)
        {
            switch (source)
            {
                case ErrorSource.UnhandledException:
                case ErrorSource.UnobservedTask:
                case ErrorSource.LogException:
                    return "uncaught_exception";
                case ErrorSource.LogError:
                    return "handled";
                default:
                    return handled ? "manual" : "uncaught_exception";
            }
        }

        // Kayan dakika penceresi: hem toplam hem aynı parmak izi için üst sınır. Sınır sıfırsa hata olayı üretilmez.
        private bool AdmitErrorLocked(string fingerprint, ErrorOptions options)
        {
            if (options.MaxPerMinute <= 0 || options.MaxPerFingerprintPerMinute <= 0)
            {
                return false;
            }
            var now = _now();
            Prune(_errorTimes, now);
            if (_errorTimes.Count >= options.MaxPerMinute)
            {
                return false;
            }
            if (!_errorTimesByFingerprint.TryGetValue(fingerprint, out var perFingerprint))
            {
                if (_errorTimesByFingerprint.Count >= MaxFingerprintWindows)
                {
                    var stale = new List<string>();
                    foreach (var pair in _errorTimesByFingerprint)
                    {
                        Prune(pair.Value, now);
                        if (pair.Value.Count == 0)
                        {
                            stale.Add(pair.Key);
                        }
                    }
                    foreach (var key in stale)
                    {
                        _errorTimesByFingerprint.Remove(key);
                    }
                    if (_errorTimesByFingerprint.Count >= MaxFingerprintWindows)
                    {
                        _errorTimesByFingerprint.Clear();
                    }
                }
                perFingerprint = new List<DateTimeOffset>();
                _errorTimesByFingerprint[fingerprint] = perFingerprint;
            }
            Prune(perFingerprint, now);
            if (perFingerprint.Count >= options.MaxPerFingerprintPerMinute)
            {
                return false;
            }
            _errorTimes.Add(now);
            perFingerprint.Add(now);
            return true;
        }

        private static void Prune(List<DateTimeOffset> times, DateTimeOffset now)
        {
            var cut = now - ErrorWindow;
            times.RemoveAll(time => time <= cut);
        }

        internal string FormatMillis(long millis) => MiniJson.FormatTime(DateTimeOffset.FromUnixTimeMilliseconds(millis));

        internal static string Millis(DateTimeOffset value) => value.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture);
    }
}
