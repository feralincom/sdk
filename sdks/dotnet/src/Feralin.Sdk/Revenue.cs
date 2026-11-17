using System.Text.RegularExpressions;

namespace Feralin;

/// <summary>Satın alma türü (<c>purchase_type</c>).</summary>
public enum PurchaseType
{
    /// <summary>Tek seferlik satın alma.</summary>
    Purchase,
    /// <summary>Abonelik başlangıcı.</summary>
    SubscriptionStart,
    /// <summary>Abonelik yenileme.</summary>
    SubscriptionRenew,
    /// <summary>Abonelik iptali; tutar 0 olabilir.</summary>
    SubscriptionCancel,
}

/// <summary>Makbuz sağlayıcısı.</summary>
public enum ReceiptProvider
{
    /// <summary>Apple App Store.</summary>
    Apple,
    /// <summary>Google Play.</summary>
    Google,
    /// <summary>Stripe.</summary>
    Stripe,
}

/// <summary>İsteğe bağlı ham makbuz; toplayıcı yalnız sağlayıcı adını ve belirtecin SHA-256 özetini saklar.</summary>
/// <param name="Provider">Sağlayıcı.</param>
/// <param name="Token">Makbuz ya da satın alma belirteci (en çok 8192 karakter).</param>
public sealed record Receipt(ReceiptProvider Provider, string Token);

/// <summary>
/// <c>TrackRevenue</c> girdisi (F5-E04-T01). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED
/// sayar, aksi hâlde ESTIMATED kalır; <c>verified</c> alanı hiçbir zaman gönderilmez.
/// </summary>
/// <param name="TransactionId">Mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz; sunucu aynı işlemi ikinci kez saymaz.</param>
/// <param name="AmountMinor">Küçük birimde satır toplamı: 49,99 TL için 4999. Ondalık yoktur; <c>Quantity</c> ile çarpılmaz. Abonelik iptalinde 0.</param>
/// <param name="Currency">ISO 4217, üç büyük harf.</param>
public sealed record RevenueInput(string TransactionId, long AmountMinor, string Currency)
{
    /// <summary>İsteğe bağlı ürün kimliği (en çok 128 karakter).</summary>
    public string? ProductId { get; init; }
    /// <summary>Adet, 0..100000; varsayılan 1.</summary>
    public int Quantity { get; init; } = 1;
    /// <summary>Satın alma türü; varsayılan tek seferlik satın alma.</summary>
    public PurchaseType PurchaseType { get; init; } = PurchaseType.Purchase;
    /// <summary>İsteğe bağlı ham makbuz.</summary>
    public Receipt? Receipt { get; init; }
    /// <summary>Ek özellikler; <c>verified</c> ve türevleri düşürülür.</summary>
    public IEnumerable<KeyValuePair<string, object?>>? Properties { get; init; }
}

/// <summary>Gelir sözleşmesi; kurallar bütün SDK'larda aynıdır.</summary>
public static partial class RevenueRules
{
    /// <summary>Sözleşmenin tek olay adı.</summary>
    public const string EventName = "feralin_purchase";
    /// <summary>JS güvenli tam sayı üst sınırı; sunucu bigint taşır.</summary>
    public const long MaxAmountMinor = (1L << 53) - 1;
    /// <summary>Adet üst sınırı.</summary>
    public const int MaxQuantity = 100_000;

    // İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
    private static readonly string[] ReservedKeys = { "verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt" };

    [GeneratedRegex("^[A-Z]{3}$", RegexOptions.CultureInvariant)]
    private static partial Regex CurrencyPattern();

    /// <summary>Tel üzerindeki <c>purchase_type</c> değeri.</summary>
    public static string Wire(this PurchaseType type) => type switch
    {
        PurchaseType.SubscriptionStart => "subscription_start",
        PurchaseType.SubscriptionRenew => "subscription_renew",
        PurchaseType.SubscriptionCancel => "subscription_cancel",
        _ => "purchase",
    };

    /// <summary>Tel üzerindeki <c>receipt.provider</c> değeri.</summary>
    public static string Wire(this ReceiptProvider provider) => provider switch
    {
        ReceiptProvider.Apple => "apple",
        ReceiptProvider.Google => "google",
        _ => "stripe",
    };

    /// <summary>Gelir olayının özelliklerini kurar; sözleşme dışı girdide <c>null</c> döner (olay üretilmez).</summary>
    public static Dictionary<string, object?>? Build(RevenueInput? input)
    {
        if (input is null || string.IsNullOrEmpty(input.TransactionId) || input.TransactionId.Length > 128)
        {
            return null;
        }
        if (input.AmountMinor < 0 || input.AmountMinor > MaxAmountMinor)
        {
            return null;
        }
        if (input.Currency is null || !CurrencyPattern().IsMatch(input.Currency))
        {
            return null;
        }
        if (input.ProductId is not null && (input.ProductId.Length == 0 || input.ProductId.Length > 128))
        {
            return null;
        }
        if (input.Quantity < 0 || input.Quantity > MaxQuantity)
        {
            return null;
        }
        if (!Enum.IsDefined(input.PurchaseType))
        {
            return null;
        }
        // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
        if (input.PurchaseType == PurchaseType.SubscriptionCancel && input.AmountMinor != 0)
        {
            return null;
        }
        if (input.Receipt is not null && (!Enum.IsDefined(input.Receipt.Provider) || string.IsNullOrEmpty(input.Receipt.Token) || input.Receipt.Token.Length > 8192))
        {
            return null;
        }
        var props = EventRules.SanitizeProperties(input.Properties);
        foreach (var key in ReservedKeys)
        {
            props.Remove(key);
        }
        props["transaction_id"] = input.TransactionId;
        props["amount_minor"] = input.AmountMinor;
        props["currency"] = input.Currency;
        props["quantity"] = input.Quantity;
        props["purchase_type"] = input.PurchaseType.Wire();
        if (input.ProductId is not null)
        {
            props["product_id"] = input.ProductId;
        }
        if (input.Receipt is not null)
        {
            props["receipt"] = new Dictionary<string, object?> { ["provider"] = input.Receipt.Provider.Wire(), ["token"] = input.Receipt.Token };
        }
        return props;
    }
}
