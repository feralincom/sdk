import 'package:flutter_test/flutter_test.dart';

import 'package:feralin_flutter/src/core/engine.dart';
import 'package:feralin_flutter/src/core/types.dart';

import 'support.dart';

/// Meta Install Referrer: Facebook App ID verildiyse ve reklam ölçümü izni açıksa ilk açılışa şifreli zarf eklenir; izin yoksa okunmaz.
Future<void> flushNow(FeralinEngine sdk) async {
  await sdk.flush();
  await sdk.settle();
}

void main() {
  late Harness h;
  setUp(() => h = Harness());

  test(
    'izinli ilk açılışa Meta zarfı eklenir, App ID sağlayıcıya gider',
    () async {
      String? askedFor;
      final sdk = await h.start(
        const Consent(analytics: true, advertising: true),
        metaAppId: '1234567890',
        metaReferrer: (appId) async {
          askedFor = appId;
          return '{"r":"x","p":"instagram"}';
        },
      );
      await sdk.settle();
      await flushNow(sdk);
      final first = h.sentEvents.firstWhere(
        (e) => e['event_name'] == 'app_first_open',
      );
      expect(
        propsOf(first)['meta_install_referrer'],
        '{"r":"x","p":"instagram"}',
      );
      expect(askedFor, '1234567890');
    },
  );

  test('reklam ölçümü izni yoksa ya da App ID yoksa okunmaz', () async {
    var reads = 0;
    final sdk = await h.start(
      const Consent(analytics: true, advertising: false),
      metaAppId: '1234567890',
      metaReferrer: (_) async {
        reads++;
        return 'x';
      },
    );
    await sdk.settle();
    await flushNow(sdk);
    final first = h.sentEvents.firstWhere(
      (e) => e['event_name'] == 'app_first_open',
    );
    expect(propsOf(first).containsKey('meta_install_referrer'), isFalse);
    expect(reads, 0);

    final h2 = Harness();
    final sdk2 = await h2.start(
      const Consent(analytics: true, advertising: true),
      metaReferrer: (_) async => 'x',
    );
    await sdk2.settle();
    await flushNow(sdk2);
    expect(
      propsOf(
        h2.sentEvents.firstWhere((e) => e['event_name'] == 'app_first_open'),
      ).containsKey('meta_install_referrer'),
      isFalse,
    );
  });
}
