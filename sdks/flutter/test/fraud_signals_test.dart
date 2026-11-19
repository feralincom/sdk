import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:feralin_flutter/src/core/attribution.dart';
import 'package:feralin_flutter/src/core/engine.dart';
import 'package:feralin_flutter/src/core/event_signer.dart';
import 'package:feralin_flutter/src/core/types.dart';

import 'support.dart';

/// SDK imzası (`fr_sig`), emülatör işareti (`device_emulator`) ve mağaza yönlendiricisi kaynağı (`attribution_source`).
const SigningKey _key = SigningKey(
  id: 'sgn_0123456789abcdef',
  secret: 'fsk_gizli_anahtar_degeri',
);

String _hex(List<int> bytes) => EventSigner.hex(bytes);

Future<List<Map<String, Object?>>> _sent(Harness h, FeralinEngine sdk) async {
  await sdk.settle();
  await sdk.flush();
  await sdk.settle();
  return h.sentEvents;
}

void main() {
  group('saf Dart SHA-256 ve HMAC', () {
    test('FIPS 180-4 örnekleri ve blok sınırları', () {
      expect(
        _hex(sha256(const [])),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        _hex(sha256(utf8.encode('abc'))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        _hex(
          sha256(
            utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
            ),
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
      // Blok sınırı: 55, 56 ve 64 baytlık girdiler dolgu yolunun üç dalını sınar (değerler Swift SDK testiyle aynı).
      expect(
        _hex(sha256(List<int>.filled(55, 0x61))),
        '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
      );
      expect(
        _hex(sha256(List<int>.filled(56, 0x61))),
        'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
      );
      expect(
        _hex(sha256(List<int>.filled(64, 0x61))),
        'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb',
      );
    });

    test('RFC 4231 sınama durumu 2 ve 6', () {
      expect(
        _hex(
          hmacSha256(
            utf8.encode('Jefe'),
            utf8.encode('what do ya want for nothing?'),
          ),
        ),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
      // Blok boyundan uzun anahtar önce özetlenir.
      expect(
        _hex(
          hmacSha256(
            List<int>.filled(131, 0xaa),
            utf8.encode(
              'Test Using Larger Than Block-Size Key - Hash Key First',
            ),
          ),
        ),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
      );
    });
  });

  group('SDK imzası', () {
    String sign({
      String secret = 'fsk_gizli',
      String eventId = 'evt-1',
      String anonymousId = 'anon-1',
    }) => EventSigner.sign(
      keyId: 'sgn_0123456789abcdef',
      secret: secret,
      atSeconds: 1795000000,
      eventId: eventId,
      eventName: 'app_first_open',
      anonymousId: anonymousId,
    );

    test('imza sunucunun ürettiği değerle aynı', () {
      // Beklenen değer sunucu uygulamasıyla (Node, HMAC-SHA256) aynı girdiden hesaplandı.
      expect(
        sign(),
        'v1.sgn_0123456789abcdef.1795000000.6f939a78369f2fb6cb3aa73fcc800d17e783292a926b865e2becac05f6b6def7',
      );
    });

    test('imza olaya, kuruluma ve anahtara bağlıdır', () {
      final base = sign();
      expect(sign(eventId: 'evt-2'), isNot(base));
      expect(sign(anonymousId: 'anon-2'), isNot(base));
      expect(sign(secret: 'fsk_baska'), isNot(base));
    });

    test('anahtar biçimi denetlenir ve değeri yazılmaz', () {
      FeralinConfig config(SigningKey key) => FeralinConfig(
        projectKey: 'pk_test_unit',
        collectUrl: 'https://collect.example.com',
        signingKey: key,
      );
      expect(_key.validationError(), isNull);
      expect(config(_key).validationError(), isNull);
      for (final bad in const [
        SigningKey(id: 'anahtar', secret: 'fsk_gizli_anahtar_degeri'),
        SigningKey(id: 'sgn_KISA', secret: 'fsk_gizli_anahtar_degeri'),
        SigningKey(id: 'sgn_0123456789abcdef', secret: 'kisa'),
      ]) {
        final error = config(bad).validationError();
        expect(error, isNotNull);
        expect(error, isNot(contains(bad.secret)));
      }
      expect(
        SigningKey(
          id: 'sgn_0123456789abcdef',
          secret: 'x' * 201,
        ).validationError(),
        isNotNull,
      );
      expect('$_key', isNot(contains('fsk_')));
    });

    test(
      'yalnız ilk açılış ve link açılışı imzalanır; imza olayın kendi alanlarından doğrulanır',
      () async {
        final h = Harness();
        final sdk = await h.start(
          const Consent(analytics: true, advertising: true),
          signingKey: _key,
        );
        await sdk.settle();
        sdk.track('purchase', {'value': 1});
        await sdk.handleLink('https://go.example.com/o?fr_click=clk_1');
        final events = await _sent(h, sdk);
        expect(
          events.map((e) => e['event_name']),
          containsAll(['app_first_open', 'deep_link_opened', 'purchase']),
        );
        for (final event in events) {
          final name = event['event_name']! as String;
          final signature = propsOf(event)[EventSigner.property];
          if (name != 'app_first_open' && name != 'deep_link_opened') {
            expect(signature, isNull, reason: name);
            continue;
          }
          final seconds =
              DateTime.parse(
                event['occurred_at']! as String,
              ).millisecondsSinceEpoch ~/
              1000;
          expect(
            signature,
            EventSigner.sign(
              keyId: _key.id,
              secret: _key.secret,
              atSeconds: seconds,
              eventId: event['event_id']! as String,
              eventName: name,
              anonymousId: event['anonymous_id']! as String,
            ),
            reason: name,
          );
          expect(signature, startsWith('v1.sgn_0123456789abcdef.$seconds.'));
        }
        // Anahtar değeri gövdeye düşmez.
        for (final request in h.transport.requests) {
          expect(request.body, isNot(contains(_key.secret)));
        }
      },
    );

    test('anahtar verilmediyse imza alanı yoktur', () async {
      final h = Harness();
      final sdk = await h.start(
        const Consent(analytics: true, advertising: true),
      );
      await sdk.handleLink('https://go.example.com/o?fr_click=clk_1');
      for (final event in await _sent(h, sdk)) {
        expect(propsOf(event).containsKey(EventSigner.property), isFalse);
      }
    });
  });

  group('emülatör işareti', () {
    Future<Map<String, Object?>> firstOpen(EmulatorReader? emulator) async {
      final h = Harness();
      final sdk = await h.start(
        const Consent(analytics: true, advertising: false),
        emulator: emulator,
      );
      final first = (await _sent(
        h,
        sdk,
      )).where((e) => e['event_name'] == 'app_first_open');
      expect(first, hasLength(1));
      return propsOf(first.single);
    }

    test('yalnız true ise ilk açılışa eklenir', () async {
      expect((await firstOpen(() async => true))['device_emulator'], true);
      for (final value in <bool?>[false, null]) {
        final props = await firstOpen(() async => value);
        expect(props.containsKey('device_emulator'), isFalse);
      }
      expect((await firstOpen(null)).containsKey('device_emulator'), isFalse);
    });

    test('okuma hatası ilk açılışı durdurmaz', () async {
      final props = await firstOpen(
        () async => throw StateError('Build okunamadı'),
      );
      expect(props.containsKey('device_emulator'), isFalse);
      expect(props['attribution_source'], 'none');
    });

    test('başka olaylara eklenmez', () async {
      final h = Harness();
      final sdk = await h.start(
        const Consent(analytics: true, advertising: true),
        emulator: () async => true,
      );
      await sdk.settle();
      sdk.track('purchase', {'value': 1});
      final other = (await _sent(
        h,
        sdk,
      )).where((e) => e['event_name'] != 'app_first_open');
      expect(other, isNotEmpty);
      for (final event in other) {
        expect(propsOf(event).containsKey('device_emulator'), isFalse);
      }
    });
  });

  group('Huawei AppGallery kaynağı', () {
    const huawei = AttributionParams(
      frClick: 'clk_hw',
      utm: {'utm_source': 'petal'},
      deepLinkPath: '/urun/42',
      source: AttributionSource.huaweiInstallReferrer,
    );

    test('ilk açılış kaynağı huawei_install_referrer olur', () async {
      final h = Harness()..referrerResult = huawei;
      final sdk = await h.start(
        const Consent(analytics: true, advertising: true),
      );
      final first = (await _sent(
        h,
        sdk,
      )).firstWhere((e) => e['event_name'] == 'app_first_open');
      final props = propsOf(first);
      expect(props['attribution_source'], 'huawei_install_referrer');
      expect(props['fr_click'], 'clk_hw');
      expect(props['utm_source'], 'petal');
      expect(props.containsKey('fr_dl'), isFalse);
    });

    test('Play kanıtında kaynak play_install_referrer kalır', () async {
      final h = Harness()
        ..referrerResult = const AttributionParams(frClick: 'clk_play');
      final sdk = await h.start(
        const Consent(analytics: true, advertising: true),
      );
      final first = (await _sent(
        h,
        sdk,
      )).firstWhere((e) => e['event_name'] == 'app_first_open');
      expect(propsOf(first)['attribution_source'], 'play_install_referrer');
    });

    test('reklam ölçümü izni yoksa yönlendirici okunmaz', () async {
      final h = Harness()..referrerResult = huawei;
      final sdk = await h.start(
        const Consent(analytics: true, advertising: false),
      );
      final first = (await _sent(
        h,
        sdk,
      )).firstWhere((e) => e['event_name'] == 'app_first_open');
      expect(h.referrerReads, 0);
      expect(propsOf(first)['attribution_source'], 'none');
      expect(propsOf(first).containsKey('fr_click'), isFalse);
    });

    test('izin sonradan gelirse kanıt aynı kaynak adıyla taşınır', () async {
      final h = Harness()..referrerResult = huawei;
      final sdk = await h.start(
        const Consent(analytics: true, advertising: false),
      );
      await sdk.settle();
      sdk.setConsent(const Consent(analytics: true, advertising: true));
      final followUp = (await _sent(
        h,
        sdk,
      )).firstWhere((e) => e['event_name'] == 'deep_link_opened');
      expect(
        propsOf(followUp)['attribution_source'],
        'huawei_install_referrer',
      );
      expect(propsOf(followUp)['fr_click'], 'clk_hw');
    });
  });
}
