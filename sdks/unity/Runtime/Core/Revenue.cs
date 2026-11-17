using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Feralin.Unity
{
    /// <summary>Satın alma türü; Android, Flutter ve React Native SDK'larındaki <c>purchase_type</c> ile aynı değerler.</summary>
    public enum PurchaseType
    {
        /// <summary>Tek seferlik satın alma.</summary>
        Purchase,
        /// <summary>Abonelik başlangıcı.</summary>
        SubscriptionStart,
        /// <summary>Abonelik yenilemesi.</summary>
        SubscriptionRenew,
        /// <summary>Abonelik iptali; tutar taşımaz (0).</summary>
        SubscriptionCancel,
    }

    /// <summary>Makbuzu doğrulayacak sağlayıcı.</summary>
    public enum ReceiptProvider
    {
        /// <summary>App Store.</summary>
        Apple,
        /// <summary>Google Play (purchaseToken).</summary>
        Google,
        /// <summary>Stripe.</summary>
        Stripe,
    }

    /// <summary>
    /// İsteğe bağlı ham makbuz. Toplayıcı yalnız sağlayıcı adını ve belirtecin SHA-256 özetini saklar; ham belirteç depoya girmez.
    /// Sunucu doğrulaması için belirteci kendi sunucunuzdan <c>POST /v1/projects/:id/finance/receipts/verify</c> ucuna da gönderebilirsiniz.
    /// </summary>
    public sealed class Receipt
    {
        /// <summary>Makbuz oluşturur.</summary>
        public Receipt(ReceiptProvider provider, string token)
        {
            Provider = provider;
            Token = token;
        }

        /// <summary>Sağlayıcı.</summary>
        public ReceiptProvider Provider { get; }
        /// <summary>Mağaza makbuzu ya da <c>purchaseToken</c> (en çok 8192 karakter).</summary>
        public string Token { get; }
    }

    /// <summary>
    /// <see cref="FeralinClient.TrackRevenue"/> girdisi (F5-E04-T01), Android, Flutter ve React Native SDK'larıyla aynı sözleşme.
    /// İstemci beyanıdır: <c>verified</c> hiçbir zaman gönderilmez; sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar.
    /// </summary>
    public sealed class RevenueInput
    {
        /// <summary>Mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz (en çok 128); sunucu aynı işlemi ikinci kez saymaz.</summary>
        public string TransactionId { get; set; }
        /// <summary>Küçük birimde satır toplamı: 49,99 TL için 4999. Abonelik iptalinde 0.</summary>
        public long AmountMinor { get; set; }
        /// <summary>ISO 4217, üç büyük harf.</summary>
        public string Currency { get; set; }
        /// <summary>Mağaza ürün kimliği (en çok 128).</summary>
        public string ProductId { get; set; }
        /// <summary>Adet (0…100000); bilgi amaçlıdır, tutarla çarpılmaz.</summary>
        public int Quantity { get; set; } = 1;
        /// <summary>Satın alma türü.</summary>
        public PurchaseType PurchaseType { get; set; } = PurchaseType.Purchase;
        /// <summary>İsteğe bağlı makbuz.</summary>
        public Receipt Receipt { get; set; }
        /// <summary>Ek özellikler; <c>verified</c> ve makbuz türevi anahtarlar düşürülür.</summary>
        public IEnumerable<KeyValuePair<string, object>> Properties { get; set; }
    }

    /// <summary><c>feralin_purchase</c> sözleşmesi; kurallar bütün SDK'larda aynıdır.</summary>
    internal static class RevenueEvent
    {
        public const string Name = "feralin_purchase";
        public const long MaxAmountMinor = (1L << 53) - 1;
        public const int MaxQuantity = 100000;
        public const int MaxTokenLength = 8192;

        private static readonly Regex CurrencyPattern = new Regex("^[A-Z]{3}$", RegexOptions.CultureInvariant);

        // İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
        private static readonly string[] ReservedKeys = { "verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt" };

        /// <summary>Gelir olayının özelliklerini kurar; sözleşme dışı girdide <c>null</c> döner (olay üretilmez).</summary>
        public static Dictionary<string, object> Properties(RevenueInput input)
        {
            if (input == null)
            {
                return null;
            }
            if (string.IsNullOrEmpty(input.TransactionId) || input.TransactionId.Length > EventRules.MaxIdentifierLength)
            {
                return null;
            }
            if (input.AmountMinor < 0 || input.AmountMinor > MaxAmountMinor)
            {
                return null;
            }
            if (input.Currency == null || !CurrencyPattern.IsMatch(input.Currency))
            {
                return null;
            }
            if (input.ProductId != null && (input.ProductId.Length == 0 || input.ProductId.Length > EventRules.MaxIdentifierLength))
            {
                return null;
            }
            if (input.Quantity < 0 || input.Quantity > MaxQuantity)
            {
                return null;
            }
            if (!Enum.IsDefined(typeof(PurchaseType), input.PurchaseType))
            {
                return null;
            }
            // Abonelik iptali para taşımaz; defter tutarsız iptali reddeder.
            if (input.PurchaseType == PurchaseType.SubscriptionCancel && input.AmountMinor != 0)
            {
                return null;
            }
            var receipt = input.Receipt;
            if (receipt != null && (!Enum.IsDefined(typeof(ReceiptProvider), receipt.Provider) || string.IsNullOrEmpty(receipt.Token) || receipt.Token.Length > MaxTokenLength))
            {
                return null;
            }

            var props = EventRules.SanitizeProperties(input.Properties, out _);
            foreach (var key in ReservedKeys)
            {
                props.Remove(key);
            }
            props["transaction_id"] = input.TransactionId;
            props["amount_minor"] = input.AmountMinor;
            props["currency"] = input.Currency;
            props["quantity"] = input.Quantity;
            props["purchase_type"] = PurchaseTypeWire(input.PurchaseType);
            if (input.ProductId != null)
            {
                props["product_id"] = input.ProductId;
            }
            if (receipt != null)
            {
                props["receipt"] = new Dictionary<string, object>(StringComparer.Ordinal)
                {
                    ["provider"] = ReceiptProviderWire(receipt.Provider),
                    ["token"] = receipt.Token,
                };
            }
            return props;
        }

        public static string PurchaseTypeWire(PurchaseType type)
        {
            switch (type)
            {
                case PurchaseType.SubscriptionStart:
                    return "subscription_start";
                case PurchaseType.SubscriptionRenew:
                    return "subscription_renew";
                case PurchaseType.SubscriptionCancel:
                    return "subscription_cancel";
                default:
                    return "purchase";
            }
        }

        public static string ReceiptProviderWire(ReceiptProvider provider)
        {
            switch (provider)
            {
                case ReceiptProvider.Apple:
                    return "apple";
                case ReceiptProvider.Google:
                    return "google";
                default:
                    return "stripe";
            }
        }
    }

    /// <summary>ISO 4217 küçük birim üssü: oyunun ondalık tutarını (eski <c>iap_purchase</c>) tam sayı küçük birime çevirir.</summary>
    public static class CurrencyMinorUnits
    {
        private static readonly HashSet<string> ZeroDecimal = new HashSet<string>(StringComparer.Ordinal)
        {
            "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF",
        };

        private static readonly HashSet<string> ThreeDecimal = new HashSet<string>(StringComparer.Ordinal)
        {
            "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND",
        };

        /// <summary>Para biriminin ondalık basamak sayısı (0, 2 ya da 3).</summary>
        public static int Exponent(string currency) => currency != null && ZeroDecimal.Contains(currency) ? 0 : currency != null && ThreeDecimal.Contains(currency) ? 3 : 2;

        /// <summary>Ondalık tutarı küçük birime çevirir (yarım değer yukarı yuvarlanır); aralık dışıysa <c>null</c>.</summary>
        public static long? ToMinor(decimal amount, string currency)
        {
            if (amount < 0)
            {
                return null;
            }
            var scale = 1m;
            for (var i = 0; i < Exponent(currency); i++)
            {
                scale *= 10m;
            }
            var minor = Math.Round(amount * scale, 0, MidpointRounding.AwayFromZero);
            return minor > RevenueEvent.MaxAmountMinor ? (long?)null : (long)minor;
        }
    }

    /// <summary>Reklam biçimi (<c>fr_ad_revenue.ad_format</c>).</summary>
    public enum AdFormat
    {
        /// <summary>Banner.</summary>
        Banner,
        /// <summary>Tam ekran (interstitial).</summary>
        Interstitial,
        /// <summary>Ödüllü.</summary>
        Rewarded,
        /// <summary>Ödüllü tam ekran.</summary>
        RewardedInterstitial,
        /// <summary>Yerel (native).</summary>
        Native,
        /// <summary>Uygulama açılış reklamı.</summary>
        AppOpen,
        /// <summary>Diğer.</summary>
        Other,
    }

    /// <summary>Ağın bildirdiği gelir kesinliği (<c>fr_ad_revenue.precision</c>).</summary>
    public enum AdPrecision
    {
        /// <summary>Tahmini.</summary>
        Estimated,
        /// <summary>Yayıncıya sağlanan.</summary>
        PublisherProvided,
        /// <summary>Kesin.</summary>
        Precise,
        /// <summary>Bilinmiyor (varsayılan).</summary>
        Unknown,
    }

    /// <summary>
    /// Reklam geliri (<c>fr_ad_revenue</c>): satın alma gelirinden ayrıdır ve deftere <c>feralin_purchase</c> olarak girmez.
    /// Android SDK <c>AdRevenueInput</c> ile aynı alanlar; istemci beyanıdır, sunucuda ESTIMATED kalır.
    /// </summary>
    public sealed class AdRevenueInput
    {
        /// <summary>Reklam ağı, küçük harf ve alt çizgi (<c>^[a-z][a-z0-9_]{0,63}$</c>): <c>admob</c>, <c>applovin_max</c>, <c>ironsource</c>, <c>unity_ads</c>.</summary>
        public string Network { get; set; }
        /// <summary>Reklam biçimi.</summary>
        public AdFormat AdFormat { get; set; } = AdFormat.Other;
        /// <summary>Tek gösterim geliri, para biriminin milyonda biri: 0,0125 USD için 12500. Ondalık yok.</summary>
        public long RevenueMicros { get; set; }
        /// <summary>ISO 4217.</summary>
        public string Currency { get; set; }
        /// <summary>İsteğe bağlı reklam birimi kimliği (en çok 128).</summary>
        public string AdUnit { get; set; }
        /// <summary>Ağın bildirdiği kesinlik.</summary>
        public AdPrecision Precision { get; set; } = AdPrecision.Unknown;
        /// <summary>İsteğe bağlı yerleşim adı (en çok 64).</summary>
        public string Placement { get; set; }
        /// <summary>Ağın gösterim kimliği (en çok 128); verilirse aynı gösterim ikinci kez sayılmaz.</summary>
        public string ImpressionId { get; set; }
        /// <summary>Ek özellikler; <c>verified</c> ve türevleri düşürülür.</summary>
        public IEnumerable<KeyValuePair<string, object>> Properties { get; set; }
    }

    internal static class AdRevenueEvent
    {
        public const string Name = "fr_ad_revenue";

        private static readonly Regex CurrencyPattern = new Regex("^[A-Z]{3}$", RegexOptions.CultureInvariant);
        private static readonly Regex NetworkPattern = new Regex("^[a-z][a-z0-9_]{0,63}$", RegexOptions.CultureInvariant);
        private static readonly string[] Reserved = { "verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt" };

        public static Dictionary<string, object> Properties(AdRevenueInput input)
        {
            if (input == null || input.Network == null || !NetworkPattern.IsMatch(input.Network))
            {
                return null;
            }
            if (!Enum.IsDefined(typeof(AdFormat), input.AdFormat) || !Enum.IsDefined(typeof(AdPrecision), input.Precision))
            {
                return null;
            }
            if (input.RevenueMicros < 0 || input.RevenueMicros > RevenueEvent.MaxAmountMinor)
            {
                return null;
            }
            if (input.Currency == null || !CurrencyPattern.IsMatch(input.Currency))
            {
                return null;
            }
            if (Bad(input.AdUnit, 128) || Bad(input.Placement, 64) || Bad(input.ImpressionId, 128))
            {
                return null;
            }
            var props = EventRules.SanitizeProperties(input.Properties, out _);
            foreach (var key in Reserved)
            {
                props.Remove(key);
            }
            props["network"] = input.Network;
            props["ad_format"] = FormatWire(input.AdFormat);
            props["revenue_micros"] = input.RevenueMicros;
            props["currency"] = input.Currency;
            props["precision"] = PrecisionWire(input.Precision);
            if (input.AdUnit != null)
            {
                props["ad_unit"] = input.AdUnit;
            }
            if (input.Placement != null)
            {
                props["placement"] = input.Placement;
            }
            if (input.ImpressionId != null)
            {
                props["impression_id"] = input.ImpressionId;
            }
            return props;
        }

        private static bool Bad(string value, int max) => value != null && (value.Length == 0 || value.Length > max);

        public static string PrecisionWire(AdPrecision precision)
        {
            switch (precision)
            {
                case AdPrecision.Estimated:
                    return "estimated";
                case AdPrecision.PublisherProvided:
                    return "publisher_provided";
                case AdPrecision.Precise:
                    return "precise";
                default:
                    return "unknown";
            }
        }

        public static string FormatWire(AdFormat format)
        {
            switch (format)
            {
                case AdFormat.Banner:
                    return "banner";
                case AdFormat.Interstitial:
                    return "interstitial";
                case AdFormat.Rewarded:
                    return "rewarded";
                case AdFormat.RewardedInterstitial:
                    return "rewarded_interstitial";
                case AdFormat.Native:
                    return "native";
                case AdFormat.AppOpen:
                    return "app_open";
                default:
                    return "other";
            }
        }
    }
}
