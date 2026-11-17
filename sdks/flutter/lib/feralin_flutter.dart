/// Feralin UTP v1 SDK'sı: consent-first olaylar, kalıcı çevrimdışı kuyruk, Android'de Play Install Referrer ve
/// App Links, iOS'ta uygulamanın verdiği evrensel bağlantılar.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show ErrorCallback;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'src/core/ad_revenue.dart';
import 'src/core/engine.dart';
import 'src/core/error_event.dart';
import 'src/core/event_json.dart';
import 'src/core/event_store.dart';
import 'src/core/profile.dart';
import 'src/core/revenue_event.dart';
import 'src/core/signal_events.dart';
import 'src/core/transport.dart';
import 'src/core/types.dart';
import 'src/platform_bridge.dart';

export 'src/core/ad_revenue.dart' show AdFormat, AdPrecision, AdRevenueInput;
export 'src/core/types.dart';

/// iOS eklenti kaydı: yerel kod olmadığı için Dart tarafında yapılacak iş yoktur.
class FeralinFlutterIos {
  /// Flutter eklenti kaydedicisi çağırır.
  static void registerWith() {}
}

/// SDK girişi. Hiçbir metot uygulamaya hata fırlatmaz.
abstract final class Feralin {
  static FeralinEngine? _engine;
  static PlatformBridge? _bridge;
  static _LifecycleObserver? _observer;
  static String? _appVersion;
  static ErrorLimiter _errorLimiter = ErrorLimiter();
  static bool _errorCaptureInstalled = false;
  static FlutterExceptionHandler? _previousFlutterError;
  static ErrorCallback? _previousPlatformError;

  /// `runApp` öncesinde bir kez çağrılır; ikinci çağrı yok sayılır. `true`: SDK etkin.
  /// Geçersiz yapılandırma veya desteklenmeyen platformda `false` döner ve SDK kapalı kalır.
  static Future<bool> initialize(FeralinConfig config) async {
    if (_engine != null) return true;
    try {
      final error = config.validationError();
      if (error != null) {
        debugPrint('Feralin: SDK kapalı: $error');
        return false;
      }
      final PlatformBridge bridge;
      if (Platform.isAndroid) {
        bridge = AndroidPlatformBridge();
      } else if (Platform.isIOS) {
        bridge = const IosPlatformBridge();
      } else {
        debugPrint('Feralin: SDK kapalı: yalnız Android ve iOS desteklenir');
        return false;
      }
      WidgetsFlutterBinding.ensureInitialized();
      return await _start(config, bridge);
    } on Object catch (error) {
      debugPrint('Feralin: başlatılamadı: ${error.runtimeType}');
      return false;
    }
  }

  static Future<bool> _start(
    FeralinConfig config,
    PlatformBridge bridge,
  ) async {
    void log(String message) {
      if (config.debug) debugPrint('Feralin: $message');
    }

    NativeAppInfo info = const NativeAppInfo();
    try {
      info = await bridge.appInfo();
    } on Object catch (error) {
      log('uygulama bilgisi okunamadı: ${error.runtimeType}');
    }

    final engine = FeralinEngine(
      config: config,
      platform: bridge.platform,
      linkSource: bridge.linkSource,
      openStore: () => _openStore(bridge, log),
      transport: IoHttpTransport(),
      referrer: bridge.readInstallReferrer,
      adServicesToken: bridge.adServicesToken,
      appContext: () => AppContext(
        locale: PlatformDispatcher.instance.locale.toLanguageTag(),
        timezone: info.timezone,
        appVersion: config.appVersion ?? info.version,
        appBuild: config.appBuild ?? info.build,
      ),
      log: log,
    );
    _engine = engine;
    _bridge = bridge;
    _appVersion = config.appVersion ?? info.version;
    await engine.start();

    bridge.listen(
      onLink: (url) {
        if (config.autoCaptureDeepLinks) unawaited(engine.handleLink(url));
      },
      onNetworkAvailable: () => unawaited(engine.onNetworkAvailable()),
    );
    final observer = _LifecycleObserver(engine, bridge);
    _observer = observer;
    WidgetsBinding.instance.addObserver(observer);
    // Başlangıçta durum henüz bildirilmemiş olabilir; `runApp` öncesi ön plan kabul edilir.
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) {
      observer.enterForeground();
    }
    if (config.autoCaptureDeepLinks) {
      try {
        final link = await bridge.initialLink();
        if (link != null) unawaited(engine.handleLink(link));
      } on Object catch (error) {
        log('açılış bağlantısı okunamadı: ${error.runtimeType}');
      }
    }
    return true;
  }

  static Future<EventStore> _openStore(
    PlatformBridge bridge,
    void Function(String) log,
  ) async {
    try {
      return await FileEventStore.open(
        await bridge.storageDirectory(),
        log: log,
        cipher: bridge.queueCipher,
      );
    } on Object catch (error) {
      // Disk açılamazsa SDK yine çalışır; kuyruk süreç ömrüyle sınırlı kalır.
      log('kalıcı kuyruk açılamadı: ${error.runtimeType}');
      return MemoryEventStore();
    }
  }

  /// İzin kararını bildirir. `analytics=false`: kuyruk ve depodaki anonim kimlik silinir.
  static Future<void> setConsent(Consent consent) async {
    await _engine?.setConsent(consent);
  }

  /// `setConsent(Consent(analytics: false))` ile aynıdır.
  static Future<void> optOut() => setConsent(const Consent(analytics: false));

  /// Olay üretir ve kuyruğa alır. Olay kimliği döner; izin yoksa, ad geçersizse veya SDK kapalıysa `null`.
  static String? track(String name, [Map<String, Object?>? properties]) =>
      _engine?.track(name, properties);

  /// `screen_view` olayı üretir.
  static String? screen(String name, [Map<String, Object?>? properties]) =>
      track('screen_view', {...?properties, 'screen_name': name});

  /// Satın alma ya da abonelik beyanı (`feralin_purchase`). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı
  /// onaylarsa REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez.
  /// Sözleşme dışı girdide `null` döner.
  static String? trackRevenue(RevenueInput input) {
    final props = revenueProperties(input);
    if (props == null) {
      debugPrint('[feralin] geçersiz gelir girdisi, olay üretilmedi');
      return null;
    }
    return _engine?.track(revenueEventName, props);
  }

  /// Reklam gösterimi geliri (`fr_ad_revenue`, X4). Satın alma gelirinden ([trackRevenue]) ve reklam harcamasından ayrı bir gelir sınıfıdır;
  /// istemci beyanıdır ve sunucuda ESTIMATED kalır, reklam ağı raporuyla mutabakat yoktur. Sözleşme dışı girdide `null` döner.
  static String? trackAdRevenue(AdRevenueInput input) =>
      _signal(adRevenueEventName, adRevenueProperties(input));

  /// Bölüm başladı (`level_start`). `levelId` 1-64 karakter. Sözleşme dışı girdide `null`.
  static String? trackLevelStart(String levelId, {int? attempt}) =>
      _signal(levelStartEvent, levelStartProperties(levelId, attempt));

  /// Bölüm tamamlandı (`level_complete`). Süre milisaniyedir (0-86 400 000).
  static String? trackLevelComplete(
    String levelId, {
    int? attempt,
    int? score,
    int? durationMs,
  }) => _signal(
    levelCompleteEvent,
    levelCompleteProperties(levelId, attempt, score, durationMs),
  );

  /// Bölüm başarısız (`level_fail`).
  static String? trackLevelFail(
    String levelId, {
    int? attempt,
    int? score,
    int? durationMs,
    String? failReason,
  }) => _signal(
    levelFailEvent,
    levelFailProperties(levelId, attempt, score, durationMs, failReason),
  );

  /// Oyun içi para birimi kazanıldı (`economy_source`). Sanal para birimidir; gerçek gelir değildir. Miktar 1..10^12.
  static String? trackEconomySource(
    String currencyName,
    int amount, {
    String? reason,
    String? itemId,
  }) => _signal(
    economySourceEvent,
    economyProperties(currencyName, amount, reason, itemId),
  );

  /// Oyun içi para birimi harcandı (`economy_sink`).
  static String? trackEconomySink(
    String currencyName,
    int amount, {
    String? reason,
    String? itemId,
  }) => _signal(
    economySinkEvent,
    economyProperties(currencyName, amount, reason, itemId),
  );

  /// Ödüllü reklam gösterildi (`rewarded_ad_shown`). Gelir taşımaz; reklam geliri [trackAdRevenue] ile bildirilir.
  static String? trackRewardedAdShown(String placement, {String? network}) =>
      _signal(rewardedShownEvent, rewardedShownProperties(placement, network));

  /// Ödüllü reklam tamamlandı (`rewarded_ad_complete`).
  static String? trackRewardedAdComplete(
    String placement, {
    String? network,
    int? rewardAmount,
    String? rewardCurrency,
  }) => _signal(
    rewardedCompleteEvent,
    rewardedCompleteProperties(placement, network, rewardAmount, rewardCurrency),
  );

  /// Uygulama içi satın alma teklifi gösterildi (`iap_offer_shown`). Gelir değildir; gelir [trackRevenue] ile bildirilir.
  static String? trackIapOfferShown(String productId, {String? placement}) =>
      _signal(iapOfferShownEvent, iapOfferShownProperties(productId, placement));

  /// Satın alma başlatıldı (`iap_initiated`). `transactionId` sonradan [trackRevenue] ile bildirilen işlemle aynıysa panel satın almayı
  /// bu basamağa bağlar.
  static String? trackIapInitiated(
    String productId, {
    String? placement,
    String? transactionId,
  }) => _signal(
    iapInitiatedEvent,
    iapInitiatedProperties(productId, placement, transactionId),
  );

  static String? _signal(String name, Map<String, Object?>? properties) {
    if (properties == null) {
      debugPrint('[feralin] geçersiz olay girdisi, olay üretilmedi: $name');
      return null;
    }
    return _engine?.track(name, properties);
  }

  /// Yakalanan (try/catch) bir hatayı `fr_error` olarak bildirir. Yığın izi gitmez: hata sınıfı adı, temizlenmiş mesaj ve çerçeve özeti
  /// olan parmak izi gider. Süreç başına en çok 20 olay, aynı parmak izi için en çok 3 olay. Sınır dolduysa ya da izin yoksa `null`.
  static String? captureError(Object error, [StackTrace? stack]) =>
      _reportError(error, stack, origin: errorOriginHandled);

  static String? _reportError(
    Object error,
    StackTrace? stack, {
    required String origin,
  }) {
    final engine = _engine;
    if (engine == null) return null;
    try {
      final props = errorProperties(
        error,
        stack,
        origin: origin,
        fatal: false,
        appVersion: _appVersion,
      );
      if (!_errorLimiter.allow(props['fingerprint']! as String)) return null;
      return engine.track(errorEventName, props);
    } on Object {
      // Hata bildirimi uygulamayı düşüremez.
      return null;
    }
  }

  /// Yakalanmamış Flutter ve Dart hatalarını `fr_error` olarak bildirir: `FlutterError.onError` ve `PlatformDispatcher.onError`. Mevcut işleyiciler
  /// korunur ve çağrılmaya devam eder; hata davranışı değişmez. Sembolleştirme yoktur. İkinci çağrı yok sayılır.
  ///
  /// [sampleRate]: 0..1 örnekleme oranı (varsayılan 1).
  static void captureUncaughtErrors({double sampleRate = 1.0}) {
    if (_errorCaptureInstalled) return;
    _errorCaptureInstalled = true;
    _errorLimiter = ErrorLimiter(sampleRate: sampleRate.clamp(0.0, 1.0));
    final previousFlutter = FlutterError.onError;
    _previousFlutterError = previousFlutter;
    FlutterError.onError = (details) {
      _reportError(details.exception, details.stack, origin: errorOriginUncaught);
      if (previousFlutter != null) {
        previousFlutter(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    final previousPlatform = PlatformDispatcher.instance.onError;
    _previousPlatformError = previousPlatform;
    PlatformDispatcher.instance.onError = (error, stack) {
      _reportError(error, stack, origin: errorOriginUncaught);
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Uygulamanın kendi kullanıcı kimliği (≤128 karakter). E-posta veya telefon gibi PII verilmemelidir.
  static void identify(String userId) => _engine?.identify(userId);

  /// Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve temizlenmiş özellikler. Grup kimliği 1-128
  /// karakter olmalı, `@` ve kontrol karakteri içermemelidir; uymazsa olay üretilmez ve `null` döner. Toplayıcı yalnız projenin izin
  /// listesindeki özellikleri saklar.
  static String? group(String groupId, [Map<String, Object?>? traits]) {
    final props = groupEventProperties(groupId, traits, log: _profileLog);
    return props == null ? null : _engine?.track(groupEventName, props);
  }

  /// Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad vb.),
  /// doğrulama alanı ve sözleşme dışı değer düşer; geçerli özellik kalmazsa olay üretilmez ve `null` döner. Toplayıcı yalnız projenin
  /// izin listesindeki anahtarları saklar (liste boşsa hiçbirini).
  static String? setUserProperties(Map<String, Object?> properties) {
    final props = userPropertiesEventProperties(properties, log: _profileLog);
    return props == null ? null : _engine?.track(userPropertiesEventName, props);
  }

  static void _profileLog(String message) => debugPrint('[feralin] $message');

  /// Global özellikleri birleştirir: `fr_` ile başlamayan her olaya eklenir, olayın kendi özelliği aynı anahtarda kazanır. `null` değer
  /// anahtarı siler; kurallar [setUserProperties] ile aynıdır, toplam en çok 50 anahtar. [reset] globalleri de siler.
  static void setGlobalProperties(Map<String, Object?> properties) =>
      _engine?.setGlobalProperties(properties);

  /// Bütün global özellikleri siler.
  static void clearGlobalProperties() => _engine?.clearGlobalProperties();

  /// Çıkışta çağrılır: oturum ve anonim kimlik yenilenir, kuyruk ve global özellikler silinir.
  static Future<void> reset() async {
    await _engine?.reset();
  }

  /// Kuyruğu göndermeyi dener.
  static Future<FlushResult> flush() async =>
      await _engine?.flush() ?? FlushResult.none;

  /// Uygulamayı açan bağlantıyı işler. iOS'ta evrensel bağlantının tek yoludur (kaynak `universal_link`).
  /// Android'de `autoCaptureDeepLinks` açıkken çağrılmamalıdır; aynı açılış iki kez sayılır.
  static Future<void> handleDeepLink(Uri uri) async {
    await _engine?.handleLink(uri.toString());
  }

  /// Kurulumdan sonra ertelenmiş derin bağlantıyı bir kez verir (yalnız Android; iOS `notSupported`). Okuma reklam ölçümü
  /// iznine bağlıdır. Yol olay özelliğine yazılmaz ve sunucuya gönderilmez.
  static Future<DeferredDeepLink> consumeDeferredDeepLink() async =>
      await _engine?.consumeDeferredDeepLink() ??
      const DeferredDeepLink(DeferredDeepLinkStatus.notInitialized);

  /// Kurulum kimliği (ADR-0007). Yalnız iOS'ta ve reklam ölçümü izniyle üretilir; aksi hâlde `null`. Kimliği kendi sunucunuza
  /// iletin: sunucu gizli API anahtarıyla `account-links` ucunu çağırır, SDK hesap kimliği yazmaz.
  static Future<String?> installIdentifier() async =>
      await _engine?.installIdentifier();

  /// AdServices token'ını bu kurulum kimliğiyle gönderir ve kimliği döndürür (`FeralinConfig.attribution` gerekir).
  /// iOS dışında ve iOS yerel eklentisi yokken `AdServicesStatus.unsupported` döner. Sunucu bugün Apple'a sormaz: sonuç atıf
  /// kararı değildir.
  static Future<InstallBinding> bindInstall() async =>
      await _engine?.bindInstall() ??
      const InstallBinding(
        null,
        AdServicesSubmission(AdServicesStatus.unsupported),
      );

  /// Anlık durum; SDK başlatılmadıysa `initialized=false`.
  static FeralinStatus getStatus() =>
      _engine?.status() ??
      const FeralinStatus(
        initialized: false,
        sdk: sdkName,
        version: sdkVersion,
        queued: 0,
      );

  /// Testler için tüm durumu sıfırlar.
  @visibleForTesting
  static Future<void> resetForTest() async {
    final observer = _observer;
    if (observer != null) WidgetsBinding.instance.removeObserver(observer);
    await _engine?.settle();
    _engine = null;
    _bridge = null;
    _observer = null;
    _appVersion = null;
    if (_errorCaptureInstalled) {
      FlutterError.onError = _previousFlutterError;
      PlatformDispatcher.instance.onError = _previousPlatformError;
      _errorCaptureInstalled = false;
    }
    _errorLimiter = ErrorLimiter();
  }

  /// Testlerde sahte köprüyle başlatır.
  @visibleForTesting
  static Future<bool> initializeForTest(
    FeralinConfig config,
    PlatformBridge bridge,
  ) => _start(config, bridge);

  /// Testlerde iş sırasının bitmesini bekler.
  @visibleForTesting
  static Future<void> settleForTest() async => _engine?.settle();

  /// Etkin köprü (tanı ve testler için).
  @visibleForTesting
  static PlatformBridge? get bridgeForTest => _bridge;
}

class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver(this._engine, this._bridge);

  final FeralinEngine _engine;
  final PlatformBridge _bridge;

  void enterForeground() {
    unawaited(_engine.onForeground());
    _setNetwork(true);
  }

  void _setNetwork(bool enabled) {
    unawaited(
      _bridge.setNetworkListening(enabled).catchError((Object _) {
        // Ağ dinleyicisi yoksa kuyruk ön plan geçişlerinde yine boşalır.
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        enterForeground();
      case AppLifecycleState.paused:
        unawaited(_engine.onBackground());
        _setNetwork(false);
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }
}
