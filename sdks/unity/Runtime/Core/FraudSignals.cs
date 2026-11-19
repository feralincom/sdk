using System;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Feralin.Unity
{
    /// <summary>
    /// SDK imza anahtarı: <see cref="Id"/> panelde görünen kimlik (<c>sgn_…</c>), <see cref="Secret"/> üretildiği anda bir kez gösterilen
    /// değer (<c>fsk_…</c>). Anahtar uygulamaya gömülüdür: sürüm başına ayrı anahtar üretip eskisini panelden iptal edebilirsiniz.
    /// </summary>
    public sealed class SigningKey
    {
        private static readonly Regex IdPattern = new Regex("^sgn_[a-z0-9]{12,40}$", RegexOptions.CultureInvariant);

        /// <summary>Anahtarı oluşturur; biçim <see cref="FeralinClient"/> kurucusunda denetlenir.</summary>
        public SigningKey(string id, string secret)
        {
            Id = id;
            Secret = secret;
        }

        /// <summary>Anahtar kimliği (<c>sgn_…</c>).</summary>
        public string Id { get; }
        /// <summary>Anahtar değeri (<c>fsk_…</c>, 16-200 karakter). Loglanmaz.</summary>
        public string Secret { get; }

        /// <summary>Hata mesajı döner; geçerliyse <c>null</c>. Mesajda anahtar değeri bulunmaz.</summary>
        internal string ValidationError()
        {
            if (Id == null || !IdPattern.IsMatch(Id) || Id.EndsWith("\n", StringComparison.Ordinal))
            {
                return "SigningKey.Id biçimi geçersiz";
            }
            if (Secret == null || Secret.Length < 16 || Secret.Length > 200)
            {
                return "SigningKey.Secret 16-200 karakter olmalı";
            }
            return null;
        }

        /// <summary>Anahtar değeri loglara ve hata dökümlerine düşmesin.</summary>
        public override string ToString() => "SigningKey(id=" + Id + ")";
    }

    /// <summary>
    /// Atıf olaylarının (ilk açılış, bağlantı açılışı) imzası. Sunucu, projenin imza anahtarıyla doğrular; imzasız ya da bozuk imzalı kurulum
    /// projenin seçtiği kurala göre işaretlenir ya da reddedilir. İmza olayın kimliğine bağlıdır: başka olaya taşınamaz.
    ///
    /// Biçim: <c>v1.&lt;anahtar kimliği&gt;.&lt;unix saniye&gt;.&lt;hex hmac-sha256&gt;</c>; imzalanan dizgi
    /// <c>v1\n&lt;saniye&gt;\n&lt;event_id&gt;\n&lt;event_name&gt;\n&lt;anonymous_id&gt;</c> (Android SDK <c>EventSigner</c> ile aynı).
    /// Anahtar uygulamaya gömülüdür: kararlı bir saldırgan paketten çıkarabilir. İmza sahte kurulum üretmeyi zorlaştırır, imkânsız kılmaz.
    /// </summary>
    internal static class EventSigner
    {
        /// <summary>İmzanın yazıldığı olay özelliği.</summary>
        public const string PropertyName = "fr_sig";

        private const string Hex = "0123456789abcdef";

        public static string Sign(string keyId, string secret, long atSeconds, string eventId, string eventName, string anonymousId)
        {
            var seconds = atSeconds.ToString(CultureInfo.InvariantCulture);
            byte[] digest;
            using (var mac = new HMACSHA256(Encoding.UTF8.GetBytes(secret)))
            {
                digest = mac.ComputeHash(Encoding.UTF8.GetBytes("v1\n" + seconds + "\n" + eventId + "\n" + eventName + "\n" + (anonymousId ?? "")));
            }
            var hex = new StringBuilder(digest.Length * 2);
            foreach (var value in digest)
            {
                hex.Append(Hex[value >> 4]).Append(Hex[value & 0x0f]);
            }
            return "v1." + keyId + "." + seconds + "." + hex;
        }
    }

    /// <summary>
    /// Uygulamanın emülatörde çalışıp çalışmadığı. Tek bir evet/hayır değeri üretir ve yalnız <c>true</c> ise ilk açılışa eklenir
    /// (<c>device_emulator</c>); cihaz kimliği ya da parmak izi üretmez, <c>Build</c> alanlarının kendisi gönderilmez.
    ///
    /// Sezgiseldir ve Android SDK ile aynıdır: yaygın emülatörlerin (Android Studio, Genymotion, bulut cihaz çiftlikleri) bilinen
    /// <c>android.os.Build</c> değerlerine bakar. Kendini gerçek cihaz gibi gösteren özel emülatörü görmez; bu yüzden sunucuda kesin kanıt
    /// değil, işaret sayılır.
    /// </summary>
    public static class EmulatorCheck
    {
        /// <summary>İlk açılış olayındaki özellik adı (<c>device_emulator</c>).</summary>
        public const string PropertyName = "device_emulator";

        /// <summary><c>android.os.Build</c> alanlarından sınıflama; <c>null</c> alan boş sayılır.</summary>
        public static bool IsEmulator(string fingerprint, string model, string manufacturer, string brand, string device, string product, string hardware)
        {
            var print = fingerprint ?? "";
            var name = model ?? "";
            var item = product ?? "";
            var board = hardware ?? "";
            return Starts(print, "generic")
                || Starts(print, "unknown")
                || Has(print, "/sdk_gphone")
                || Has(print, "vbox")
                || Has(name, "google_sdk")
                || Has(name, "Emulator")
                || Has(name, "Android SDK built for")
                || Starts(name, "sdk_gphone")
                || Has(manufacturer ?? "", "Genymotion")
                || (Starts(brand ?? "", "generic") && Starts(device ?? "", "generic"))
                || item == "google_sdk"
                || Starts(item, "sdk_gphone")
                || Starts(item, "sdk_google")
                || Has(item, "emulator")
                || Has(item, "simulator")
                || Starts(item, "vbox")
                || board == "goldfish"
                || board == "ranchu"
                || Has(board, "vbox");
        }

        // Kültürden bağımsız karşılaştırma: Türkçe kültürde de sonuç aynıdır.
        private static bool Starts(string text, string prefix) => text.StartsWith(prefix, StringComparison.Ordinal);

        private static bool Has(string text, string part) => text.IndexOf(part, StringComparison.Ordinal) >= 0;
    }

    /// <summary>Emülatör okuyucusu (Unity katmanı Android'de verir). Yalnız evet/hayır döndürür; <c>Build</c> alanlarını döndürmez.</summary>
    public interface IEmulatorSource
    {
        bool Read();
    }

    /// <summary>
    /// Huawei AppGallery kurulum yönlendiricisi okuyucusu (Unity katmanı Android'de verir): AppGallery içerik sağlayıcısının
    /// (<c>content://com.huawei.appmarket.commondata/item/5</c>) yalnız <c>referrer</c> sütununu döndürür, yoksa <c>null</c>. Ham dizgi
    /// yalnız çekirdeğe verilir, izin listesinden geçer ve saklanmaz.
    /// </summary>
    public interface IHuaweiReferrerSource
    {
        string Read();
    }

    /// <summary>
    /// AppGallery'nin verdiği <c>referrer</c> dizgisini kanıta çevirir. AppGallery, mağaza linkindeki <c>referrer</c> değerini kurulumla
    /// birlikte saklar; yalnız izin listesindeki alanlar (<c>fr_click</c>, <c>fr_dl</c>, <c>utm_*</c>) okunur. Kurallar Android SDK'daki
    /// <c>HuaweiInstallReferrerSource</c> ile aynıdır. Gerçek Huawei cihazında denenmedi.
    /// </summary>
    public static class HuaweiInstallReferrer
    {
        // AppGallery linkindeki referrer en çok 500 karakterdir; daha uzunu bizim linkimizden gelmemiştir.
        private const int MaxReferrerChars = 2000;

        /// <summary>Linkteki tıklama kimliği ve UTM, kaynağı <c>huawei_install_referrer</c> olarak; kanıt yoksa <c>null</c>.</summary>
        public static AttributionParams Parse(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw) || raw.Length > MaxReferrerChars)
            {
                return null;
            }
            var parsed = AttributionParams.ParseQuery(raw);
            return parsed.IsEmpty ? null : parsed.WithSource(AttributionSource.HuaweiInstallReferrer);
        }
    }

    /// <summary>
    /// Mağaza yönlendiricisi zinciri: önce Google Play okunur; Play kanıt vermezse (hizmet yok, organik varsayılan ya da boş) AppGallery'ye
    /// sorulur. Play hizmeti olmayan Huawei cihazında Play okuması sonuçsuz kalır ve kanıt AppGallery'den gelir. İkisi de kanıt vermezse
    /// Play sonucu korunur.
    /// </summary>
    internal static class StoreReferrerChain
    {
        /// <param name="playRaw">Play Install Referrer dizgisi; okunamadıysa <c>null</c>.</param>
        /// <param name="huawei">AppGallery okuyucusu; yoksa <c>null</c>. Okuma hatası kanıt yok sayılır.</param>
        public static AttributionParams Resolve(string playRaw, IHuaweiReferrerSource huawei)
        {
            var play = playRaw == null ? null : AttributionParams.ParseQuery(playRaw);
            if ((play != null && !play.IsEmpty && !play.IsPlayOrganicDefault) || huawei == null)
            {
                return play;
            }
            string raw;
            try
            {
                raw = huawei.Read();
            }
            catch (Exception)
            {
                // AppGallery yok, sağlayıcı görünmüyor ya da erişim reddedildi.
                raw = null;
            }
            return HuaweiInstallReferrer.Parse(raw) ?? play;
        }
    }
}
