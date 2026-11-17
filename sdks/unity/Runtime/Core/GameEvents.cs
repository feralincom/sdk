using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Feralin.Unity
{
    /// <summary>
    /// Oyun olayları için ince yardımcılar. Hepsi <see cref="FeralinClient.Track"/> üstündedir; izin ve süzme kuralları aynıdır.
    /// </summary>
    public static class GameEvents
    {
        private static readonly Regex CurrencyPattern = new Regex("^[A-Z]{3}$", RegexOptions.CultureInvariant);

        private const long MaxNumber = (1L << 53) - 1;
        private const long MaxDurationMs = 86400000L;
        private const long MaxAmount = 1000000000000L;

        /// <summary><c>level_start</c> (zorunlu <c>level_id</c> 1-64; isteğe bağlı <c>attempt</c> ≥1). Sözleşme: <c>packages/schemas/utp/v1/game-events.md</c>.</summary>
        public static TrackedEvent TrackLevelStart(this FeralinClient client, string levelId, long? attempt = null, IEnumerable<KeyValuePair<string, object>> properties = null) =>
            TrackLevel(client, "level_start", levelId, attempt, null, null, null, properties);

        /// <summary><c>level_complete</c> (<c>attempt</c>, <c>score</c> ≥0, <c>duration_ms</c> 0-86 400 000 isteğe bağlı).</summary>
        public static TrackedEvent TrackLevelComplete(this FeralinClient client, string levelId, long? attempt = null, long? score = null, long? durationMs = null, IEnumerable<KeyValuePair<string, object>> properties = null) =>
            TrackLevel(client, "level_complete", levelId, attempt, score, durationMs, null, properties);

        /// <summary><c>level_fail</c> (<c>fail_reason</c> en çok 64 karakter).</summary>
        public static TrackedEvent TrackLevelFail(this FeralinClient client, string levelId, long? attempt = null, long? score = null, long? durationMs = null, string failReason = null, IEnumerable<KeyValuePair<string, object>> properties = null) =>
            TrackLevel(client, "level_fail", levelId, attempt, score, durationMs, failReason, properties);

        /// <summary>
        /// <c>economy_source</c>: oyuncuya sanal para ya da eşya girişi. <c>currency_name</c> oyun içi para birimidir (gerçek para değildir);
        /// gerçek gelir için <see cref="FeralinClient.TrackRevenue"/>. <c>amount</c> 1..10^12.
        /// </summary>
        public static TrackedEvent TrackEconomySource(this FeralinClient client, string currencyName, long amount, string reason = null, string itemId = null, IEnumerable<KeyValuePair<string, object>> properties = null) =>
            TrackEconomy(client, "economy_source", currencyName, amount, reason, itemId, properties);

        /// <summary><c>economy_sink</c>: oyuncunun sanal para ya da eşya harcaması.</summary>
        public static TrackedEvent TrackEconomySink(this FeralinClient client, string currencyName, long amount, string reason = null, string itemId = null, IEnumerable<KeyValuePair<string, object>> properties = null) =>
            TrackEconomy(client, "economy_sink", currencyName, amount, reason, itemId, properties);

        /// <summary><c>rewarded_ad_shown</c>: ödüllü reklam gösterildi (<c>placement</c> 1-64, isteğe bağlı <c>network</c>).</summary>
        public static TrackedEvent TrackRewardedAdShown(this FeralinClient client, string placement, string network = null, IEnumerable<KeyValuePair<string, object>> properties = null)
        {
            var props = Merge(properties);
            if (!Text(placement, 64) || !Put(props, "placement", placement) || !PutText(props, "network", network, 64))
            {
                return Reject(client, "rewarded_ad_shown");
            }
            return client.Track("rewarded_ad_shown", props);
        }

        /// <summary><c>rewarded_ad_complete</c> (<c>reward_amount</c> ≥0, <c>reward_currency</c> ≤64 isteğe bağlı). Gelir taşımaz.</summary>
        public static TrackedEvent TrackRewardedAdComplete(this FeralinClient client, string placement, string network = null, long? rewardAmount = null, string rewardCurrency = null, IEnumerable<KeyValuePair<string, object>> properties = null)
        {
            var props = Merge(properties);
            if (!Text(placement, 64) || !Put(props, "placement", placement) || !PutText(props, "network", network, 64)
                || !PutNumber(props, "reward_amount", rewardAmount, 0, MaxNumber) || !PutText(props, "reward_currency", rewardCurrency, 64))
            {
                return Reject(client, "rewarded_ad_complete");
            }
            return client.Track("rewarded_ad_complete", props);
        }

        /// <summary><c>iap_offer_shown</c>: satın alma teklifi gösterildi (gelir değildir).</summary>
        public static TrackedEvent TrackIapOfferShown(this FeralinClient client, string productId, string placement = null, IEnumerable<KeyValuePair<string, object>> properties = null)
        {
            var props = Merge(properties);
            if (!Text(productId, 128) || !Put(props, "product_id", productId) || !PutText(props, "placement", placement, 64))
            {
                return Reject(client, "iap_offer_shown");
            }
            return client.Track("iap_offer_shown", props);
        }

        /// <summary><c>iap_initiated</c>: satın alma başlatıldı; <c>transactionId</c> sonradan gelen <c>feralin_purchase</c> ile aynıysa huni bağlanır.</summary>
        public static TrackedEvent TrackIapInitiated(this FeralinClient client, string productId, string placement = null, string transactionId = null, IEnumerable<KeyValuePair<string, object>> properties = null)
        {
            var props = Merge(properties);
            if (!Text(productId, 128) || !Put(props, "product_id", productId) || !PutText(props, "placement", placement, 64) || !PutText(props, "transaction_id", transactionId, 128))
            {
                return Reject(client, "iap_initiated");
            }
            return client.Track("iap_initiated", props);
        }

        /// <summary>
        /// Eski <c>iap_purchase</c> yardımcısı (geriye uyumluluk): ondalık tutarı para biriminin küçük birimine çevirip ortak
        /// <c>feralin_purchase</c> sözleşmesiyle (<see cref="FeralinClient.TrackRevenue"/>) gönderir; ayrı bir <c>iap_purchase</c> olayı artık
        /// üretilmez. Sözleşme işlem kimliğini zorunlu kılar: <paramref name="transactionId"/> boşsa olay üretilmez. İstemci beyanıdır,
        /// <c>verified</c> gönderilmez.
        /// </summary>
        /// <param name="client">İstemci.</param>
        /// <param name="productId">Mağaza ürün kimliği.</param>
        /// <param name="price">Beyan edilen tutar (negatif olamaz).</param>
        /// <param name="currency">ISO 4217, üç büyük harf.</param>
        /// <param name="transactionId">Mağaza işlem kimliği (zorunlu); sunucu aynı işlemi ikinci kez saymaz.</param>
        /// <param name="properties">Ek özellikler.</param>
        public static TrackedEvent TrackIapPurchase(this FeralinClient client, string productId, decimal price, string currency, string transactionId = null, IEnumerable<KeyValuePair<string, object>> properties = null)
        {
            var minor = currency != null && CurrencyPattern.IsMatch(currency) ? CurrencyMinorUnits.ToMinor(price, currency) : null;
            if (string.IsNullOrEmpty(productId) || string.IsNullOrEmpty(transactionId) || !minor.HasValue)
            {
                client.Warn("iap_purchase: ürün, işlem kimliği, tutar veya para birimi geçersiz, olay üretilmedi");
                return null;
            }
            return client.TrackRevenue(new RevenueInput
            {
                TransactionId = transactionId,
                AmountMinor = minor.Value,
                Currency = currency,
                ProductId = productId,
                Properties = properties,
            });
        }

        private static TrackedEvent TrackLevel(FeralinClient client, string eventName, string levelId, long? attempt, long? score, long? durationMs, string failReason, IEnumerable<KeyValuePair<string, object>> properties)
        {
            var props = Merge(properties);
            if (!Text(levelId, 64) || !Put(props, "level_id", levelId) || !PutNumber(props, "attempt", attempt, 1, MaxNumber) || !PutNumber(props, "score", score, 0, MaxNumber)
                || !PutNumber(props, "duration_ms", durationMs, 0, MaxDurationMs) || !PutText(props, "fail_reason", failReason, 64))
            {
                return Reject(client, eventName);
            }
            return client.Track(eventName, props);
        }

        private static TrackedEvent TrackEconomy(FeralinClient client, string eventName, string currencyName, long amount, string reason, string itemId, IEnumerable<KeyValuePair<string, object>> properties)
        {
            var props = Merge(properties);
            if (!Text(currencyName, 64) || amount < 1 || amount > MaxAmount || !Put(props, "currency_name", currencyName) || !Put(props, "amount", amount)
                || !PutText(props, "reason", reason, 64) || !PutText(props, "item_id", itemId, 64))
            {
                return Reject(client, eventName);
            }
            return client.Track(eventName, props);
        }

        private static TrackedEvent Reject(FeralinClient client, string eventName)
        {
            client.Warn(eventName + ": girdi sözleşmeye uymuyor, olay üretilmedi");
            return null;
        }

        private static bool Text(string value, int max) => !string.IsNullOrEmpty(value) && value.Length <= max;

        private static bool Put(Dictionary<string, object> props, string key, object value)
        {
            props[key] = value;
            return true;
        }

        private static bool PutText(Dictionary<string, object> props, string key, string value, int max)
        {
            if (value == null)
            {
                return true;
            }
            if (!Text(value, max))
            {
                return false;
            }
            props[key] = value;
            return true;
        }

        private static bool PutNumber(Dictionary<string, object> props, string key, long? value, long min, long max)
        {
            if (!value.HasValue)
            {
                return true;
            }
            if (value.Value < min || value.Value > max)
            {
                return false;
            }
            props[key] = value.Value;
            return true;
        }

        private static Dictionary<string, object> Merge(IEnumerable<KeyValuePair<string, object>> properties)
        {
            var result = new Dictionary<string, object>(StringComparer.Ordinal);
            if (properties != null)
            {
                foreach (var pair in properties)
                {
                    if (pair.Key != null)
                    {
                        result[pair.Key] = pair.Value;
                    }
                }
            }
            return result;
        }
    }
}
