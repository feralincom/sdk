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
