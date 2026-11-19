using System;
using System.Collections.Generic;

namespace Feralin.Unity
{
    /// <summary>
    /// Kurulum mağazası: Android'de uygulamayı cihaza kuran paketin adından türetilir. Kişisel veri değildir; cihaz ya da kullanıcı kimliği
    /// taşımaz. Liste ve sınıflar Android SDK ile aynıdır. Değer işletim sisteminin bildirdiğidir, mağaza tarafından doğrulanmaz: yan yükleme
    /// ve geliştirme kurulumu ayrı sınıflardır, bilinmeyen kurucu <c>other</c> olur ve paket adı olaya yazılmaz.
    /// </summary>
    public static class InstallStore
    {
        /// <summary>İlk açılış olayındaki özellik adı (<c>install_store</c>).</summary>
        public const string PropertyName = "install_store";

        public const string GooglePlay = "google_play";
        public const string SamsungGalaxyStore = "samsung_galaxy_store";
        public const string HuaweiAppGallery = "huawei_appgallery";
        public const string AmazonAppstore = "amazon_appstore";
        public const string XiaomiGetApps = "xiaomi_getapps";
        public const string OppoAppMarket = "oppo_app_market";
        public const string VivoAppStore = "vivo_app_store";
        public const string HonorAppMarket = "honor_app_market";
        /// <summary>Dosyadan kurulum (tarayıcı, dosya yöneticisi, sistem paket kurucusu).</summary>
        public const string Sideload = "sideload";
        /// <summary>Kurucu bildirilmedi: <c>adb install</c>, geliştirme kurulumu ya da ön yüklü uygulama.</summary>
        public const string Unknown = "unknown";
        public const string Other = "other";

        private static readonly Dictionary<string, string> Stores = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["com.android.vending"] = GooglePlay,
            ["com.google.android.feedback"] = GooglePlay,
            ["com.sec.android.app.samsungapps"] = SamsungGalaxyStore,
            ["com.huawei.appmarket"] = HuaweiAppGallery,
            ["com.amazon.venezia"] = AmazonAppstore,
            ["com.xiaomi.market"] = XiaomiGetApps,
            ["com.xiaomi.mipicks"] = XiaomiGetApps,
            ["com.oppo.market"] = OppoAppMarket,
            ["com.heytap.market"] = OppoAppMarket,
            ["com.vivo.appstore"] = VivoAppStore,
            ["com.bbk.appstore"] = VivoAppStore,
            ["com.hihonor.appmarket"] = HonorAppMarket,
            ["com.google.android.packageinstaller"] = Sideload,
            ["com.android.packageinstaller"] = Sideload,
            ["com.samsung.android.packageinstaller"] = Sideload,
            ["com.miui.packageinstaller"] = Sideload,
        };

        private static readonly HashSet<string> Known = new HashSet<string>(StringComparer.Ordinal)
        {
            GooglePlay, SamsungGalaxyStore, HuaweiAppGallery, AmazonAppstore, XiaomiGetApps, OppoAppMarket, VivoAppStore, HonorAppMarket,
            Sideload, Unknown, Other,
        };

        /// <summary>Kurucu paket adından mağaza sınıfı. Boş ad <c>unknown</c>, listede olmayan ad <c>other</c>.</summary>
        public static string Classify(string installerPackage)
        {
            var name = installerPackage?.Trim().ToLowerInvariant();
            if (string.IsNullOrEmpty(name))
            {
                return Unknown;
            }
            return Stores.TryGetValue(name, out var store) ? store : Other;
        }

        /// <summary>Değer kapalı listedeyse <c>true</c>. Çekirdek, kaynaktan gelen değeri olaya yazmadan önce bununla denetler.</summary>
        public static bool IsKnown(string value) => value != null && Known.Contains(value);
    }

    /// <summary>
    /// Kurulum mağazası okuyucusu (Unity katmanı Android'de verir). <see cref="InstallStore"/> listesinden bir sınıf döndürür; kurucu paket
    /// adını döndürmez. Liste dışı değer çekirdekte atılır.
    /// </summary>
    public interface IInstallStoreSource
    {
        string Read();
    }
}
