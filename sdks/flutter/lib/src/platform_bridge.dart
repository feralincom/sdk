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

  /// Play Install Referrer; olmayan platformda `null`.
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

  @override
  Future<AttributionParams?> readInstallReferrer() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'readInstallReferrer',
    );
    return result == null ? null : AttributionParams.fromMap(result);
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

  /// AdServices token'ını iOS yerel eklentisinden ister (`getAdServicesToken`). Eklenti bu pakette henüz yoktur
  /// (BLOCKED_EXTERNAL: macOS ve Xcode gerekir); kanal kayıtlı değilse `null` döner ve SDK dürüstçe `unsupported` der.
  @override
  Future<String?> adServicesToken() async {
    try {
      return await _channel.invokeMethod<String>('getAdServicesToken');
    } on MissingPluginException {
      return null;
    }
  }
}
