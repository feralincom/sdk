/// Reklam biçimi (`ad_format`).
enum AdFormat {
  /// Afiş.
  banner,

  /// Tam ekran geçiş reklamı.
  interstitial,

  /// Ödüllü reklam.
  rewarded,

  /// Ödüllü geçiş reklamı.
  rewardedInterstitial,

  /// Yerel reklam.
  native,

  /// Uygulama açılış reklamı.
  appOpen,

  /// Diğer.
  other,
}

/// Reklam ağının bildirdiği gelir kesinliği (`precision`); istemci beyanıdır, doğrulama sınıfı değildir.
enum AdPrecision {
  /// Tahmini.
  estimated,

  /// Yayıncının sağladığı.
  publisherProvided,

  /// Kesin.
  precise,

  /// Bilinmiyor.
  unknown,
}

/// `trackAdRevenue` girdisi (X4): tek reklam gösteriminin geliri (ör. AdMob `onPaidEvent`, AppLovin MAX `onAdRevenuePaid`).
/// Satın alma gelirinden (`trackRevenue`) ve reklam harcamasından ayrı bir gelir sınıfıdır; istemci beyanıdır ve sunucuda
/// ESTIMATED kalır.
class AdRevenueInput {
  /// Girdiyi kurar.
  const AdRevenueInput({
    required this.network,
    required this.adFormat,
    required this.revenueMicros,
    required this.currency,
    this.adUnit,
    this.precision = AdPrecision.unknown,
    this.placement,
    this.impressionId,
    this.properties,
  });

  /// Reklam ağı, küçük harf ve alt çizgi: `admob`, `applovin_max`, `ironsource`, `unity_ads`.
  final String network;

  /// Reklam biçimi.
  final AdFormat adFormat;

  /// Tek gösterim geliri, para biriminin milyonda biri: 0,0125 USD için 12500. Ondalık yoktur.
  final int revenueMicros;

  /// ISO 4217, üç büyük harf.
  final String currency;

  /// Reklam birimi kimliği (≤128).
  final String? adUnit;

  /// Ağın bildirdiği kesinlik.
  final AdPrecision precision;

  /// Yerleşim adı (≤64).
  final String? placement;

  /// Ağın gösterim kimliği; verilirse aynı gösterim ikinci kez sayılmaz.
  final String? impressionId;

  /// Ek özellikler; `verified` ve türevleri düşürülür.
  final Map<String, Object?>? properties;
}
