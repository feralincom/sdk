using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Feralin.Unity;
using Xunit;

namespace Feralin.Unity.Core.Tests;

/// <summary>NIST/McGrew vektörleri ve .NET AesGcm ile karşılaştırma: yönetilen GCM doğru ve birlikte çalışabilir olmalı.</summary>
public class AesGcmTests
{
    private static byte[] H(string hex) => Convert.FromHexString(hex);

    [Fact]
    public void McGrewTestCase2()
    {
        var sealedData = ManagedAesGcm.Seal(new byte[16], new byte[12], new byte[16], Array.Empty<byte>());
        Assert.Equal("0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf", Convert.ToHexString(sealedData).ToLowerInvariant());
    }

    [Fact]
    public void McGrewTestCase4WithAad()
    {
        var key = H("feffe9928665731c6d6a8f9467308308");
        var iv = H("cafebabefacedbaddecaf888");
        var aad = H("feedfacedeadbeeffeedfacedeadbeefabaddad2");
        var plain = H("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39");
        var expected = "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091" + "5bc94fbc3221a5db94fae95ae7121a47";
        var sealedData = ManagedAesGcm.Seal(key, iv, plain, aad);
        Assert.Equal(expected, Convert.ToHexString(sealedData).ToLowerInvariant());
        Assert.Equal(plain, ManagedAesGcm.Open(key, iv, sealedData, aad));
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(1, 0)]
    [InlineData(15, 3)]
    [InlineData(16, 16)]
    [InlineData(17, 20)]
    [InlineData(100, 1)]
    [InlineData(4096, 33)]
    public void MatchesDotNetAesGcmBothWays(int plainLength, int aadLength)
    {
        var key = RandomNumberGenerator.GetBytes(32);
        var iv = RandomNumberGenerator.GetBytes(12);
        var plain = RandomNumberGenerator.GetBytes(plainLength);
        var aad = RandomNumberGenerator.GetBytes(aadLength);

        var ours = ManagedAesGcm.Seal(key, iv, plain, aad);
        var cipher = new byte[plainLength];
        var tag = new byte[16];
        using (var reference = new AesGcm(key, 16))
        {
            reference.Encrypt(iv, plain, cipher, tag, aad);
            Assert.Equal(cipher.Concat(tag).ToArray(), ours);

            // Referansın ürettiği, bizim çözebildiğimiz biçim.
            var decrypted = ManagedAesGcm.Open(key, iv, cipher.Concat(tag).ToArray(), aad);
            Assert.Equal(plain, decrypted);
        }
    }

    [Fact]
    public void TamperedCiphertextTagOrAadIsRejectedWithoutThrowing()
    {
        var key = RandomNumberGenerator.GetBytes(32);
        var iv = RandomNumberGenerator.GetBytes(12);
        var sealedData = ManagedAesGcm.Seal(key, iv, Encoding.UTF8.GetBytes("gizli"), new byte[] { 1, 2, 3 });

        var flippedBody = (byte[])sealedData.Clone();
        flippedBody[0] ^= 1;
        var flippedTag = (byte[])sealedData.Clone();
        flippedTag[^1] ^= 1;

        Assert.Null(ManagedAesGcm.Open(key, iv, flippedBody, new byte[] { 1, 2, 3 }));
        Assert.Null(ManagedAesGcm.Open(key, iv, flippedTag, new byte[] { 1, 2, 3 }));
        Assert.Null(ManagedAesGcm.Open(key, iv, sealedData, new byte[] { 1, 2, 4 }));
        Assert.Null(ManagedAesGcm.Open(RandomNumberGenerator.GetBytes(32), iv, sealedData, new byte[] { 1, 2, 3 }));
        Assert.Null(ManagedAesGcm.Open(key, iv, new byte[5], null));
    }

    [Fact]
    public void PayloadCipherUsesAndroidLineFormatAndBindsEventId()
    {
        var cipher = new AesGcmPayloadCipher(RandomNumberGenerator.GetBytes(32));
        var stored = cipher.Encrypt("{\"event_name\":\"level_start\"}", "01JABCDEFGHJKMNPQRSTVWXYZ0");
        Assert.StartsWith("enc1:", stored);
        Assert.DoesNotContain("level_start", stored);
        Assert.Matches("^enc1:[0-9a-f]+$", stored);
        Assert.Equal("{\"event_name\":\"level_start\"}", cipher.Decrypt(stored, "01JABCDEFGHJKMNPQRSTVWXYZ0"));
        // Satır başka kimliğe taşınırsa açılmaz.
        Assert.Null(cipher.Decrypt(stored, "01JABCDEFGHJKMNPQRSTVWXYZ1"));
        Assert.Null(cipher.Decrypt(stored.Substring(0, stored.Length - 2), "01JABCDEFGHJKMNPQRSTVWXYZ0"));
        Assert.Null(cipher.Decrypt("düz metin", "x"));
        Assert.Null(cipher.Decrypt("enc1:zz", "x"));
    }

    [Fact]
    public void EveryEncryptionUsesFreshIv()
    {
        var cipher = new AesGcmPayloadCipher(RandomNumberGenerator.GetBytes(32));
        Assert.NotEqual(cipher.Encrypt("a", "id"), cipher.Encrypt("a", "id"));
    }

    [Fact]
    public void PayloadCipherNeedsAes256Key()
    {
        Assert.Throws<ArgumentException>(() => new AesGcmPayloadCipher(new byte[16]));
    }

    [Fact]
    public void AndroidKotlinCipherTextCanBeOpened()
    {
        // Android SDK (AesGcmPayloadCipher.kt) aynı biçimi üretir: bu satır .NET AesGcm ile aynı biçimde elle kurulur.
        var key = RandomNumberGenerator.GetBytes(32);
        var iv = RandomNumberGenerator.GetBytes(12);
        var plain = Encoding.UTF8.GetBytes("{\"a\":1}");
        var cipher = new byte[plain.Length];
        var tag = new byte[16];
        using (var reference = new AesGcm(key, 16))
        {
            reference.Encrypt(iv, plain, cipher, tag, Encoding.UTF8.GetBytes("EVENTID"));
        }
        var line = "enc1:" + Convert.ToHexString(iv.Concat(cipher).Concat(tag).ToArray()).ToLowerInvariant();
        Assert.Equal("{\"a\":1}", new AesGcmPayloadCipher(key).Decrypt(line, "EVENTID"));
    }
}

public class FileEventStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "feralin-unity-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try
        {
            Directory.Delete(_dir, true);
        }
        catch (IOException)
        {
        }
    }

    private static string Id(int n) => "01JTESTEVENT" + n.ToString("D14");

    [Fact]
    public void AddLoadRemoveClearKeepOrder()
    {
        var store = new FileEventStore(_dir);
        Assert.Empty(store.Load());
        for (var i = 1; i <= 4; i++)
        {
            store.Add(new StoredEvent(Id(i), "{\"n\":" + i + "}"));
        }
        Assert.Equal(new[] { Id(1), Id(2), Id(3), Id(4) }, store.Load().Select(e => e.Id));
        store.Remove(new[] { Id(2), Id(3) });
        Assert.Equal(new[] { Id(1), Id(4) }, new FileEventStore(_dir).Load().Select(e => e.Id));
        store.Clear();
        Assert.Empty(new FileEventStore(_dir).Load());
    }

    [Fact]
    public void PartialTailLineDoesNotCorruptNextEvent()
    {
        var store = new FileEventStore(_dir);
        store.Add(new StoredEvent(Id(1), "{\"a\":1}"));
        // Süreç yazarken öldü: son satır yarım ve satır sonu yok.
        File.AppendAllText(Path.Combine(_dir, "events.log"), Id(2) + "\t{\"yar");
        var restarted = new FileEventStore(_dir);
        restarted.Add(new StoredEvent(Id(3), "{\"c\":3}"));
        var loaded = restarted.Load();
        Assert.Equal(Id(1), loaded[0].Id);
        Assert.Equal("{\"c\":3}", loaded.Single(e => e.Id == Id(3)).Payload);
        Assert.DoesNotContain(loaded, e => e.Payload.Contains("c\":3}") && e.Id == Id(2));
    }

    [Fact]
    public void GarbageLinesAndDuplicatesAreIgnored()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(Path.Combine(_dir, "events.log"), "çöp satır\n\n" + Id(1) + "\t{\"a\":1}\n" + Id(1) + "\t{\"a\":2}\nkisa\tx\n");
        var loaded = new FileEventStore(_dir).Load();
        Assert.Single(loaded);
        Assert.Equal("{\"a\":1}", loaded[0].Payload);
    }

    [Fact]
    public void RejectsNewlinesAndBadIds()
    {
        var store = new FileEventStore(_dir);
        store.Add(new StoredEvent("kisa", "{}"));
        store.Add(new StoredEvent(Id(1), "iki\nsatır"));
        Assert.Empty(store.Load());
    }

    [Fact]
    public void MarkersPersistAndRemove()
    {
        var store = new FileEventStore(_dir);
        Assert.Null(store.GetMarker("a"));
        store.PutMarker("a", "1");
        store.PutMarker("b", "iki");
        store.PutMarker("a", "3");
        store.PutMarker("kötü\tanahtar", "x");
        var reopened = new FileEventStore(_dir);
        Assert.Equal("3", reopened.GetMarker("a"));
        Assert.Equal("iki", reopened.GetMarker("b"));
        Assert.Null(reopened.GetMarker("kötü\tanahtar"));
        reopened.RemoveMarker("a");
        Assert.Null(new FileEventStore(_dir).GetMarker("a"));
        // Olay silmek işaretlere dokunmaz.
        reopened.Clear();
        Assert.Equal("iki", reopened.GetMarker("b"));
    }

    [Fact]
    public void IoFailureNeverThrowsAndIsReported()
    {
        var errors = new List<string>();
        Directory.CreateDirectory(_dir);
        // Dizin yerine aynı adda dosya: yazma hata verir.
        var blocked = Path.Combine(_dir, "engel");
        File.WriteAllText(blocked, "x");
        var store = new FileEventStore(blocked, errors.Add);
        store.Add(new StoredEvent(Id(1), "{}"));
        store.PutMarker("a", "b");
        Assert.Empty(store.Load());
        Assert.True(store.Failures > 0);
        Assert.NotEmpty(errors);
        Assert.All(errors, e => Assert.DoesNotContain(blocked, e));
    }
}

public class EncryptedEventStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "feralin-unity-enc-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try
        {
            Directory.Delete(_dir, true);
        }
        catch (IOException)
        {
        }
    }

    [Fact]
    public void DiskNeverContainsPlaintextAndWrongKeyRowsAreDropped()
    {
        var key = RandomNumberGenerator.GetBytes(32);
        var store = new EncryptedEventStore(new FileEventStore(_dir), new AesGcmPayloadCipher(key));
        store.Add(new StoredEvent("01JTESTEVENT00000000000001", "{\"event_name\":\"level_start\",\"user_id\":\"oyuncu_42\"}"));
        var raw = File.ReadAllText(Path.Combine(_dir, "events.log"));
        Assert.DoesNotContain("level_start", raw);
        Assert.DoesNotContain("oyuncu_42", raw);
        Assert.Contains("enc1:", raw);

        Assert.Single(new EncryptedEventStore(new FileEventStore(_dir), new AesGcmPayloadCipher(key)).Load());

        // Anahtar kayboldu (Keystore sıfırlandı): okunamayan satırlar atılır, sonsuza dek birikmez.
        var other = new EncryptedEventStore(new FileEventStore(_dir), new AesGcmPayloadCipher(RandomNumberGenerator.GetBytes(32)));
        Assert.Empty(other.Load());
        Assert.Empty(new FileEventStore(_dir).Load());
    }

    [Fact]
    public void PlainTextRowsAreDroppedNotSent()
    {
        var inner = new FileEventStore(_dir);
        inner.Add(new StoredEvent("01JTESTEVENT00000000000001", "{\"event_name\":\"duz\"}"));
        var store = new EncryptedEventStore(inner, new AesGcmPayloadCipher(RandomNumberGenerator.GetBytes(32)));
        Assert.Empty(store.Load());
        Assert.Empty(inner.Load());
    }
}

public class KeyProviderTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "feralin-unity-key-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try
        {
            Directory.Delete(_dir, true);
        }
        catch (IOException)
        {
        }
    }

    private sealed class XorProtector : IKeyProtector
    {
        public bool Fail { get; set; }
        public string Protection => "test_wrap";
        public byte[] Protect(byte[] data) => Fail ? null : data.Select(b => (byte)(b ^ 0x5A)).ToArray();
        public byte[] Unprotect(byte[] data) => Fail ? null : data.Select(b => (byte)(b ^ 0x5A)).ToArray();
    }

    [Fact]
    public void KeyIsGeneratedOnceStoredWrappedAndStable()
    {
        var protector = new XorProtector();
        var provider = new WrappedFileKeyProvider(_dir, protector);
        var key = provider.GetOrCreateKey();
        Assert.Equal(32, key.Length);
        Assert.Equal("test_wrap", provider.Protection);
        Assert.NotEqual(key, File.ReadAllBytes(Path.Combine(_dir, "queue.key")));
        Assert.Equal(key, new WrappedFileKeyProvider(_dir, protector).GetOrCreateKey());
    }

    [Fact]
    public void UnwrapFailureGeneratesNewKeyInsteadOfPlaintext()
    {
        var protector = new XorProtector();
        var first = new WrappedFileKeyProvider(_dir, protector).GetOrCreateKey();
        protector.Fail = true;
        var logs = new List<string>();
        // Sarmalayıcı bozuk: ne eski anahtar ne yenisi alınabilir; kuyruk bellekte kalır (null), düz metne düşülmez.
        Assert.Null(new WrappedFileKeyProvider(_dir, protector, logs.Add).GetOrCreateKey());
        Assert.NotEmpty(logs);
        protector.Fail = false;
        Assert.Equal(first, new WrappedFileKeyProvider(_dir, protector).GetOrCreateKey());
    }

    [Fact]
    public void DeleteKeyMakesNextKeyDifferent()
    {
        var provider = new WrappedFileKeyProvider(_dir, new PlainKeyProtector());
        var first = provider.GetOrCreateKey();
        Assert.Equal("local_file", provider.Protection);
        provider.DeleteKey();
        Assert.False(File.Exists(Path.Combine(_dir, "queue.key")));
        Assert.NotEqual(first, provider.GetOrCreateKey());
    }
}

public class PersistentQueueClientTests : IDisposable
{
    private const string Key = "pk_test_unity_key_0001";
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "feralin-unity-queue-" + Guid.NewGuid().ToString("N"));
    private readonly byte[] _storeKey = RandomNumberGenerator.GetBytes(32);
    private DateTimeOffset _now = new(2026, 11, 3, 10, 0, 0, TimeSpan.Zero);
    private readonly List<string> _logs = new();

    public void Dispose()
    {
        try
        {
            Directory.Delete(_dir, true);
        }
        catch (IOException)
        {
        }
    }

    private IEventStore NewStore() => new EncryptedEventStore(new FileEventStore(_dir), new AesGcmPayloadCipher(_storeKey));

    private FeralinClient Make(FakeTransport transport, Consent consent = null, Action<FeralinOptions> edit = null)
    {
        var options = new FeralinOptions
        {
            ProjectKey = Key,
            CollectUrl = "https://collect.example.test/",
            Transport = transport,
            Consent = consent,
            Clock = () => _now,
            Random = () => 1.0,
            Store = NewStore(),
            QueueProtection = "test",
            Log = (_, message) => _logs.Add(message),
        };
        edit?.Invoke(options);
        return new FeralinClient(options);
    }

    private static string[] EventIds(TransportRequest request) =>
        JsonDocument.Parse(request.Body).RootElement.GetProperty("events").EnumerateArray().Select(e => e.GetProperty("event_id").GetString()).ToArray();

    private static FlushResult Flush(FeralinClient client)
    {
        FlushResult result = null;
        client.Flush(r => result = r);
        Assert.NotNull(result);
        return result;
    }

    [Fact]
    public void OfflineEventsSurviveRestartAndKeepEventIdWithoutDoubleCount()
    {
        var offline = new FakeTransport();
        offline.Responses.Enqueue(TransportResponse.NetworkError);
        var first = Make(offline, new Consent(true));
        var tracked = first.Track("level_start");
        var failed = Flush(first);
        Assert.Equal(1, failed.Retained);
        Assert.Equal(0, failed.Status);

        // Oyun kapandı; yeni süreç aynı diskten başlar.
        var online = new FakeTransport();
        var second = Make(online, new Consent(true));
        Assert.Equal(1, second.GetStatus().Queued);
        var delivered = Flush(second);
        Assert.Equal(1, delivered.Accepted);
        Assert.Equal(new[] { tracked.EventId }, EventIds(online.Requests[0]));

        // Kabul edilen olay diskten silindi: bir sonraki başlangıçta tekrar gönderilmez.
        var third = Make(new FakeTransport(), new Consent(true));
        Assert.Equal(0, third.GetStatus().Queued);
    }

    [Fact]
    public void EventsOnDiskAreEncryptedAndCarryNoKeyOrPlaintext()
    {
        var client = Make(new FakeTransport(), new Consent(true), o => o.Context = new EventContext { Locale = "tr-TR" });
        client.Track("level_start", new Dictionary<string, object> { ["level_id"] = "gizli_bolum_adi" });
        var raw = File.ReadAllText(Path.Combine(_dir, "events.log"));
        Assert.DoesNotContain("gizli_bolum_adi", raw);
        Assert.DoesNotContain("level_start", raw);
        Assert.DoesNotContain("tr-TR", raw);
        Assert.DoesNotContain(Key, raw);
        Assert.Equal("test", client.GetStatus().QueueProtection);
        Assert.True(client.GetStatus().Persistent);
    }

    [Fact]
    public void UndecidedConsentNeitherLoadsNorWipesDisk()
    {
        var seed = Make(new FakeTransport(), new Consent(true));
        seed.Track("level_start");

        // Oyun açıldı ama kullanıcı kararı henüz yok.
        var transport = new FakeTransport();
        var undecided = Make(transport);
        Assert.Equal(0, undecided.GetStatus().Queued);
        undecided.Tick();
        Assert.Empty(transport.Requests);
        Assert.Single(NewStore().Load());

        undecided.SetConsent(new Consent(true));
        Assert.Equal(1, undecided.GetStatus().Queued);
    }

    [Fact]
    public void ConsentWithdrawalWipesDisk()
    {
        var client = Make(new FakeTransport(), new Consent(true));
        client.Track("level_start");
        Assert.Single(NewStore().Load());
        client.SetConsent(Consent.None);
        Assert.Empty(NewStore().Load());
        Assert.Equal(0, client.GetStatus().Queued);

        // Sonraki başlangıçta açık ret de diski temizler.
        client.SetConsent(new Consent(true));
        client.Track("level_start");
        var next = Make(new FakeTransport(), Consent.None);
        Assert.Empty(NewStore().Load());
        Assert.Equal(0, next.GetStatus().Queued);
    }

    [Fact]
    public void ResetClearsDisk()
    {
        var client = Make(new FakeTransport(), new Consent(true));
        client.Track("level_start");
        client.Reset();
        Assert.Empty(NewStore().Load());
    }

    [Fact]
    public void QueueLimitDropsOldestOnDiskToo()
    {
        var transport = new FakeTransport();
        transport.Responses.Enqueue(TransportResponse.NetworkError);
        var client = Make(transport, new Consent(true), o => o.QueueLimit = 3);
        var ids = new List<string>();
        for (var i = 0; i < 5; i++)
        {
            ids.Add(client.Track("e" + i).EventId);
        }
        Assert.Equal(3, client.GetStatus().Queued);
        Assert.Equal(2, client.GetStatus().Dropped);
        Assert.Equal(ids.Skip(2), NewStore().Load().Select(e => e.Id));
    }

    [Fact]
    public void RestoredQueueIsTrimmedToLimitOldestFirst()
    {
        var seed = Make(new FakeTransport(), new Consent(true), o => o.QueueLimit = 10);
        var ids = new List<string>();
        for (var i = 0; i < 6; i++)
        {
            ids.Add(seed.Track("e" + i).EventId);
        }
        var small = Make(new FakeTransport(), new Consent(true), o => o.QueueLimit = 4);
        Assert.Equal(4, small.GetStatus().Queued);
        Assert.Equal(2, small.GetStatus().Dropped);
        Assert.Equal(ids.Skip(2), NewStore().Load().Select(e => e.Id));
    }

    [Fact]
    public void RestoredEventsComeBeforeNewOnesAndAreNotDuplicated()
    {
        var offline = new FakeTransport();
        offline.Responses.Enqueue(TransportResponse.NetworkError);
        var first = Make(offline, new Consent(true));
        var old = first.Track("eski");
        Flush(first);

        var transport = new FakeTransport();
        var second = Make(transport, new Consent(true));
        var fresh = second.Track("yeni");
        // Aynı karar yeniden verilirse kuyruk ikinci kez yüklenmez.
        second.SetConsent(new Consent(true));
        Flush(second);
        Assert.Equal(new[] { old.EventId, fresh.EventId }, EventIds(transport.Requests[0]));
    }

    // SDK-R09 (docs/sdk/upgrade-guide.md): 0.1.0 kuyruğu yalnız bellekteydi; `Store` verilmeyen istemci aynı davranıştır.
    [Fact]
    public void UpgradeFromMemoryOnlyBuildHasNothingToMigrateAndInventsNothing()
    {
        var offline = new FakeTransport();
        offline.Responses.Enqueue(TransportResponse.NetworkError);
        var v1 = Make(offline, new Consent(true), o => o.Store = null);
        v1.Track("level_start");
        Assert.Equal(1, Flush(v1).Retained);
        Assert.False(File.Exists(Path.Combine(_dir, "events.log")));

        // Güncelleme süreci bitirir: 0.1'in bellekteki olayı kaybolur (0.1 davranışı); 0.2 boş kuyrukla başlar, olay uydurmaz.
        var transport = new FakeTransport();
        var v2 = Make(transport, new Consent(true));
        Assert.Equal(0, v2.GetStatus().Queued);
        Flush(v2);
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public void RollbackToMemoryOnlyBuildKeepsDiskRowsAndReupgradeSendsEachOnce()
    {
        // 0.2 çevrimdışıyken iki olay diske şifreli yazar.
        var offline = new FakeTransport();
        offline.Responses.Enqueue(TransportResponse.NetworkError);
        var v2 = Make(offline, new Consent(true));
        var a = v2.Track("eski_a").EventId;
        var b = v2.Track("eski_b").EventId;
        Flush(v2);

        // 0.1'e dönülür: disk okunmaz ve silinmez; 0.1 yalnız kendi olayını gönderir.
        var transport = new FakeTransport();
        var v1 = Make(transport, new Consent(true), o => o.Store = null);
        var c = v1.Track("geri_donus").EventId;
        Flush(v1);
        Assert.Equal(new[] { c }, EventIds(transport.Requests[0]));
        Assert.Equal(new[] { a, b }, NewStore().Load().Select(e => e.Id));

        // Yeniden 0.2: diskteki olaylar aynı kimlikle bir kez gider, sonra kuyruk boştur.
        var reupgraded = Make(transport, new Consent(true));
        Flush(reupgraded);
        var all = transport.Requests.SelectMany(EventIds).ToList();
        Assert.Equal(new[] { c, a, b }, all);
        Assert.Equal(all.Count, all.Distinct().Count());
        Assert.Equal(0, Make(new FakeTransport(), new Consent(true)).GetStatus().Queued);
    }

    [Fact]
    public void RejectedBatchesAndRevokedKeysLeaveNoRowsBehind()
    {
        var transport = new FakeTransport();
        transport.Responses.Enqueue(new TransportResponse(400, "{\"title\":\"bad\"}"));
        var client = Make(transport, new Consent(true));
        client.Track("a");
        Assert.Equal(1, Flush(client).Rejected);
        Assert.Empty(NewStore().Load());

        var keyed = new FakeTransport();
        keyed.Responses.Enqueue(new TransportResponse(401, "{}"));
        var revoked = Make(keyed, new Consent(true));
        revoked.Track("a");
        revoked.Track("b");
        Flush(revoked);
        Assert.Empty(NewStore().Load());
    }

    [Fact]
    public void CorruptDiskNeverBreaksTheGame()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(Path.Combine(_dir, "events.log"), "bozuk\n01JTESTEVENT00000000000001\tenc1:00ff\n");
        var client = Make(new FakeTransport(), new Consent(true));
        Assert.Equal(0, client.GetStatus().Queued);
        Assert.NotNull(client.Track("level_start"));
    }

    private sealed class ThrowingStore : IEventStore
    {
        public IReadOnlyList<StoredEvent> Load() => throw new IOException("disk");
        public void Add(StoredEvent storedEvent) => throw new IOException("disk");
        public void Remove(IReadOnlyCollection<string> eventIds) => throw new IOException("disk");
        public void Clear() => throw new IOException("disk");
        public string GetMarker(string key) => throw new IOException("disk");
        public void PutMarker(string key, string value) => throw new IOException("disk");
        public void RemoveMarker(string key) => throw new IOException("disk");
    }

    [Fact]
    public void BrokenStoreKeepsQueueInMemory()
    {
        var transport = new FakeTransport();
        var client = Make(transport, new Consent(true), o => o.Store = new ThrowingStore());
        Assert.NotNull(client.Track("level_start"));
        Assert.Equal(1, Flush(client).Accepted);
        Assert.Contains(_logs, l => l.Contains("kalıcı kuyruk"));
    }

    [Fact]
    public void OversizedEventsAreDroppedWithAndroidLimit()
    {
        var client = Make(new FakeTransport(), new Consent(true));
        Assert.Null(client.Track("big", new Dictionary<string, object> { ["blob"] = new string('x', 257 * 1024) }));
        Assert.NotNull(client.Track("ok", new Dictionary<string, object> { ["blob"] = new string('x', 100 * 1024) }));
    }
}
