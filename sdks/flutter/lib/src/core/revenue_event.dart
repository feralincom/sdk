import 'types.dart';

/// `trackRevenue` sözleşmesi (F5-E04-T01): olay adı `feralin_purchase`; tutar küçük birimde tam sayı (kuruş, cent), para birimi
/// ISO 4217. İstemci beyanıdır: `verified` hiçbir zaman gönderilmez, doğrulama sunucu tarafı makbuz doğrulayıcısınındır.
/// Kurallar bütün SDK'larda aynıdır.
const String revenueEventName = 'feralin_purchase';

/// JS güvenli tam sayı üst sınırı; sunucu bigint taşır.
const int maxAmountMinor = 9007199254740991;
const int _maxQuantity = 100000;
final RegExp _currency = RegExp(r'^[A-Z]{3}$');

// İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
const List<String> _reservedKeys = [
  'verified',
  'verification',
  'verification_source',
  'receipt_provider',
  'receipt_digest',
  'receipt',
];

String _purchaseTypeWire(PurchaseType type) => switch (type) {
  PurchaseType.purchase => 'purchase',
  PurchaseType.subscriptionStart => 'subscription_start',
  PurchaseType.subscriptionRenew => 'subscription_renew',
  PurchaseType.subscriptionCancel => 'subscription_cancel',
};

String _providerWire(ReceiptProvider provider) => switch (provider) {
  ReceiptProvider.apple => 'apple',
  ReceiptProvider.google => 'google',
  ReceiptProvider.stripe => 'stripe',
};

/// Gelir olayının özelliklerini kurar; sözleşme dışı girdide `null` döner (olay üretilmez).
Map<String, Object?>? revenueProperties(RevenueInput input) {
  if (input.transactionId.isEmpty || input.transactionId.length > 128) {
    return null;
  }
  if (input.amountMinor < 0 || input.amountMinor > maxAmountMinor) return null;
  if (!_currency.hasMatch(input.currency)) return null;
  final productId = input.productId;
  if (productId != null && (productId.isEmpty || productId.length > 128)) {
    return null;
  }
  if (input.quantity < 0 || input.quantity > _maxQuantity) return null;
  // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
  if (input.purchaseType == PurchaseType.subscriptionCancel &&
      input.amountMinor != 0) {
    return null;
  }
  final receipt = input.receipt;
  if (receipt != null && (receipt.token.isEmpty || receipt.token.length > 8192)) {
    return null;
  }
  final out = <String, Object?>{...?input.properties};
  for (final key in _reservedKeys) {
    out.remove(key);
  }
  out['transaction_id'] = input.transactionId;
  out['amount_minor'] = input.amountMinor;
  out['currency'] = input.currency;
  out['quantity'] = input.quantity;
  out['purchase_type'] = _purchaseTypeWire(input.purchaseType);
  if (productId != null) out['product_id'] = productId;
  if (receipt != null) {
    out['receipt'] = {
      'provider': _providerWire(receipt.provider),
      'token': receipt.token,
    };
  }
  return out;
}
