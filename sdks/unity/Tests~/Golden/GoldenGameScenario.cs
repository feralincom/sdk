using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace Feralin.Unity.Golden
{
    /// <summary>
    /// QA-F altın senaryosu (Unity oyunu): gerçek Unity oynatıcısında UnityWebRequest ile gerçek toplayıcıya seviye, ekonomi ve ödüllü
    /// reklam olayları gönderilir. scripts/sdk-e2e/unity-golden.mjs bu testi geçici bir Unity projesinin Assets/ dizinine kopyalar,
    /// sonra aynı olayların ClickHouse'tan funnel ve D7 retention uçlarını doldurduğunu saas-api üzerinden doğrular.
    ///
    /// Oyuncular sentetiktir ve sayıları k-eşiği (10) gizlemesine takılmayacak biçimdedir: 20 oyuncu kohort günü oynar, 10'u ödüllü
    /// reklam izler, 10'u yedinci gün geri döner (dönen ve dönmeyen grup ikisi de en az 10 olduğundan retention hücresi ölçülür).
    /// Olay zamanı SDK'nın saat kancasıyla (FeralinOptions.Clock) geçmişe alınır; toplayıcı 90 güne kadar geçmişi kabul eder.
    /// Ekonomi olayları istemci beyanıdır; sunucu tarafı onayı (server-authoritative) yoktur ve bu test öyle bir iddia taşımaz.
    /// </summary>
    public class GoldenGameScenario
    {
        public const int Players = 20;
        public const int ReturningPlayers = 10;
        public const int RewardedPlayers = 10;

        private static string Env(string name)
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (string.IsNullOrEmpty(value))
            {
                Assert.Fail(name + " tanımsız");
            }
            return value;
        }

        private static IEnumerator Wait(Func<bool> done, float seconds = 30f)
        {
            var end = Time.realtimeSinceStartup + seconds;
            while (!done() && Time.realtimeSinceStartup < end)
            {
                yield return null;
            }
            Assert.IsTrue(done(), "zaman aşımı");
        }

        [UnityTest]
        public IEnumerator GameEventsReachRealCollector()
        {
            var url = Env("FERALIN_E2E_COLLECT_URL");
            var key = Env("FERALIN_E2E_PROJECT_KEY");
            var checks = Env("FERALIN_E2E_CHECKS");
            var cohortDay = DateTimeOffset.ParseExact(Env("FERALIN_GOLDEN_COHORT_DAY"), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
            var runId = Env("FERALIN_GOLDEN_RUN_ID");

            var now = cohortDay.AddHours(10);
            var clients = new List<FeralinClient>();
            var lines = new List<string>();
            void Remember(TrackedEvent tracked, string name)
            {
                Assert.IsNotNull(tracked, name + " üretilmedi");
                Assert.AreEqual(name, tracked.EventName);
                lines.Add("once " + tracked.EventId);
                lines.Add("platform unity:" + tracked.EventId);
            }

            for (var i = 0; i < Players; i++)
            {
                var client = new FeralinClient(new FeralinOptions
                {
                    ProjectKey = key,
                    CollectUrl = url,
                    Transport = new UnityWebRequestTransport(),
                    Consent = new Consent(true),
                    FlushInterval = TimeSpan.Zero,
                    Clock = () => now,
                });
                client.SetAnonymousId("golden_" + runId + "_" + i.ToString(CultureInfo.InvariantCulture));
                clients.Add(client);
            }

            // Kohort günü: seviye başlar ve biter, ekonomi kazancı ve harcaması, ödüllü reklam (10 oyuncu).
            for (var i = 0; i < Players; i++)
            {
                var client = clients[i];
                now = cohortDay.AddHours(10).AddMinutes(i);
                Remember(client.TrackLevelStart("dunya_1", 1), "level_start");
                now = now.AddMinutes(3);
                Remember(client.TrackLevelComplete("dunya_1", 1, 1000 + i, 180000), "level_complete");
                now = now.AddSeconds(5);
                Remember(client.TrackEconomySource("gem", 50, "level_reward", "chest"), "economy_source");
                now = now.AddSeconds(5);
                Remember(client.TrackEconomySink("gem", 20, "shop", "sword"), "economy_sink");
                if (i < RewardedPlayers)
                {
                    now = now.AddSeconds(30);
                    Remember(client.TrackRewardedAdShown("revive", "admob"), "rewarded_ad_shown");
                    now = now.AddSeconds(30);
                    Remember(client.TrackRewardedAdComplete("revive", "admob", 1, "life"), "rewarded_ad_complete");
                }
            }

            // Yedinci gün: 10 oyuncu geri döner.
            for (var i = 0; i < ReturningPlayers; i++)
            {
                now = cohortDay.AddDays(7).AddHours(10).AddMinutes(i);
                Remember(clients[i].TrackLevelStart("dunya_2", 1), "level_start");
            }

            var results = new FlushResult[Players];
            for (var i = 0; i < Players; i++)
            {
                var index = i;
                clients[i].Flush(r => results[index] = r);
            }
            yield return Wait(() => Array.TrueForAll(results, r => r != null));
            var accepted = 0;
            foreach (var result in results)
            {
                Assert.AreEqual(202, result.Status, "toplayıcı 202 vermeliydi");
                Assert.AreEqual(0, result.Retained, "kuyruk boşalmalıydı");
                accepted += result.Accepted;
            }
            Assert.AreEqual(lines.Count / 2, accepted, "bütün olaylar kabul edilmeliydi");
            File.AppendAllText(checks, string.Join("\n", lines) + "\n");
            Debug.Log("feralin golden: " + accepted + " olay kabul edildi");
        }
    }
}
