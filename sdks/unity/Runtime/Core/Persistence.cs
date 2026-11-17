using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Feralin.Unity
{
    /// <summary>Diskteki olay: kimlik ve (şifreli ya da düz) gövde.</summary>
    public sealed class StoredEvent
    {
        /// <summary>Kimlik ve gövdeyi tutar.</summary>
        public StoredEvent(string id, string payload)
        {
            Id = id;
            Payload = payload;
        }

        /// <summary>Olay kimliği (ULID); tekrar gönderimde değişmez.</summary>
        public string Id { get; }
        /// <summary>Gövde.</summary>
        public string Payload { get; }
    }

    /// <summary>
    /// Kalıcı olay kuyruğu ve küçük işaret (marker) deposu. Çağrılar iş parçacığı güvenlidir ve oyuna hata fırlatmaz.
    /// Kuyruk üst sınırı ve eski olay atma kuralı istemcidedir; depo yalnız istenileni yazar ve siler.
    /// </summary>
    public interface IEventStore
    {
        /// <summary>Saklı olaylar, eskiden yeniye.</summary>
        IReadOnlyList<StoredEvent> Load();
        /// <summary>Olayı sona ekler.</summary>
        void Add(StoredEvent storedEvent);
        /// <summary>Verilen kimlikli olayları siler.</summary>
        void Remove(IReadOnlyCollection<string> eventIds);
        /// <summary>Tüm olayları siler (işaretlere dokunmaz).</summary>
        void Clear();
        /// <summary>İşaret değeri; yoksa <c>null</c>.</summary>
        string GetMarker(string key);
        /// <summary>İşaret yazar.</summary>
        void PutMarker(string key, string value);
        /// <summary>İşareti siler.</summary>
        void RemoveMarker(string key);
    }

    /// <summary>Olay gövdesini diskte şifreli tutar. İlişkilendirilmiş veri olay kimliğidir: satır başka kimliğe taşınırsa açılmaz.</summary>
    public interface IPayloadCipher
    {
        /// <summary>Şifreler.</summary>
        string Encrypt(string plain, string aad);
        /// <summary>Açılamazsa (bozuk, kurcalanmış, anahtar kayıp) <c>null</c>; fırlatmaz.</summary>
        string Decrypt(string stored, string aad);
    }

    /// <summary>
    /// AES-256-GCM, Android SDK ile aynı satır biçimi: <c>enc1:</c> + hex(iv ‖ şifreli metin ‖ etiket), ilişkilendirilmiş veri olay kimliği.
    /// </summary>
    public sealed class AesGcmPayloadCipher : IPayloadCipher
    {
        /// <summary>Şifreli satır öneki.</summary>
        public const string Prefix = "enc1:";

        private static readonly RandomNumberGenerator Rng = RandomNumberGenerator.Create();
        private static readonly object RngGate = new object();
        private static readonly char[] Hex = "0123456789abcdef".ToCharArray();

        private readonly byte[] _key;
        private readonly Func<byte[]> _iv;

        /// <summary>Şifreleyici; <paramref name="key"/> 32 bayt olmalı.</summary>
        public AesGcmPayloadCipher(byte[] key)
            : this(key, null)
        {
        }

        internal AesGcmPayloadCipher(byte[] key, Func<byte[]> ivSource)
        {
            if (key == null || key.Length != 32)
            {
                throw new ArgumentException("AES-256 anahtarı 32 bayt olmalı", nameof(key));
            }
            _key = (byte[])key.Clone();
            _iv = ivSource ?? NewIv;
        }

        /// <inheritdoc />
        public string Encrypt(string plain, string aad)
        {
            var iv = _iv();
            var sealedData = ManagedAesGcm.Seal(_key, iv, Encoding.UTF8.GetBytes(plain), Encoding.UTF8.GetBytes(aad ?? ""));
            var all = new byte[iv.Length + sealedData.Length];
            Buffer.BlockCopy(iv, 0, all, 0, iv.Length);
            Buffer.BlockCopy(sealedData, 0, all, iv.Length, sealedData.Length);
            return Prefix + ToHex(all);
        }

        /// <inheritdoc />
        public string Decrypt(string stored, string aad)
        {
            try
            {
                if (stored == null || !stored.StartsWith(Prefix, StringComparison.Ordinal))
                {
                    return null;
                }
                var raw = FromHex(stored.Substring(Prefix.Length));
                if (raw == null || raw.Length <= ManagedAesGcm.IvBytes + ManagedAesGcm.TagBytes)
                {
                    return null;
                }
                var iv = new byte[ManagedAesGcm.IvBytes];
                Buffer.BlockCopy(raw, 0, iv, 0, iv.Length);
                var body = new byte[raw.Length - iv.Length];
                Buffer.BlockCopy(raw, iv.Length, body, 0, body.Length);
                var plain = ManagedAesGcm.Open(_key, iv, body, Encoding.UTF8.GetBytes(aad ?? ""));
                return plain == null ? null : new UTF8Encoding(false, true).GetString(plain);
            }
            catch (Exception ex) when (ex is CryptographicException || ex is ArgumentException || ex is FormatException)
            {
                return null;
            }
        }

        private static byte[] NewIv()
        {
            var iv = new byte[ManagedAesGcm.IvBytes];
            // Mono'da RandomNumberGenerator örneğinin iş parçacığı güvenliği garanti değildir.
            lock (RngGate)
            {
                Rng.GetBytes(iv);
            }
            return iv;
        }

        internal static string ToHex(byte[] bytes)
        {
            var chars = new char[bytes.Length * 2];
            for (var i = 0; i < bytes.Length; i++)
            {
                chars[i * 2] = Hex[bytes[i] >> 4];
                chars[(i * 2) + 1] = Hex[bytes[i] & 0xF];
            }
            return new string(chars);
        }

        internal static byte[] FromHex(string text)
        {
            if (text.Length % 2 != 0)
            {
                return null;
            }
            var bytes = new byte[text.Length / 2];
            for (var i = 0; i < bytes.Length; i++)
            {
                var hi = HexValue(text[i * 2]);
                var lo = HexValue(text[(i * 2) + 1]);
                if (hi < 0 || lo < 0)
                {
                    return null;
                }
                bytes[i] = (byte)((hi << 4) | lo);
            }
            return bytes;
        }

        private static int HexValue(char c)
        {
            if (c >= '0' && c <= '9')
            {
                return c - '0';
            }
            if (c >= 'a' && c <= 'f')
            {
                return c - 'a' + 10;
            }
            if (c >= 'A' && c <= 'F')
            {
                return c - 'A' + 10;
            }
            return -1;
        }
    }

    /// <summary>
    /// Olay gövdelerini şifreleyen sarmalayıcı. Açılamayan satır (anahtar kaybı, bozulma, düz metin) kuyruktan atılır: gönderilemeyecek
    /// şifreli veri sonsuza dek birikmez. İşaretler olay gövdesi değildir ve olduğu gibi kalır.
    /// </summary>
    public sealed class EncryptedEventStore : IEventStore
    {
        private readonly IEventStore _inner;
        private readonly IPayloadCipher _cipher;

        /// <summary>Sarmalayıcı.</summary>
        public EncryptedEventStore(IEventStore inner, IPayloadCipher cipher)
        {
            _inner = inner ?? throw new ArgumentNullException(nameof(inner));
            _cipher = cipher ?? throw new ArgumentNullException(nameof(cipher));
        }

        /// <inheritdoc />
        public IReadOnlyList<StoredEvent> Load()
        {
            var result = new List<StoredEvent>();
            var broken = new List<string>();
            foreach (var row in _inner.Load())
            {
                var plain = _cipher.Decrypt(row.Payload, row.Id);
                if (plain == null)
                {
                    broken.Add(row.Id);
                }
                else
                {
                    result.Add(new StoredEvent(row.Id, plain));
                }
            }
            if (broken.Count > 0)
            {
                _inner.Remove(broken);
            }
            return result;
        }

        /// <inheritdoc />
        public void Add(StoredEvent storedEvent) => _inner.Add(new StoredEvent(storedEvent.Id, _cipher.Encrypt(storedEvent.Payload, storedEvent.Id)));

        /// <inheritdoc />
        public void Remove(IReadOnlyCollection<string> eventIds) => _inner.Remove(eventIds);

        /// <inheritdoc />
        public void Clear() => _inner.Clear();

        /// <inheritdoc />
        public string GetMarker(string key) => _inner.GetMarker(key);

        /// <inheritdoc />
        public void PutMarker(string key, string value) => _inner.PutMarker(key, value);

        /// <inheritdoc />
        public void RemoveMarker(string key) => _inner.RemoveMarker(key);
    }

    /// <summary>
    /// Dosya tabanlı kuyruk: <c>events.log</c> her satırda <c>kimlik TAB gövde</c>, <c>markers.log</c> her satırda <c>anahtar TAB değer</c>.
    /// Ekleme yalnızca dosya sonuna yazar; silme dosyayı geçici dosya üzerinden yeniden yazar. Yarım kalmış son satır (süreç ölümü)
    /// sonraki ekleme tarafından bozulmasın diye satır sonu tamamlanır; geçersiz satır yok sayılır. G/Ç hatası oyuna yansımaz:
    /// <see cref="Failures"/> artar, <paramref name="onError"/> çağrılır.
    /// </summary>
    public sealed class FileEventStore : IEventStore
    {
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

        private readonly object _gate = new object();
        private readonly string _eventsPath;
        private readonly string _markersPath;
        private readonly Action<string> _onError;
        private bool _tailChecked;

        /// <summary>Dizin yoksa oluşturulur.</summary>
        public FileEventStore(string directory, Action<string> onError = null)
        {
            if (string.IsNullOrWhiteSpace(directory))
            {
                throw new ArgumentException("dizin boş olamaz", nameof(directory));
            }
            _eventsPath = Path.Combine(directory, "events.log");
            _markersPath = Path.Combine(directory, "markers.log");
            _onError = onError;
            Guarded(() => Directory.CreateDirectory(directory));
        }

        /// <summary>Başarısız G/Ç işlemi sayısı.</summary>
        public int Failures { get; private set; }

        /// <inheritdoc />
        public IReadOnlyList<StoredEvent> Load()
        {
            lock (_gate)
            {
                var list = new List<StoredEvent>();
                var seen = new HashSet<string>(StringComparer.Ordinal);
                foreach (var line in ReadLines(_eventsPath))
                {
                    var tab = line.IndexOf('\t');
                    if (tab != 26 || line.Length <= 27)
                    {
                        continue;
                    }
                    var id = line.Substring(0, tab);
                    if (seen.Add(id))
                    {
                        list.Add(new StoredEvent(id, line.Substring(tab + 1)));
                    }
                }
                return list;
            }
        }

        /// <inheritdoc />
        public void Add(StoredEvent storedEvent)
        {
            if (storedEvent == null || storedEvent.Id == null || storedEvent.Id.Length != 26 || storedEvent.Payload.IndexOfAny(new[] { '\n', '\r' }) >= 0)
            {
                return;
            }
            lock (_gate)
            {
                Guarded(() =>
                {
                    EnsureTailLocked();
                    File.AppendAllText(_eventsPath, storedEvent.Id + "\t" + storedEvent.Payload + "\n", Utf8);
                });
            }
        }

        /// <inheritdoc />
        public void Remove(IReadOnlyCollection<string> eventIds)
        {
            if (eventIds == null || eventIds.Count == 0)
            {
                return;
            }
            var drop = new HashSet<string>(eventIds, StringComparer.Ordinal);
            lock (_gate)
            {
                Guarded(() =>
                {
                    if (!File.Exists(_eventsPath))
                    {
                        return;
                    }
                    var keep = new List<string>();
                    foreach (var line in ReadLines(_eventsPath))
                    {
                        var tab = line.IndexOf('\t');
                        if (tab == 26 && !drop.Contains(line.Substring(0, tab)))
                        {
                            keep.Add(line);
                        }
                    }
                    Rewrite(_eventsPath, keep);
                    _tailChecked = true;
                });
            }
        }

        /// <inheritdoc />
        public void Clear()
        {
            lock (_gate)
            {
                Guarded(() =>
                {
                    if (File.Exists(_eventsPath))
                    {
                        File.Delete(_eventsPath);
                    }
                    _tailChecked = true;
                });
            }
        }

        /// <inheritdoc />
        public string GetMarker(string key)
        {
            lock (_gate)
            {
                string value = null;
                foreach (var pair in ReadMarkersLocked())
                {
                    if (pair.Key == key)
                    {
                        value = pair.Value;
                    }
                }
                return value;
            }
        }

        /// <inheritdoc />
        public void PutMarker(string key, string value)
        {
            if (!ValidMarker(key, value))
            {
                return;
            }
            lock (_gate)
            {
                var map = ReadMarkersLocked();
                map[key] = value;
                WriteMarkersLocked(map);
            }
        }

        /// <inheritdoc />
        public void RemoveMarker(string key)
        {
            lock (_gate)
            {
                var map = ReadMarkersLocked();
                if (map.Remove(key))
                {
                    WriteMarkersLocked(map);
                }
            }
        }

        private static bool ValidMarker(string key, string value) =>
            !string.IsNullOrEmpty(key) && value != null && key.IndexOfAny(new[] { '\t', '\n', '\r' }) < 0 && value.IndexOfAny(new[] { '\n', '\r' }) < 0;

        private Dictionary<string, string> ReadMarkersLocked()
        {
            var map = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var line in ReadLines(_markersPath))
            {
                var tab = line.IndexOf('\t');
                if (tab > 0)
                {
                    map[line.Substring(0, tab)] = line.Substring(tab + 1);
                }
            }
            return map;
        }

        private void WriteMarkersLocked(Dictionary<string, string> map)
        {
            var lines = new List<string>(map.Count);
            foreach (var pair in map)
            {
                lines.Add(pair.Key + "\t" + pair.Value);
            }
            Guarded(() => Rewrite(_markersPath, lines));
        }

        // Dosyanın son baytı satır sonu değilse (yarım yazma) tamamlanır; sonraki geçerli olay bozuk satıra yapışmaz.
        private void EnsureTailLocked()
        {
            if (_tailChecked)
            {
                return;
            }
            _tailChecked = true;
            if (!File.Exists(_eventsPath))
            {
                return;
            }
            using (var stream = new FileStream(_eventsPath, FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
            {
                if (stream.Length == 0)
                {
                    return;
                }
                stream.Seek(-1, SeekOrigin.End);
                if (stream.ReadByte() != '\n')
                {
                    stream.Seek(0, SeekOrigin.End);
                    stream.WriteByte((byte)'\n');
                }
            }
        }

        private IEnumerable<string> ReadLines(string path)
        {
            string[] lines = null;
            Guarded(() =>
            {
                if (File.Exists(path))
                {
                    lines = File.ReadAllText(path, Utf8).Split('\n');
                }
            });
            if (lines == null)
            {
                yield break;
            }
            foreach (var line in lines)
            {
                var trimmed = line.TrimEnd('\r');
                if (trimmed.Length > 0)
                {
                    yield return trimmed;
                }
            }
        }

        private static void Rewrite(string path, List<string> lines)
        {
            if (lines.Count == 0)
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
                return;
            }
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, string.Join("\n", lines) + "\n", Utf8);
            // File.Replace platformlar arasında tutarsızdır; kopyalayıp silmek Mono, IL2CPP ve .NET'te aynı davranır.
            File.Copy(temporary, path, true);
            File.Delete(temporary);
        }

        private void Guarded(Action action)
        {
            try
            {
                action();
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException || ex is System.Security.SecurityException || ex is NotSupportedException)
            {
                Failures++;
                try
                {
                    _onError?.Invoke("kalıcı kuyruk G/Ç hatası: " + ex.GetType().Name);
                }
                catch (Exception)
                {
                    // Günlük hatası SDK akışını kesmez.
                }
            }
        }
    }

    /// <summary>Kuyruk şifreleme anahtarını sağlar. Gerçek koruma düzeyi <see cref="Protection"/> ile açıkça bildirilir.</summary>
    public interface IQueueKeyProvider
    {
        /// <summary>Koruma düzeyi: <c>android_keystore</c>, <c>ios_keychain</c>, <c>windows_dpapi</c> ya da <c>local_file</c> (yalnız dosya izni).</summary>
        string Protection { get; }
        /// <summary>32 baytlık anahtarı döndürür; yoksa üretir. Alınamazsa <c>null</c> (kuyruk bellekte kalır, düz metne düşmez).</summary>
        byte[] GetOrCreateKey();
        /// <summary>Anahtarı siler; eski şifreli satırlar bir daha açılmaz.</summary>
        void DeleteKey();
    }

    /// <summary>Rastgele veri anahtarını bir platform sarmalayıcısıyla (Keystore, DPAPI) korur.</summary>
    public interface IKeyProtector
    {
        /// <summary>Koruma düzeyi adı.</summary>
        string Protection { get; }
        /// <summary>Anahtar baytlarını sarar; başarısızsa <c>null</c>.</summary>
        byte[] Protect(byte[] data);
        /// <summary>Sarılmış baytları açar; başarısızsa <c>null</c>.</summary>
        byte[] Unprotect(byte[] data);
    }

    /// <summary>
    /// Veri anahtarı dosyada yalnızca <see cref="IKeyProtector"/> ile sarılmış hâlde durur. Sarmalayıcı donanım/OS tabanlıysa (Keystore, DPAPI)
    /// dosya tek başına işe yaramaz. <see cref="PlainKeyProtector"/> verilirse koruma yalnız dosya iznidir ve bu açıkça
    /// <c>local_file</c> olarak bildirilir.
    /// </summary>
    public sealed class WrappedFileKeyProvider : IQueueKeyProvider
    {
        private static readonly RandomNumberGenerator Rng = RandomNumberGenerator.Create();
        private static readonly object RngGate = new object();

        private readonly string _path;
        private readonly IKeyProtector _protector;
        private readonly Action<string> _onError;
        private byte[] _cached;

        /// <summary>Anahtar dosyası <paramref name="directory"/> içinde <c>queue.key</c> adıyla tutulur.</summary>
        public WrappedFileKeyProvider(string directory, IKeyProtector protector, Action<string> onError = null)
        {
            _path = Path.Combine(directory, "queue.key");
            _protector = protector ?? throw new ArgumentNullException(nameof(protector));
            _onError = onError;
        }

        /// <inheritdoc />
        public string Protection => _protector.Protection;

        /// <inheritdoc />
        public byte[] GetOrCreateKey()
        {
            if (_cached != null)
            {
                return (byte[])_cached.Clone();
            }
            try
            {
                if (File.Exists(_path))
                {
                    var wrapped = File.ReadAllBytes(_path);
                    var key = _protector.Unprotect(wrapped);
                    if (key != null && key.Length == 32)
                    {
                        _cached = key;
                        return (byte[])key.Clone();
                    }
                    // Sarmalayıcı anahtarı açamıyor (cihaz değişti, Keystore sıfırlandı): eski satırlar zaten okunamaz, yeni anahtar üretilir.
                    _onError?.Invoke("kuyruk anahtarı açılamadı, yenisi üretiliyor");
                }
                var fresh = new byte[32];
                lock (RngGate)
                {
                    Rng.GetBytes(fresh);
                }
                var protectedKey = _protector.Protect(fresh);
                if (protectedKey == null)
                {
                    return null;
                }
                Directory.CreateDirectory(Path.GetDirectoryName(_path));
                File.WriteAllBytes(_path, protectedKey);
                _cached = fresh;
                return (byte[])fresh.Clone();
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException || ex is System.Security.SecurityException || ex is NotSupportedException)
            {
                _onError?.Invoke("kuyruk anahtarı dosyasına erişilemedi: " + ex.GetType().Name);
                return null;
            }
        }

        /// <inheritdoc />
        public void DeleteKey()
        {
            _cached = null;
            try
            {
                if (File.Exists(_path))
                {
                    File.Delete(_path);
                }
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
            {
                _onError?.Invoke("kuyruk anahtarı silinemedi: " + ex.GetType().Name);
            }
        }
    }

    /// <summary>Sarmalama yapmaz: anahtar dosyada düz durur. Yalnız başka seçenek olmayan platformlar için; koruma düzeyi <c>local_file</c>.</summary>
    public sealed class PlainKeyProtector : IKeyProtector
    {
        /// <inheritdoc />
        public string Protection => "local_file";

        /// <inheritdoc />
        public byte[] Protect(byte[] data) => (byte[])data.Clone();

        /// <inheritdoc />
        public byte[] Unprotect(byte[] data) => (byte[])data.Clone();
    }
}
