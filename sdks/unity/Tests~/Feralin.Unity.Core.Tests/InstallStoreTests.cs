using Feralin.Unity;
using Xunit;

namespace Feralin.Unity.Core.Tests;

public class InstallStoreTests
{
    private static readonly string[] Allowed =
    {
        "google_play", "samsung_galaxy_store", "huawei_appgallery", "amazon_appstore", "xiaomi_getapps", "oppo_app_market",
        "vivo_app_store", "honor_app_market", "sideload", "unknown", "other",
    };

    [Theory]
    [InlineData("com.android.vending", "google_play")]
    [InlineData("com.google.android.feedback", "google_play")]
    [InlineData("com.sec.android.app.samsungapps", "samsung_galaxy_store")]
    [InlineData("com.huawei.appmarket", "huawei_appgallery")]
    [InlineData("com.amazon.venezia", "amazon_appstore")]
    [InlineData("com.xiaomi.market", "xiaomi_getapps")]
    [InlineData("com.xiaomi.mipicks", "xiaomi_getapps")]
    [InlineData("com.oppo.market", "oppo_app_market")]
    [InlineData("com.heytap.market", "oppo_app_market")]
    [InlineData("com.vivo.appstore", "vivo_app_store")]
    [InlineData("com.bbk.appstore", "vivo_app_store")]
    [InlineData("com.hihonor.appmarket", "honor_app_market")]
    public void KnownStoresAreClassified(string installer, string expected)
    {
        Assert.Equal(expected, InstallStore.Classify(installer));
    }

    [Theory]
    [InlineData("com.google.android.packageinstaller", "sideload")]
    [InlineData("com.android.packageinstaller", "sideload")]
    [InlineData("com.samsung.android.packageinstaller", "sideload")]
    [InlineData("com.miui.packageinstaller", "sideload")]
    [InlineData(null, "unknown")]
    [InlineData("", "unknown")]
    [InlineData("  ", "unknown")]
    [InlineData("com.ornek.ozelmagaza", "other")]
    [InlineData("google_play", "other")]
    public void SideloadUnknownAndOtherAreSeparate(string installer, string expected)
    {
        Assert.Equal(expected, InstallStore.Classify(installer));
    }

    [Fact]
    public void WhitespaceAndCaseAreNormalized()
    {
        Assert.Equal("google_play", InstallStore.Classify(" Com.Android.Vending "));
        // Türkçe kültürde büyük I küçük ı olmamalı: sınıflama kültürden bağımsızdır.
        var previous = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("tr-TR");
            Assert.Equal("google_play", InstallStore.Classify("COM.ANDROID.VENDING"));
            Assert.Equal("xiaomi_getapps", InstallStore.Classify("COM.XIAOMI.MIPICKS"));
        }
        finally
        {
            System.Globalization.CultureInfo.CurrentCulture = previous;
        }
    }

    [Fact]
    public void ResultIsAlwaysInClosedListAndNeverThePackageName()
    {
        foreach (var name in new[] { "com.ornek.ozelmagaza", "com.android.vending.sahte", "x", "com.aurora.store", null, "sideload " })
        {
            var store = InstallStore.Classify(name);
            Assert.Contains(store, Allowed);
            Assert.True(InstallStore.IsKnown(store));
        }
        foreach (var value in Allowed)
        {
            Assert.True(InstallStore.IsKnown(value));
        }
        Assert.False(InstallStore.IsKnown("com.android.vending"));
        Assert.False(InstallStore.IsKnown("Google_Play"));
        Assert.False(InstallStore.IsKnown(""));
        Assert.False(InstallStore.IsKnown(null));
    }
}
