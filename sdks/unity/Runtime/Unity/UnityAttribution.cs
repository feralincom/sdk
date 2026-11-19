#if UNITY_5_3_OR_NEWER
using System;
using System.Threading;
using UnityEngine;
#if UNITY_IOS && !UNITY_EDITOR
using System.Runtime.InteropServices;
#endif

namespace Feralin.Unity
{
    /// <summary>
    /// Platform atıf kaynakları. Android Play Install Referrer ve iOS AdServices yalnız oyuncu derlemesinde çalışır; Editor ve diğer
    /// platformlarda <c>null</c> döner (kanıt yoktur). Hiçbiri cihazda sınanmamıştır: Android ve iOS oyuncu derlemesi bu depoda yoktur.
    /// </summary>
    public static class UnityAttribution
    {
        /// <summary>
        /// Android'de Play Install Referrer kaynağı. Diğer platformlarda referrer kavramı yoktur: ilk açılış yine bir kez sayılsın diye
        /// hemen <c>null</c> (kanıt yok) döndüren kaynak verilir; olay <c>attribution_source=none</c> taşır.
        /// </summary>
        /// <summary>Meta Install Referrer okuyucusu: Android oyuncuda Java köprüsü, diğer platformlarda <c>null</c>.</summary>
        public static IMetaReferrerSource CreateMetaReferrerSource()
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            return new AndroidMetaReferrerSource();
#else
            return null;
#endif
        }

        /// <summary>Kurulum mağazası okuyucusu: Android oyuncuda <c>PackageManager</c>, diğer platformlarda <c>null</c> (alan eklenmez).</summary>
        public static IInstallStoreSource CreateInstallStoreSource()
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            return new AndroidInstallStoreSource();
#else
            return null;
#endif
        }

        /// <summary>Emülatör okuyucusu: Android oyuncuda <c>android.os.Build</c> alanları, diğer platformlarda <c>null</c> (alan eklenmez).</summary>
        public static IEmulatorSource CreateEmulatorSource()
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            return new AndroidEmulatorSource();
#else
            return null;
#endif
        }

        /// <summary>Huawei AppGallery kurulum yönlendiricisi okuyucusu: Android oyuncuda Java köprüsü, diğer platformlarda <c>null</c>.</summary>
        public static IHuaweiReferrerSource CreateHuaweiReferrerSource()
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            return new AndroidHuaweiReferrerSource();
#else
            return null;
#endif
        }

        public static IInstallReferrerSource CreateInstallReferrerSource()
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            return new AndroidInstallReferrerSource();
#else
            return new NoReferrerSource();
#endif
        }

        /// <summary>iOS'ta AdServices token kaynağı; diğer platformlarda <c>null</c>.</summary>
        public static IAdServicesTokenSource CreateAdServicesTokenSource()
        {
#if UNITY_IOS && !UNITY_EDITOR
            return new IosAdServicesTokenSource();
#else
            return null;
#endif
        }

        /// <summary>iOS ATT durumu; iOS dışında ya da okunamıyorsa <see cref="TrackingStatus.Unavailable"/>.</summary>
        public static TrackingStatus ReadTrackingStatus()
        {
#if UNITY_IOS && !UNITY_EDITOR
            return IosNative.ReadTrackingStatus();
#else
            return TrackingStatus.Unavailable;
#endif
        }
    }

    /// <summary>Meta Install Referrer: Android'de <c>FeralinMetaReferrer.java</c> ile Facebook/Instagram/Facebook Lite sağlayıcıları okunur.</summary>
    internal sealed class AndroidMetaReferrerSource : IMetaReferrerSource
    {
        public string Read(string appId)
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            AndroidJNI.AttachCurrentThread();
            try
            {
                using (var player = new AndroidJavaClass("com.unity3d.player.UnityPlayer"))
                using (var activity = player.GetStatic<AndroidJavaObject>("currentActivity"))
                using (var context = activity.Call<AndroidJavaObject>("getApplicationContext"))
                using (var bridge = new AndroidJavaClass("com.feralin.unity.FeralinMetaReferrer"))
                {
                    return bridge.CallStatic<string>("read", context, appId);
                }
            }
            catch (Exception)
            {
                // Sağlayıcı yok ya da JNI hatası: kanıt yoktur.
                return null;
            }
#else
            return null;
#endif
        }
    }

    /// <summary>
    /// Kurulum mağazası: uygulamayı kuran paketi <c>PackageManager</c> ile okur (Android 11+ <c>getInstallSourceInfo</c>, öncesi
    /// <c>getInstallerPackageName</c>) ve <see cref="InstallStore.Classify"/> ile kapalı listeye indirger. Paket adı bu sınıfın dışına çıkmaz.
    /// Okunamazsa <c>unknown</c> (Android SDK ile aynı). Cihazda sınanmamıştır: Android oyuncu derlemesi bu depoda yoktur.
    /// </summary>
    internal sealed class AndroidInstallStoreSource : IInstallStoreSource
    {
        public string Read()
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            string installer = null;
            AndroidJNI.AttachCurrentThread();
            try
            {
                using (var player = new AndroidJavaClass("com.unity3d.player.UnityPlayer"))
                using (var activity = player.GetStatic<AndroidJavaObject>("currentActivity"))
                using (var context = activity.Call<AndroidJavaObject>("getApplicationContext"))
                using (var manager = context.Call<AndroidJavaObject>("getPackageManager"))
                using (var version = new AndroidJavaClass("android.os.Build$VERSION"))
                {
                    var packageName = context.Call<string>("getPackageName");
                    if (version.GetStatic<int>("SDK_INT") >= 30)
                    {
                        using (var info = manager.Call<AndroidJavaObject>("getInstallSourceInfo", packageName))
                        {
                            installer = info.Call<string>("getInstallingPackageName");
                        }
                    }
                    else
                    {
                        installer = manager.Call<string>("getInstallerPackageName", packageName);
                    }
                }
            }
            catch (Exception)
            {
                // Paket bilgisi okunamadı ya da JNI hatası: kurucu bilinmiyor sayılır.
                installer = null;
            }
            return InstallStore.Classify(installer);
#else
            return null;
#endif
        }
    }

    /// <summary>
    /// Emülatör işareti: <c>android.os.Build</c> alanlarını okur ve <see cref="EmulatorCheck.IsEmulator"/> ile tek bir evet/hayıra indirger.
    /// Alanların kendisi bu sınıfın dışına çıkmaz. Okunamazsa <c>false</c>. Cihazda sınanmamıştır: Android oyuncu derlemesi bu depoda yoktur.
    /// </summary>
    internal sealed class AndroidEmulatorSource : IEmulatorSource
    {
        public bool Read()
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            AndroidJNI.AttachCurrentThread();
            try
            {
                using (var build = new AndroidJavaClass("android.os.Build"))
                {
                    return EmulatorCheck.IsEmulator(
                        build.GetStatic<string>("FINGERPRINT"),
                        build.GetStatic<string>("MODEL"),
                        build.GetStatic<string>("MANUFACTURER"),
                        build.GetStatic<string>("BRAND"),
                        build.GetStatic<string>("DEVICE"),
                        build.GetStatic<string>("PRODUCT"),
                        build.GetStatic<string>("HARDWARE"));
                }
            }
            catch (Exception)
            {
                // JNI hatası: işaret üretilmez.
                return false;
            }
#else
            return false;
#endif
        }
    }

    /// <summary>
    /// Huawei AppGallery kurulum yönlendiricisi: Android'de <c>FeralinHuaweiReferrer.java</c> AppGallery içerik sağlayıcısının yalnız
    /// <c>referrer</c> sütununu okur. Ham dizgi çekirdekte izin listesinden geçer. Cihazda sınanmamıştır.
    /// </summary>
    internal sealed class AndroidHuaweiReferrerSource : IHuaweiReferrerSource
    {
        public string Read()
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            AndroidJNI.AttachCurrentThread();
            try
            {
                using (var player = new AndroidJavaClass("com.unity3d.player.UnityPlayer"))
                using (var activity = player.GetStatic<AndroidJavaObject>("currentActivity"))
                using (var context = activity.Call<AndroidJavaObject>("getApplicationContext"))
                using (var bridge = new AndroidJavaClass("com.feralin.unity.FeralinHuaweiReferrer"))
                {
                    return bridge.CallStatic<string>("read", context);
                }
            }
            catch (Exception)
            {
                // AppGallery yok ya da JNI hatası: kanıt yoktur.
                return null;
            }
#else
            return null;
#endif
        }
    }

    internal sealed class NoReferrerSource : IInstallReferrerSource
    {
        public void Read(Action<string> onResult) => onResult(null);
    }

#if UNITY_ANDROID && !UNITY_EDITOR
    /// <summary>
    /// Resmî <c>com.android.installreferrer:installreferrer</c> kitaplığı (bağımlılık <c>Editor/FeralinDependencies.xml</c> ya da elle
    /// Gradle ile gelir). Üç deneme, sekiz saniye zaman aşımı; kitaplık yoksa ya da servis erişilemezse <c>null</c> (kanıt yok).
    /// Değer değişmez: çekirdek bunu kurulumda bir kez çağırır. Ham dizgi çekirdekte izin listesinden geçer ve saklanmaz.
    /// </summary>
    internal sealed class AndroidInstallReferrerSource : IInstallReferrerSource
    {
        private const int MaxAttempts = 3;
        private const int RetryDelayMs = 2000;
        private const int TimeoutMs = 8000;

        public void Read(Action<string> onResult) => Attempt(1, onResult);

        private static void Attempt(int number, Action<string> onResult)
        {
            var settled = 0;
            AndroidJavaObject client = null;
            Timer timeout = null;

            void Close()
            {
                try
                {
                    client?.Call("endConnection");
                }
                catch (Exception)
                {
                    // Bağlantı zaten kopmuş olabilir.
                }
            }

            void RetryOrFinish()
            {
                if (Interlocked.Exchange(ref settled, 1) != 0)
                {
                    return;
                }
                timeout?.Dispose();
                Close();
                if (number < MaxAttempts)
                {
                    Timer delay = null;
                    delay = new Timer(_ =>
                    {
                        delay?.Dispose();
                        Attempt(number + 1, onResult);
                    }, null, RetryDelayMs, Timeout.Infinite);
                }
                else
                {
                    onResult(null);
                }
            }

            void Finish(string referrer)
            {
                if (Interlocked.Exchange(ref settled, 1) != 0)
                {
                    return;
                }
                timeout?.Dispose();
                Close();
                onResult(referrer);
            }

            try
            {
                using (var player = new AndroidJavaClass("com.unity3d.player.UnityPlayer"))
                using (var activity = player.GetStatic<AndroidJavaObject>("currentActivity"))
                using (var context = activity.Call<AndroidJavaObject>("getApplicationContext"))
                using (var builderClass = new AndroidJavaClass("com.android.installreferrer.api.InstallReferrerClient"))
                using (var builder = builderClass.CallStatic<AndroidJavaObject>("newBuilder", context))
                {
                    client = builder.Call<AndroidJavaObject>("build");
                }
                timeout = new Timer(_ => RetryOrFinish(), null, TimeoutMs, Timeout.Infinite);
                client.Call("startConnection", new Listener(
                    code =>
                    {
                        // getInstallReferrer IPC'dir; geri çağrının geldiği iş parçacığında değil ayrı bir iş parçacığında okunur.
                        ThreadPool.QueueUserWorkItem(__ =>
                        {
                            AndroidJNI.AttachCurrentThread();
                            try
                            {
                                if (code == 0)
                                {
                                    Finish(ReadReferrer(client));
                                }
                                else if (code == 1 || code == -1)
                                {
                                    RetryOrFinish();
                                }
                                else
                                {
                                    // FEATURE_NOT_SUPPORTED, DEVELOPER_ERROR: bu cihazda yeniden denemek işe yaramaz.
                                    Finish(null);
                                }
                            }
                            finally
                            {
                                AndroidJNI.DetachCurrentThread();
                            }
                        });
                    },
                    RetryOrFinish));
            }
            catch (Exception)
            {
                // Kitaplık uygulamadan çıkarılmış ya da JNI hatası: kanıt yok.
                timeout?.Dispose();
                Finish(null);
            }
        }

        private static string ReadReferrer(AndroidJavaObject client)
        {
            try
            {
                using (var details = client.Call<AndroidJavaObject>("getInstallReferrer"))
                {
                    return details.Call<string>("getInstallReferrer");
                }
            }
            catch (Exception)
            {
                return null;
            }
        }

        private sealed class Listener : AndroidJavaProxy
        {
            private readonly Action<int> _setupFinished;
            private readonly Action _disconnected;

            public Listener(Action<int> setupFinished, Action disconnected)
                : base("com.android.installreferrer.api.InstallReferrerStateListener")
            {
                _setupFinished = setupFinished;
                _disconnected = disconnected;
            }

            // Java arayüz yöntem adları küçük harfle başlar; AndroidJavaProxy ada göre eşler.
            public void onInstallReferrerSetupFinished(int responseCode) => _setupFinished(responseCode);

            public void onInstallReferrerServiceDisconnected() => _disconnected();
        }
    }
#endif

#if UNITY_IOS && !UNITY_EDITOR
    internal static class IosNative
    {
        [DllImport("__Internal")]
        private static extern int feralin_att_status();

        [DllImport("__Internal")]
        private static extern int feralin_adservices_token(byte[] buffer, int capacity);

        public static TrackingStatus ReadTrackingStatus()
        {
            try
            {
                var value = feralin_att_status();
                return value >= 0 && value <= 4 ? (TrackingStatus)value : TrackingStatus.Unavailable;
            }
            catch (Exception)
            {
                return TrackingStatus.Unavailable;
            }
        }

        public static AdServicesTokenResult ReadAdServicesToken()
        {
            try
            {
                var buffer = new byte[16384];
                var length = feralin_adservices_token(buffer, buffer.Length);
                if (length > 0)
                {
                    return AdServicesTokenResult.FromToken(System.Text.Encoding.UTF8.GetString(buffer, 0, length));
                }
                return length == 0 ? AdServicesTokenResult.Unsupported() : AdServicesTokenResult.Failed();
            }
            catch (Exception)
            {
                return AdServicesTokenResult.Failed();
            }
        }
    }

    /// <summary>
    /// <c>AAAttribution.attributionToken()</c> eşzamanlıdır; oyun döngüsünü bloke etmesin diye ayrı iş parçacığında çağrılır. Sonuç, kaynağın
    /// oluşturulduğu (ana) iş parçacığına taşınır: UnityWebRequest yalnız orada çalışır.
    /// </summary>
    internal sealed class IosAdServicesTokenSource : IAdServicesTokenSource
    {
        private readonly SynchronizationContext _main = SynchronizationContext.Current;

        public void GetToken(Action<AdServicesTokenResult> onResult) =>
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var result = IosNative.ReadAdServicesToken();
                if (_main != null)
                {
                    _main.Post(__ => onResult(result), null);
                }
                else
                {
                    onResult(result);
                }
            });
    }
#endif
}
#endif
