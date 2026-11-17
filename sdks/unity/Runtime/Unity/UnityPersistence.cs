#if UNITY_5_3_OR_NEWER
using System;
using System.IO;
using System.Runtime.InteropServices;
using UnityEngine;

namespace Feralin.Unity
{
    /// <summary>
    /// Platforma uygun şifreli kalıcı kuyruğu kurar. Anahtar korumasının gücü platforma bağlıdır ve <see cref="FeralinStatus.QueueProtection"/>
    /// ile açıkça bildirilir:
    /// <list type="bullet">
    /// <item><description>Android: <c>android_keystore</c>. Veri anahtarı, dışarı aktarılamayan Android Keystore AES anahtarıyla sarılır (<c>FeralinKeystore.java</c>).</description></item>
    /// <item><description>iOS: <c>ios_keychain</c>. Veri anahtarı Keychain'de (<c>AfterFirstUnlockThisDeviceOnly</c>) durur (<c>FeralinNative.mm</c>).</description></item>
    /// <item><description>Windows (Editor ve oyuncu): <c>windows_dpapi</c>, DPAPI kullanılabiliyorsa (yansıma ile aranır).</description></item>
    /// <item><description>macOS, Linux, diğer: <c>local_file</c>. Anahtar kuyruğun yanındaki dosyada durur; yalnızca sıradan inceleme ve dosya kopyalamaya karşı korur, aynı kullanıcı hesabına erişen biri anahtarı okuyabilir.</description></item>
    /// <item><description>WebGL: kalıcı kuyruk kapalıdır (bellek içi).</description></item>
    /// </list>
    /// Anahtar alınamazsa düz metne düşülmez: kuyruk bellekte kalır.
    /// </summary>
    public static class UnityPersistence
    {
        /// <summary>Şifreli kalıcı depoyu oluşturur; kurulamazsa <c>null</c> (kuyruk bellekte kalır).</summary>
        public static IEventStore CreateEncryptedStore(Action<string> log, out string protection)
        {
            protection = null;
#if UNITY_WEBGL
            return null;
#else
            try
            {
                var directory = Path.Combine(Application.persistentDataPath, "feralin");
                var provider = CreateKeyProvider(directory, log);
                var key = provider.GetOrCreateKey();
                if (key == null)
                {
                    log?.Invoke("kuyruk anahtarı alınamadı, kalıcı kuyruk kapalı");
                    return null;
                }
                protection = provider.Protection;
                return new EncryptedEventStore(new FileEventStore(directory, log), new AesGcmPayloadCipher(key));
            }
            catch (Exception ex)
            {
                log?.Invoke("kalıcı kuyruk kurulamadı: " + ex.GetType().Name);
                return null;
            }
#endif
        }

        private static IQueueKeyProvider CreateKeyProvider(string directory, Action<string> log)
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            return new WrappedFileKeyProvider(directory, new AndroidKeystoreProtector(), log);
#elif UNITY_IOS && !UNITY_EDITOR
            return new IosKeychainKeyProvider();
#else
            if (DpapiKeyProtector.IsAvailable)
            {
                return new WrappedFileKeyProvider(directory, new DpapiKeyProtector(), log);
            }
            return new WrappedFileKeyProvider(directory, new PlainKeyProtector(), log);
#endif
        }
    }

#if UNITY_ANDROID && !UNITY_EDITOR
    /// <summary>Android Keystore ile sarmalama: <c>FeralinKeystore.java</c> (AES-256-GCM, anahtar cihazdan çıkmaz, yedekle taşınmaz).</summary>
    internal sealed class AndroidKeystoreProtector : IKeyProtector
    {
        public string Protection => "android_keystore";

        public byte[] Protect(byte[] data) => Call("wrap", data);

        public byte[] Unprotect(byte[] data) => Call("unwrap", data);

        private static byte[] Call(string method, byte[] data)
        {
            try
            {
                using (var bridge = new AndroidJavaClass("com.feralin.unity.FeralinKeystore"))
                {
                    return bridge.CallStatic<byte[]>(method, data);
                }
            }
            catch (Exception)
            {
                // Sınıf yok ya da Keystore kullanılamıyor: anahtar sarılamaz, kuyruk bellekte kalır.
                return null;
            }
        }
    }
#endif

#if UNITY_IOS && !UNITY_EDITOR
    /// <summary>iOS Keychain: 32 baytlık veri anahtarı doğrudan Keychain'de durur, dosyaya yazılmaz.</summary>
    internal sealed class IosKeychainKeyProvider : IQueueKeyProvider
    {
        private const string Account = "com.feralin.sdk.queue.v1";

        [DllImport("__Internal")]
        private static extern int feralin_keychain_load(string account, byte[] buffer, int capacity);

        [DllImport("__Internal")]
        private static extern int feralin_keychain_save(string account, byte[] data, int length);

        [DllImport("__Internal")]
        private static extern int feralin_keychain_delete(string account);

        public string Protection => "ios_keychain";

        public byte[] GetOrCreateKey()
        {
            try
            {
                var buffer = new byte[32];
                var loaded = feralin_keychain_load(Account, buffer, buffer.Length);
                if (loaded == 32)
                {
                    return buffer;
                }
                if (loaded != 0)
                {
                    // Okuma hatası (ör. cihaz ilk kilit açılışından önce): var olan anahtar ezilmez, kuyruk bellekte kalır.
                    return null;
                }
                var fresh = new byte[32];
                using (var rng = System.Security.Cryptography.RandomNumberGenerator.Create())
                {
                    rng.GetBytes(fresh);
                }
                return feralin_keychain_save(Account, fresh, fresh.Length) == 0 ? fresh : null;
            }
            catch (Exception)
            {
                return null;
            }
        }

        public void DeleteKey()
        {
            try
            {
                feralin_keychain_delete(Account);
            }
            catch (Exception)
            {
                // Silinemeyen anahtar sonraki açılışta yeniden denenir.
            }
        }
    }
#endif

    /// <summary>
    /// Windows DPAPI (<c>ProtectedData</c>, mevcut kullanıcı kapsamı). Unity'nin .NET Standard profilinde sınıf bulunmayabilir; bu yüzden
    /// yansımayla aranır ve yoksa <see cref="IsAvailable"/> <c>false</c> olur.
    /// </summary>
    internal sealed class DpapiKeyProtector : IKeyProtector
    {
        private static readonly Type Protected = FindType();
        private static readonly byte[] Entropy = System.Text.Encoding.UTF8.GetBytes("feralin.queue.v1");

        public static bool IsAvailable =>
            (Application.platform == RuntimePlatform.WindowsEditor || Application.platform == RuntimePlatform.WindowsPlayer) && Protected != null;

        public string Protection => "windows_dpapi";

        public byte[] Protect(byte[] data) => Invoke("Protect", data);

        public byte[] Unprotect(byte[] data) => Invoke("Unprotect", data);

        private static Type FindType()
        {
            foreach (var name in new[] { "System.Security.Cryptography.ProtectedData, System.Security", "System.Security.Cryptography.ProtectedData, System.Security.Cryptography.ProtectedData" })
            {
                try
                {
                    var type = Type.GetType(name, false);
                    if (type != null)
                    {
                        return type;
                    }
                }
                catch (Exception)
                {
                    // Derleme yüklenemedi: sıradaki ad denenir.
                }
            }
            return null;
        }

        private static byte[] Invoke(string method, byte[] data)
        {
            try
            {
                var scope = Type.GetType("System.Security.Cryptography.DataProtectionScope, System.Security", false)
                    ?? Type.GetType("System.Security.Cryptography.DataProtectionScope, System.Security.Cryptography.ProtectedData", false);
                if (Protected == null || scope == null)
                {
                    return null;
                }
                var currentUser = Enum.ToObject(scope, 0);
                return (byte[])Protected.GetMethod(method, new[] { typeof(byte[]), typeof(byte[]), scope }).Invoke(null, new object[] { data, Entropy, currentUser });
            }
            catch (Exception)
            {
                return null;
            }
        }
    }
}
#endif
