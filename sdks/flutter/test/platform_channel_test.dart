import 'dart:io';

import 'package:feralin_flutter/feralin_flutter.dart';
import 'package:feralin_flutter/src/core/attribution.dart';
import 'package:feralin_flutter/src/platform_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Yerel taraf burada sahtedir: gerçek kanal davranışı emülatör kanıtıyla ayrıca sınanır.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.feralin/flutter');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Directory dir;

  setUp(() {
    calls.clear();
    dir = Directory.systemTemp.createTempSync('feralin_channel_');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getNoBackupDir':
          return dir.path;
        case 'getAppInfo':
          return {
            'version': '3.1.4',
            'build': '7',
            'timezone': 'Europe/Istanbul',
          };
        case 'readInstallReferrer':
          return {'fr_click': 'clk_native', 'utm_source': 'ads', 'gclid': 'x'};
        case 'getInitialLink':
          return 'https://go.example.com/o?fr_click=clk_open&token=SIR';
        case 'encryptQueue':
          final args = call.arguments as Map<Object?, Object?>;
          return FakeQueueCipher.sealText(
            args['plain']! as String,
            args['aad']! as String,
          );
        case 'decryptQueue':
          final args = call.arguments as Map<Object?, Object?>;
          return FakeQueueCipher.openText(
            args['stored']! as String,
            args['aad']! as String,
          );
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await Feralin.resetForTest();
    dir.deleteSync(recursive: true);
  });

  test(
    'Android köprüsü referrer haritasını izin listesinden geçirir',
    () async {
      final bridge = AndroidPlatformBridge();
      final params = await bridge.readInstallReferrer();
      expect(params!.frClick, 'clk_native');
      expect(params.utm, {'utm_source': 'ads'});
      expect(bridge.platform, 'flutter_android');
      expect(bridge.linkSource, AttributionSource.appLink);
      expect((await bridge.storageDirectory()).path, dir.path);
      final info = await bridge.appInfo();
      expect(info.version, '3.1.4');
      expect(info.timezone, 'Europe/Istanbul');
    },
  );

  test('referrer servisi yoksa null', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await AndroidPlatformBridge().readInstallReferrer(), isNull);
  });

  test('iOS köprüsü yerel kanal kullanmaz, referrer vermez', () async {
    const bridge = IosPlatformBridge();
    expect(bridge.platform, 'flutter_ios');
    expect(bridge.linkSource, AttributionSource.universalLink);
    expect(await bridge.readInstallReferrer(), isNull);
    expect(await bridge.initialLink(), isNull);
    await bridge.setNetworkListening(true);
    expect(calls, isEmpty);
  });

  test(
    'AdServices token: iOS köprüsü kanaldan alır, eklenti yoksa null; Android null',
    () async {
      expect(await AndroidPlatformBridge().adServicesToken(), isNull);
      expect(calls, isEmpty, reason: 'Android kanalı AdServices çağırmaz');

      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'getAdServicesToken' ? 'TOKEN-DEGERI' : null;
      });
      expect(await const IosPlatformBridge().adServicesToken(), 'TOKEN-DEGERI');
      expect(calls.single.method, 'getAdServicesToken');

      // Eklenti kayıtlı değil: MissingPluginException dürüstçe null olur.
      messenger.setMockMethodCallHandler(channel, null);
      expect(await const IosPlatformBridge().adServicesToken(), isNull);

      // Apple hatası (PlatformException) çağırana ulaşır; motor bunu tokenUnavailable yapar.
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'adservices_failed');
      });
      await expectLater(
        const IosPlatformBridge().adServicesToken(),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'facade: izin yokken kanal yalnız bilgi amaçlı, referrer okunmaz',
    () async {
      final started = await Feralin.initializeForTest(
        const FeralinConfig(
          projectKey: 'pk_test_unit',
          collectUrl: 'http://127.0.0.1:9',
        ),
        AndroidPlatformBridge(),
      );
      expect(started, isTrue);
      await Feralin.settleForTest();
      expect(Feralin.track('x'), isNull);
      expect(Feralin.getStatus().initialized, isTrue);
      expect(Feralin.getStatus().queued, 0);
      expect(
        calls.map((c) => c.method),
        isNot(contains('readInstallReferrer')),
      );
      expect(Directory('${dir.path}/feralin_sdk').listSync(), isEmpty);
    },
  );

  test('facade: yaşam döngüsü ağ dinleyicisini açar ve kapatır', () async {
    await Feralin.initializeForTest(
      const FeralinConfig(
        projectKey: 'pk_test_unit',
        collectUrl: 'http://127.0.0.1:9',
      ),
      AndroidPlatformBridge(),
    );
    await Feralin.settleForTest();
    calls.clear();
    final binding = WidgetsBinding.instance;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(
      calls
          .where((c) => c.method == 'setNetworkListening')
          .map((c) => c.arguments),
      contains(false),
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(
      calls
          .where((c) => c.method == 'setNetworkListening')
          .map((c) => c.arguments)
          .last,
      isTrue,
    );
  });

  test('facade: kuyruk diske yerel şifreleme çağrısıyla ve düz metin olmadan yazılır', () async {
    await Feralin.initializeForTest(
      const FeralinConfig(
        projectKey: 'pk_test_unit',
        collectUrl: 'http://127.0.0.1:9',
        consent: Consent(analytics: true),
        autoCaptureDeepLinks: false,
      ),
      AndroidPlatformBridge(),
    );
    await Feralin.settleForTest();
    final id = Feralin.track('sifreli_olay', {'gizli_ozellik': 'sir-degeri-42'});
    await Feralin.settleForTest();
    expect(id, isNotNull);
    expect(calls.map((c) => c.method), contains('encryptQueue'));
    final text = File('${dir.path}/feralin_sdk/queue.jsonl').readAsStringSync();
    expect(text, isNot(contains('sir-degeri-42')));
    expect(text, isNot(contains('sifreli_olay')));
    expect(text, contains('"event_id":"$id"'));
    expect(text, contains('enc1:'));
  });

  test('facade başlatılmadan da fırlatmaz', () async {
    expect(Feralin.track('x'), isNull);
    expect(Feralin.screen('home'), isNull);
    Feralin.identify('u');
    await Feralin.setConsent(const Consent(analytics: true));
    await Feralin.optOut();
    await Feralin.reset();
    await Feralin.handleDeepLink(Uri.parse('https://e.com'));
    expect((await Feralin.flush()).status, 0);
    expect(Feralin.getStatus().initialized, isFalse);
  });

  test('gizli anahtar reddedilir, SDK kapalı kalır', () async {
    final started = await Feralin.initialize(
      const FeralinConfig(projectKey: 'sk_live_x', collectUrl: 'https://e.com'),
    );
    expect(started, isFalse);
    expect(Feralin.getStatus().initialized, isFalse);
  });
}
