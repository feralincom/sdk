import 'ad_revenue.dart';

// Hata (`fr_error`), oyun ve reklam geliri (`fr_ad_revenue`) olay sözleşmeleri (X4). Kurallar Android ve Web SDK'larıyla aynıdır
// (`packages/schemas/utp/v1/event.schema.json`, `game-events.md`); sözleşme dışı girdide `null` döner ve olay üretilmez.

/// Hata olayı adı.
const String errorEventName = 'fr_error';

/// Reklam geliri olayı adı.
const String adRevenueEventName = 'fr_ad_revenue';

/// Oyun olayı adları.
const String levelStartEvent = 'level_start';

/// Bölüm tamamlandı.
const String levelCompleteEvent = 'level_complete';

/// Bölüm başarısız.
const String levelFailEvent = 'level_fail';

/// Oyun içi para birimi kazanıldı.
const String economySourceEvent = 'economy_source';

/// Oyun içi para birimi harcandı.
const String economySinkEvent = 'economy_sink';

/// Ödüllü reklam gösterildi.
const String rewardedShownEvent = 'rewarded_ad_shown';

/// Ödüllü reklam tamamlandı.
const String rewardedCompleteEvent = 'rewarded_ad_complete';

/// Satın alma teklifi gösterildi.
const String iapOfferShownEvent = 'iap_offer_shown';

/// Satın alma başlatıldı.
const String iapInitiatedEvent = 'iap_initiated';

/// Tek olay miktarı üst sınırı.
const int maxEconomyAmount = 1000000000000;
const int _maxDurationMs = 86400000;
const int _maxNumber = 9007199254740991;

/// Reklam geliri üst sınırı (JS güvenli tam sayı; sunucu bigint taşır).
const int maxRevenueMicros = 9007199254740991;

final RegExp _currency = RegExp(r'^[A-Z]{3}$');
final RegExp _network = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
const List<String> _reservedKeys = [
  'verified',
  'verification',
  'verification_source',
  'receipt_provider',
  'receipt_digest',
  'receipt',
];

bool _text(String? value, int max) =>
    value != null && value.isNotEmpty && value.length <= max;

bool _putText(Map<String, Object?> out, String key, String? value, int max) {
  if (value == null) return true;
  if (!_text(value, max)) return false;
  out[key] = value;
  return true;
}

bool _putNumber(Map<String, Object?> out, String key, int? value, int min, int max) {
  if (value == null) return true;
  if (value < min || value > max) return false;
  out[key] = value;
  return true;
}

Map<String, Object?>? _level(
  String levelId,
  int? attempt,
  int? score,
  int? durationMs,
  String? failReason,
) {
  if (!_text(levelId, 64)) return null;
  final out = <String, Object?>{'level_id': levelId};
  if (!_putNumber(out, 'attempt', attempt, 1, _maxNumber)) return null;
  if (!_putNumber(out, 'score', score, 0, _maxNumber)) return null;
  if (!_putNumber(out, 'duration_ms', durationMs, 0, _maxDurationMs)) {
    return null;
  }
  if (!_putText(out, 'fail_reason', failReason, 64)) return null;
  return out;
}

/// `level_start` özellikleri.
Map<String, Object?>? levelStartProperties(String levelId, int? attempt) =>
    _level(levelId, attempt, null, null, null);

/// `level_complete` özellikleri.
Map<String, Object?>? levelCompleteProperties(
  String levelId,
  int? attempt,
  int? score,
  int? durationMs,
) => _level(levelId, attempt, score, durationMs, null);

/// `level_fail` özellikleri.
Map<String, Object?>? levelFailProperties(
  String levelId,
  int? attempt,
  int? score,
  int? durationMs,
  String? failReason,
) => _level(levelId, attempt, score, durationMs, failReason);

/// `economy_source` ve `economy_sink` özellikleri: oyun içi para birimi adı ve 1..10^12 miktar (sanal para, gerçek gelir değil).
Map<String, Object?>? economyProperties(
  String currencyName,
  int amount,
  String? reason,
  String? itemId,
) {
  if (!_text(currencyName, 64) || amount < 1 || amount > maxEconomyAmount) {
    return null;
  }
  final out = <String, Object?>{
    'currency_name': currencyName,
    'amount': amount,
  };
  if (!_putText(out, 'reason', reason, 64)) return null;
  if (!_putText(out, 'item_id', itemId, 64)) return null;
  return out;
}

/// `rewarded_ad_shown` özellikleri.
Map<String, Object?>? rewardedShownProperties(
  String placement,
  String? network,
) {
  if (!_text(placement, 64)) return null;
  final out = <String, Object?>{'placement': placement};
  if (!_putText(out, 'network', network, 64)) return null;
  return out;
}

/// `rewarded_ad_complete` özellikleri.
Map<String, Object?>? rewardedCompleteProperties(
  String placement,
  String? network,
  int? rewardAmount,
  String? rewardCurrency,
) {
  final out = rewardedShownProperties(placement, network);
  if (out == null) return null;
  if (!_putNumber(out, 'reward_amount', rewardAmount, 0, _maxNumber)) {
    return null;
  }
  if (!_putText(out, 'reward_currency', rewardCurrency, 64)) return null;
  return out;
}

/// `iap_offer_shown` özellikleri.
Map<String, Object?>? iapOfferShownProperties(
  String productId,
  String? placement,
) {
  if (!_text(productId, 128)) return null;
  final out = <String, Object?>{'product_id': productId};
  if (!_putText(out, 'placement', placement, 64)) return null;
  return out;
}

/// `iap_initiated` özellikleri.
Map<String, Object?>? iapInitiatedProperties(
  String productId,
  String? placement,
  String? transactionId,
) {
  final out = iapOfferShownProperties(productId, placement);
  if (out == null) return null;
  if (!_putText(out, 'transaction_id', transactionId, 128)) return null;
  return out;
}

String _formatWire(AdFormat format) => switch (format) {
  AdFormat.banner => 'banner',
  AdFormat.interstitial => 'interstitial',
  AdFormat.rewarded => 'rewarded',
  AdFormat.rewardedInterstitial => 'rewarded_interstitial',
  AdFormat.native => 'native',
  AdFormat.appOpen => 'app_open',
  AdFormat.other => 'other',
};

String _precisionWire(AdPrecision precision) => switch (precision) {
  AdPrecision.estimated => 'estimated',
  AdPrecision.publisherProvided => 'publisher_provided',
  AdPrecision.precise => 'precise',
  AdPrecision.unknown => 'unknown',
};

/// Reklam geliri olayının özelliklerini kurar; sözleşme dışı girdide `null`. Tutar para biriminin milyonda biri, tam sayı.
Map<String, Object?>? adRevenueProperties(AdRevenueInput input) {
  if (!_network.hasMatch(input.network)) return null;
  if (input.revenueMicros < 0 || input.revenueMicros > maxRevenueMicros) {
    return null;
  }
  if (!_currency.hasMatch(input.currency)) return null;
  final adUnit = input.adUnit;
  if (adUnit != null && !_text(adUnit, 128)) return null;
  final placement = input.placement;
  if (placement != null && !_text(placement, 64)) return null;
  final impressionId = input.impressionId;
  if (impressionId != null && !_text(impressionId, 128)) return null;
  final out = <String, Object?>{...?input.properties};
  for (final key in _reservedKeys) {
    out.remove(key);
  }
  out['network'] = input.network;
  out['ad_format'] = _formatWire(input.adFormat);
  out['revenue_micros'] = input.revenueMicros;
  out['currency'] = input.currency;
  out['precision'] = _precisionWire(input.precision);
  if (adUnit != null) out['ad_unit'] = adUnit;
  if (placement != null) out['placement'] = placement;
  if (impressionId != null) out['impression_id'] = impressionId;
  return out;
}
