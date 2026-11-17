using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace Feralin.Unity.Tests
{
    /// <summary>
    /// Gerçek Unity oynatıcısında UnityWebRequest ve MonoBehaviour yolunu sınar. Yerel HttpListener toplayıcı yerine geçer; ortamda
    /// FERALIN_E2E_COLLECT_URL verilmişse aynı akış gerçek toplayıcıya da gider.
    /// </summary>
    public class UnityTransportPlayTests
    {
        private const string Key = "pk_test_unity_play_0001";
        private const string AnonymousIdKey = "feralin.anonymous_id";

        private sealed class LocalCollector : IDisposable
        {
            private readonly HttpListener _listener = new HttpListener();
            private readonly Thread _thread;
            public readonly List<(string Key, string Idempotency, string Body, string ContentType)> Requests = new List<(string, string, string, string)>();
            public volatile int NextStatus = 202;
            public volatile int NextBodyBytes;
            public string Url { get; }

            public LocalCollector()
            {
                var port = 47150 + UnityEngine.Random.Range(0, 400);
                Url = "http://127.0.0.1:" + port;
                _listener.Prefixes.Add(Url + "/");
                _listener.Start();
                _thread = new Thread(Serve) { IsBackground = true };
                _thread.Start();
            }

            private void Serve()
            {
                try
                {
                    while (_listener.IsListening)
                    {
                        var context = _listener.GetContext();
                        using (var reader = new StreamReader(context.Request.InputStream, Encoding.UTF8))
                        {
                            var body = reader.ReadToEnd();
                            lock (Requests)
                            {
                                Requests.Add((context.Request.Headers["X-Feralin-Project-Key"], context.Request.Headers["Idempotency-Key"], body, context.Request.ContentType));
                            }
                        }
                        context.Response.StatusCode = NextStatus;
                        if (NextStatus == 429)
                        {
                            context.Response.Headers["Retry-After"] = "120";
                        }
                        var ack = NextBodyBytes > 0 ? new byte[NextBodyBytes] : Encoding.UTF8.GetBytes("{\"batch_id\":\"batch_play\",\"accepted\":1,\"rejected\":0}");
                        context.Response.ContentLength64 = ack.Length;
                        try
                        {
                            context.Response.OutputStream.Write(ack, 0, ack.Length);
                            context.Response.Close();
                        }
                        catch (IOException)
                        {
                            // İstemci sınırı aşan indirmeyi kesti; sonraki istek için dinleme sürer.
                            context.Response.Abort();
                        }
                    }
                }
                catch (Exception ex) when (ex is HttpListenerException || ex is ObjectDisposedException || ex is InvalidOperationException)
                {
                    // Dinleyici kapatıldı.
                }
            }

            public int Count
            {
                get
                {
                    lock (Requests)
                    {
                        return Requests.Count;
                    }
                }
            }

            public void Dispose()
            {
                _listener.Close();
            }
        }

        private static string QueueDirectory => Path.Combine(Application.persistentDataPath, "feralin");

        private static void CleanQueueDirectory()
        {
            try
            {
                if (Directory.Exists(QueueDirectory))
                {
                    Directory.Delete(QueueDirectory, true);
                }
            }
            catch (IOException)
            {
                // Başka bir test hâlâ yazıyor olabilir; sonraki SetUp yeniden dener.
            }
        }

        [SetUp]
        public void CleanPrefs()
        {
            PlayerPrefs.DeleteKey(AnonymousIdKey);
            CleanQueueDirectory();
        }

        [TearDown]
        public void Destroy()
        {
            if (FeralinBehaviour.Instance != null)
            {
                UnityEngine.Object.DestroyImmediate(FeralinBehaviour.Instance.gameObject);
            }
            PlayerPrefs.DeleteKey(AnonymousIdKey);
            CleanQueueDirectory();
        }

        private static IEnumerator Wait(Func<bool> done, float seconds = 10f)
        {
            var end = Time.realtimeSinceStartup + seconds;
            while (!done() && Time.realtimeSinceStartup < end)
            {
                yield return null;
            }
            Assert.IsTrue(done(), "zaman aşımı");
        }

        [UnityTest]
        public IEnumerator TransportSendsHeadersAndBodyAndParsesAck()
        {
            using (var collector = new LocalCollector())
            {
                var client = new FeralinClient(new FeralinOptions { ProjectKey = Key, CollectUrl = collector.Url, Transport = new UnityWebRequestTransport(), Consent = new Consent(true), FlushInterval = TimeSpan.Zero });
                var tracked = client.TrackLevelStart("w1");
                FlushResult result = null;
                client.Flush(r => result = r);
                yield return Wait(() => result != null);

                Assert.AreEqual(202, result.Status);
                Assert.AreEqual("batch_play", result.BatchId);
                Assert.AreEqual(0, result.Retained);
                Assert.AreEqual(1, collector.Count);
                var request = collector.Requests[0];
                Assert.AreEqual(Key, request.Key);
                Assert.AreEqual(Idempotency.KeyFor(new[] { tracked.EventId }), request.Idempotency);
                StringAssert.StartsWith("application/json", request.ContentType);
                StringAssert.Contains("\"platform\":\"unity\"", request.Body);
                StringAssert.Contains(tracked.EventId, request.Body);
            }
        }

        [UnityTest]
        public IEnumerator UnreachableCollectorKeepsEvents()
        {
            var client = new FeralinClient(new FeralinOptions { ProjectKey = Key, CollectUrl = "http://127.0.0.1:9", Transport = new UnityWebRequestTransport(), Consent = new Consent(true), FlushInterval = TimeSpan.Zero, Timeout = TimeSpan.FromSeconds(3) });
            client.Track("level_start");
            FlushResult result = null;
            client.Flush(r => result = r);
            yield return Wait(() => result != null);
            Assert.AreEqual(0, result.Status);
            Assert.AreEqual(1, result.Retained);
        }

        [UnityTest]
        public IEnumerator HttpErrorsReachCoreAsStatusAndRetryAfter()
        {
            using (var collector = new LocalCollector())
            {
                collector.NextStatus = 429;
                var client = new FeralinClient(new FeralinOptions { ProjectKey = Key, CollectUrl = collector.Url, Transport = new UnityWebRequestTransport(), Consent = new Consent(true), FlushInterval = TimeSpan.Zero });
                client.Track("level_start");
                FlushResult first = null;
                client.Flush(r => first = r);
                yield return Wait(() => first != null);
                Assert.AreEqual(429, first.Status);
                Assert.AreEqual(1, first.Retained);
                Assert.Greater(client.GetStatus().Backoff.TotalSeconds, 100);

                collector.NextStatus = 401;
                FlushResult closed = null;
                client.Close(r => closed = r);
                yield return Wait(() => closed != null);
                Assert.AreEqual(401, closed.Status);
                Assert.AreEqual(0, closed.Retained);
                Assert.AreEqual(1, closed.Rejected);
            }
        }

        [UnityTest]
        public IEnumerator BehaviourTicksInUpdateAndManagesAnonymousIdByConsent()
        {
            using (var collector = new LocalCollector())
            {
                var behaviour = FeralinBehaviour.Initialize(Key, collector.Url);
                Assert.AreSame(behaviour, FeralinBehaviour.Instance);
                Assert.IsNotNull(behaviour.Client);
                Assert.IsNull(behaviour.Client.Track("level_start"), "izin yokken olay üretilmemeli");
                Assert.IsFalse(PlayerPrefs.HasKey(AnonymousIdKey), "izin yokken kimlik yazılmamalı");

                behaviour.SetConsent(new Consent(true));
                var anonymousId = PlayerPrefs.GetString(AnonymousIdKey);
                Assert.AreEqual(26, anonymousId.Length);
                behaviour.Client.Track("level_start");

                // Flush çağrılmadan Update üzerinden aralık dolunca gönderilmeli.
                yield return Wait(() => collector.Count == 1);
                StringAssert.Contains(anonymousId, collector.Requests[0].Body);

                behaviour.SetConsent(new Consent(false));
                Assert.IsFalse(PlayerPrefs.HasKey(AnonymousIdKey), "izin geri çekilince kimlik silinmeli");
            }
        }

        [UnityTest]
        public IEnumerator ClientResetRotatesAnonymousIdInPlayerPrefs()
        {
            using (var collector = new LocalCollector())
            {
                var behaviour = FeralinBehaviour.Initialize(Key, collector.Url, new Consent(true));
                var first = PlayerPrefs.GetString(AnonymousIdKey);
                Assert.AreEqual(26, first.Length);

                behaviour.Client.Reset();
                var second = PlayerPrefs.GetString(AnonymousIdKey);
                Assert.AreEqual(26, second.Length);
                Assert.AreNotEqual(first, second, "ortak cihazda iki hesap aynı kimlikle bağlanmamalı");

                behaviour.Client.Track("level_start");
                yield return Wait(() => collector.Count == 1);
                StringAssert.Contains(second, collector.Requests[0].Body);
                StringAssert.DoesNotContain(first, collector.Requests[0].Body);

                behaviour.Client.SetConsent(new Consent(false));
                Assert.IsFalse(PlayerPrefs.HasKey(AnonymousIdKey), "izin geri çekilince kimlik silinmeli");
                behaviour.Client.Reset();
                Assert.IsFalse(PlayerPrefs.HasKey(AnonymousIdKey), "izin yokken reset kimlik üretmemeli");
            }
        }

        [UnityTest]
        public IEnumerator OversizedResponseIsAbortedAndEventsAreKept()
        {
            using (var collector = new LocalCollector())
            {
                collector.NextBodyBytes = 5 * 1024 * 1024;
                var client = new FeralinClient(new FeralinOptions { ProjectKey = Key, CollectUrl = collector.Url, Transport = new UnityWebRequestTransport(), Consent = new Consent(true), FlushInterval = TimeSpan.Zero });
                client.Track("level_start");
                FlushResult first = null;
                client.Flush(r => first = r);
                yield return Wait(() => first != null);
                Assert.AreEqual(0, first.Status, "sınırı aşan yanıt sonucu bilinmeyen sayılmalı");
                Assert.AreEqual(1, first.Retained);

                collector.NextBodyBytes = 0;
                FlushResult second = null;
                client.Flush(r => second = r);
                yield return Wait(() => second != null);
                Assert.AreEqual(202, second.Status);
                Assert.AreEqual(0, second.Retained);
                Assert.AreEqual(collector.Requests[0].Idempotency, collector.Requests[1].Idempotency);
            }
        }

        [UnityTest]
        public IEnumerator BadConfigurationDoesNotCrash()
        {
            LogAssert.Expect(LogType.Error, new System.Text.RegularExpressions.Regex("gizli anahtar"));
            var behaviour = FeralinBehaviour.Initialize("sk_live_secret_000", "https://c.example.test");
            yield return null;
            Assert.IsNull(behaviour.Client);
        }

        [UnityTest]
        public IEnumerator PauseFlushesQueue()
        {
            using (var collector = new LocalCollector())
            {
                var behaviour = FeralinBehaviour.Initialize(Key, collector.Url, new Consent(true));
                behaviour.Client.Track("level_start");
                behaviour.SendMessage("OnApplicationPause", true);
                yield return Wait(() => collector.Count == 1);
            }
        }

        [UnityTest]
        public IEnumerator QueueIsEncryptedOnDiskAndSurvivesRestartWithSameEventId()
        {
            // Toplayıcı kapalı: olaylar diskte kalır.
            var down = FeralinBehaviour.Initialize(Key, "http://127.0.0.1:9", new Consent(true));
            var status = down.Client.GetStatus();
            Assert.IsTrue(status.Persistent, "kalıcı kuyruk açık olmalı");
            Assert.IsNotNull(status.QueueProtection);
            Assert.That(status.QueueProtection, Is.EqualTo("windows_dpapi").Or.EqualTo("local_file"), "Editor'de yalnız bu iki düzey beklenir");
            var tracked = down.Client.TrackRevenue(new RevenueInput { TransactionId = "txn_play_offline", AmountMinor = 1999, Currency = "USD" });
            Assert.IsNotNull(tracked);
            var log = File.ReadAllText(Path.Combine(QueueDirectory, "events.log"));
            StringAssert.DoesNotContain("txn_play_offline", log);
            StringAssert.DoesNotContain("feralin_purchase", log);
            StringAssert.Contains("enc1:", log);
            UnityEngine.Object.DestroyImmediate(down.gameObject);
            yield return null;

            using (var collector = new LocalCollector())
            {
                var restarted = FeralinBehaviour.Initialize(Key, collector.Url, new Consent(true));
                yield return Wait(() => collector.Count >= 1);
                string all;
                lock (collector.Requests)
                {
                    all = string.Join("\n", collector.Requests.ConvertAll(r => r.Body));
                }
                StringAssert.Contains(tracked.EventId, all);
                StringAssert.Contains("txn_play_offline", all);
                Assert.IsNotNull(restarted.Client);
            }
        }

        [UnityTest]
        public IEnumerator UndecidedConsentLeavesDiskQueueUntouched()
        {
            var first = FeralinBehaviour.Initialize(Key, "http://127.0.0.1:9", new Consent(true));
            first.Client.Track("level_start");
            UnityEngine.Object.DestroyImmediate(first.gameObject);
            yield return null;

            using (var collector = new LocalCollector())
            {
                var second = FeralinBehaviour.Initialize(Key, collector.Url);
                Assert.AreEqual(0, second.Client.GetStatus().Queued, "karar yokken kuyruk yüklenmemeli");
                yield return new WaitForSeconds(2.5f);
                Assert.AreEqual(0, collector.Count, "karar yokken hiçbir şey gönderilmemeli");
                Assert.IsTrue(File.Exists(Path.Combine(QueueDirectory, "events.log")), "disk kuyruğu silinmemeli");
                second.SetConsent(new Consent(true));
                yield return Wait(() => collector.Count >= 1);
            }
        }

        [UnityTest]
        public IEnumerator UnhandledExceptionLogBecomesScrubbedErrorEvent()
        {
            using (var collector = new LocalCollector())
            {
                var behaviour = FeralinBehaviour.Initialize(Key, collector.Url, new Consent(true));
                yield return Wait(() => collector.Count >= 1);
                var before = collector.Count;
                LogAssert.Expect(LogType.Exception, new Regex("InvalidOperationException"));
                Debug.LogException(new InvalidOperationException("oyuncu ali@example.com girdi 192.168.1.20"));
                behaviour.Client.Flush();
                yield return Wait(() => collector.Count > before);
                string body;
                lock (collector.Requests)
                {
                    body = collector.Requests[collector.Requests.Count - 1].Body;
                }
                StringAssert.Contains("\"event_name\":\"fr_error\"", body);
                StringAssert.Contains("InvalidOperationException", body);
                StringAssert.DoesNotContain("ali@example.com", body);
                StringAssert.DoesNotContain("192.168.1.20", body);
            }
        }

        [UnityTest]
        public IEnumerator FirstOpenIsCountedOncePerInstallAndSessionIsAutomatic()
        {
            using (var collector = new LocalCollector())
            {
                var behaviour = FeralinBehaviour.Initialize(Key, collector.Url, new Consent(true, true));
                behaviour.Client.Flush();
                yield return Wait(() => collector.Count >= 1);
                string body;
                lock (collector.Requests)
                {
                    body = collector.Requests[0].Body;
                }
                StringAssert.Contains("\"event_name\":\"app_first_open\"", body);
                StringAssert.Contains("\"attribution_source\":\"none\"", body);
                StringAssert.Contains("\"session_id\":\"", body);
                // Yanıt işlenip olay diskten silinmeden kapatmak yeniden gönderime yol açar (en az bir kez teslim); önce kuyruğun boşalmasını bekle.
                yield return Wait(() => behaviour.Client.GetStatus().Queued == 0);
                UnityEngine.Object.DestroyImmediate(behaviour.gameObject);
                yield return null;

                var second = FeralinBehaviour.Initialize(Key, collector.Url, new Consent(true, true));
                Assert.AreEqual(0, second.Client.GetStatus().Queued, "aynı kurulumda ikinci ilk açılış olmamalı");
            }
        }

        /// <summary>Yalnız ortamda gerçek toplayıcı adresi varsa koşar: gerçek UnityWebRequest → gerçek services/collect.</summary>
        [UnityTest]
        public IEnumerator RealCollectorReceipt()
        {
            var url = Environment.GetEnvironmentVariable("FERALIN_E2E_COLLECT_URL");
            var key = Environment.GetEnvironmentVariable("FERALIN_E2E_PROJECT_KEY");
            var checks = Environment.GetEnvironmentVariable("FERALIN_E2E_CHECKS");
            if (string.IsNullOrEmpty(url))
            {
                Assert.Ignore("FERALIN_E2E_COLLECT_URL yok");
            }
            var client = new FeralinClient(new FeralinOptions { ProjectKey = key, CollectUrl = url, Transport = new UnityWebRequestTransport(), Consent = new Consent(true, true), FlushInterval = TimeSpan.Zero });
            var tracked = client.TrackIapPurchase("gem_pack", 49.99m, "TRY", "txn_play_" + Guid.NewGuid().ToString("N").Substring(0, 10), new Dictionary<string, object> { ["fr_click"] = "clk_unity_play" });
            Assert.AreEqual("feralin_purchase", tracked.EventName);
            FlushResult result = null;
            client.Flush(r => result = r);
            yield return Wait(() => result != null);
            Assert.AreEqual(202, result.Status);
            Assert.AreEqual(1, result.Accepted);
            Assert.AreEqual(0, result.Retained);
            if (!string.IsNullOrEmpty(checks))
            {
                File.AppendAllText(checks, "frclick " + result.BatchId + "\nonce " + tracked.EventId + "\nplatform unity:" + tracked.EventId + "\n");
            }
        }
    }
}
