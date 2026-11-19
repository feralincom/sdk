import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/attribution.dart';
import 'core/queue_cipher.dart';

/// Yerel uygulama bilgisi. Cihaz modeli, işletim sistemi sürümü veya donanım kimliği taşımaz.
class NativeAppInfo {
  const NativeAppInfo({this.version, this.build, this.timezone});

  final String? version;
  final String? build;
  final String? timezone;
}

/// Yerel eklentiye (`com.feralin/flutter`) `encryptQueue` ve `decryptQueue` çağrıları atar. Kanal kayıtlı değilse ya da yerel taraf
/// hata verirse sonuç `null` olur; ayrıntı (anahtar, düz metin) hiçbir yere yazılmaz.
class PlatformQueueCipher implements QueueCipher {
  /// Kanal testte sahtelenebilir.
  PlatformQueueCipher({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.feralin/flutter');

  final MethodChannel _channel;

  @override
  Future<String?> encrypt(String plain, String aad) async {
    try {
      final result = await _channel.invokeMethod<String>('encryptQueue', {
        'plain': plain,
        'aad': aad,
      });
      return result != null && result.startsWith(QueueCipher.prefix)
          ? result
          : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<String?> decrypt(String stored, String aad) async {
    try {
      return await _channel.invokeMethod<String>('decryptQueue', {
        'stored': stored,
        'aad': aad,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// Platform farkları bu sınırın arkasındadır.
abstract class PlatformBridge {
  /// UTP `platform` değeri.
  String get platform;

  /// Bu platformdaki bağlantı kanıtının adı.
  String get linkSource;

  /// Kalıcı depo dizini.
  Future<Directory> storageDirectory();

  /// Kuyruk gövdelerini şifreleyen yerel sınır (Android Keystore, iOS Keychain). Anahtar yerel tarafta kalır.
  QueueCipher get queueCipher;

  /// Mağaza kurulum yönlendiricisi (Play, kanıt vermezse Huawei AppGallery); olmayan platformda `null`.
  Future<AttributionParams?> readInstallReferrer();

  Future<NativeAppInfo> appInfo();

  /// Uygulamayı açan bağlantı; yoksa `null`.
  Future<String?> initialLink();

  /// Yerel taraftan gelen çağrıları bağlar.
  void listen({
    required void Function(String url) onLink,
    required void Function() onNetworkAvailable,
  });

  /// Ağ dinleyicisi yalnız ön plandayken açık kalır.
  Future<void> setNetworkListening(bool enabled);

  /// iOS AdServices token'ı; yerel köprü ya da platform desteği yoksa `null`. Apple hatasında fırlatır.
  Future<String?> adServicesToken();

  /// Meta Install Referrer zarfı (yalnız Android); yoksa `null`.
  Future<String?> metaInstallReferrer(String appId);

  /// Kurulum mağazası sınıfı (yalnız Android; kapalı liste, paket adı değil); yoksa `null`.
  Future<String?> installStore();

  /// Uygulama emülatörde mi (yalnız Android, sezgisel); bilinmiyorsa `null`.
  Future<bool?> isEmulator();
}

/// Android: yerel eklenti (`FeralinFlutterPlugin`) üzerinden Play Install Referrer ve App Links.
class AndroidPlatformBridge implements PlatformBridge {
  AndroidPlatformBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.feralin/flutter');

  final MethodChannel _channel;

  @override
  String get platform => 'flutter_android';

  @override
  String get linkSource => AttributionSource.appLink;

  @override
  QueueCipher get queueCipher => PlatformQueueCipher(channel: _channel);

  @override
  Future<Directory> storageDirectory() async {
    // Yedekleme dışı dizin: Auto Backup yeni kuruluma ilk açılış işareti veya anonim kimlik taşımaz.
    final path = await _channel.invokeMethod<String>('getNoBackupDir');
    if (path != null && path.isNotEmpty) return Directory(path);
    return getApplicationSupportDirectory();
  }

  /// Mağaza yönlendiricisi zinciri (Android SDK `StoreReferrerChain` ile aynı): önce Google Play okunur; Play kanıt vermezse
  /// (hizmet yok, organik varsayılan ya da boş) AppGallery'ye sorulur. İkisi de kanıt vermezse Play sonucu korunur.
  @override
  Future<AttributionParams?> readInstallReferrer() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'readInstallReferrer',
    );
    final play = result == null ? null : AttributionParams.fromMap(result);
    if (play != null && !play.isEmpty && !play.isPlayOrganicDefault) {
      return play;
    }
    return await _readHuaweiInstallReferrer() ?? play;
  }

  /// Yerel eklenti AppGallery içerik sağlayıcısının yalnız `referrer` sütununu okur ve izin listesinden geçirir. Okuma hatası ya da
  /// eski eklenti kanıt yok sayılır.
  Future<AttributionParams?> _readHuaweiInstallReferrer() async {
    final Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'readHuaweiInstallReferrer',
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
    if (result == null) return null;
    final params = AttributionParams.fromMap(result);
    return params.isEmpty
        ? null
        : params.withSource(AttributionSource.huaweiInstallReferrer);
  }

  @override
  Future<NativeAppInfo> appInfo() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getAppInfo',
    );
    return NativeAppInfo(
      version: result?['version'] as String?,
      build: result?['build'] as String?,
      timezone: result?['timezone'] as String?,
    );
  }

  @override
  Future<String?> initialLink() =>
      _channel.invokeMethod<String>('getInitialLink');

  @override
  void listen({
    required void Function(String url) onLink,
    required void Function() onNetworkAvailable,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onLink':
          final url = call.arguments;
          if (url is String) onLink(url);
        case 'onNetworkAvailable':
          onNetworkAvailable();
      }
    });
  }

  @override
  Future<void> setNetworkListening(bool enabled) =>
      _channel.invokeMethod<void>('setNetworkListening', enabled);

  // Android kuruluma Play Install Referrer ile bağlanır; AdServices yoktur.
  @override
  Future<String?> adServicesToken() async => null;

  /// Yerel eklenti Facebook, Instagram ve Facebook Lite sağlayıcılarını sorgular; eski eklentide kanal yoksa `null`.
  @override
  Future<String?> metaInstallReferrer(String appId) async {
    try {
      return await _channel.invokeMethod<String>('readMetaInstallReferrer', {'appId': appId});
    } on MissingPluginException {
      return null;
    }
  }

  /// Yerel eklenti kurucu paketi okur ve sınıflar; eski eklentide kanal yoksa `null` (alan eklenmez).
  @override
  Future<String?> installStore() async {
    try {
      return await _channel.invokeMethod<String>('getInstallStore');
    } on MissingPluginException {
      return null;
    }
  }

  /// Yerel eklenti `Build` alanlarını sınıflar ve yalnız evet/hayır döner; eski eklentide kanal yoksa `null` (alan eklenmez).
  @override
  Future<bool?> isEmulator() async {
    try {
      return await _channel.invokeMethod<bool>('isEmulator');
    } on MissingPluginException {
      return null;
    }
  }
}

/// iOS: yerel kod yoktur. Referrer yoktur (`none`); evrensel bağlantıyı uygulama `handleDeepLink` ile verir.
class IosPlatformBridge implements PlatformBridge {
  const IosPlatformBridge({
    MethodChannel channel = const MethodChannel('com.feralin/flutter'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  String get platform => 'flutter_ios';

  @override
  String get linkSource => AttributionSource.universalLink;

  @override
  QueueCipher get queueCipher => PlatformQueueCipher(channel: _channel);

  @override
  Future<Directory> storageDirectory() => getApplicationSupportDirectory();

  @override
  Future<AttributionParams?> readInstallReferrer() async => null;

  @override
  Future<NativeAppInfo> appInfo() async => const NativeAppInfo();

  @override
  Future<String?> initialLink() async => null;

  @override
  void listen({
    required void Function(String url) onLink,
    required void Function() onNetworkAvailable,
  }) {}

  @override
  Future<void> setNetworkListening(bool enabled) async {}

  /// AdServices token'ını iOS yerel eklentisinden ister (`getAdServicesToken`, ios/Classes/FeralinFlutterPlugin.swift). Eski eklenti
  /// sürümünde kanal kayıtlı değilse `null` döner ve SDK dürüstçe `unsupported` der. Mac'te derleme ve cihaz testi docs/MAC_GOREVLERI.md.
  @override
  Future<String?> adServicesToken() async {
    try {
      return await _channel.invokeMethod<String>('getAdServicesToken');
    } on MissingPluginException {
      return null;
    }
  }

  /// iOS'ta Meta Install Referrer yoktur (Meta yalnız Android sağlayıcısı sunar).
  @override
  Future<String?> metaInstallReferrer(String appId) async => null;

  /// iOS'ta kurulum mağazası okunmaz.
  @override
  Future<String?> installStore() async => null;

  /// iOS'ta emülatör işareti üretilmez.
  @override
  Future<bool?> isEmulator() async => null;
}
