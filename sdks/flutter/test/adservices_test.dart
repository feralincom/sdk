import 'dart:convert';

import 'package:feralin_flutter/src/core/event_store.dart';
import 'package:feralin_flutter/src/core/transport.dart';
import 'package:feralin_flutter/src/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const grantedAd = Consent(analytics: true, advertising: true);
const grantedNoAd = Consent(analytics: true, advertising: false);
const _attribution = AttributionConfig(
  apiUrl: 'https://api.example.com/',
  projectId: 'proj_1',
);
const _receipt =
    '{"id":"rec_1","status":"exchange_blocked","exchange":{"status":"BLOCKED_EXTERNAL"},"received_at":"2026-11-06T10:00:00.000Z","expires_at":"2026-11-07T10:00:00.000Z","duplicate":false}';

/// F3-E02-T02 (ADR-0007): AdServices token'ı kurulum kimliğiyle gider, kimlik müşteri sunucusuna iletilmek üzere döner;
/// iOS dışında dürüst no-op.
void main() {
  late Harness h;

  setUp(() => h = Harness());

  test(
    'iOS: token proje anahtarıyla Bearer olarak, kurulum kimliğiyle gider ve kimlik döner',
    () async {
      h.transport.responses.add(TransportResponse(202, _receipt, null));
      final sdk = await h.start(
        grantedAd,
        platform: 'flutter_ios',
        attribution: _attribution,
        adServicesToken: () async => 'QUJD' * 40,
      );
      final result = await sdk.bindInstall();

      expect(result.adServices.status, AdServicesStatus.received);
      final id = result.installId;
      expect(id, isNotNull);
      final request = h.transport.requests.single;
      expect(
        request.url,
        'https://api.example.com/v1/projects/proj_1/attribution/apple-adservices/tokens',
      );
      expect(request.headers['authorization'], 'Bearer pk_test_unit');
      expect(request.headers.containsKey('x-feralin-project-key'), isFalse);
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body, {'token': 'QUJD' * 40, 'install_id': id});
      // Kimlik kalıcıdır ve ikinci çağrıda aynıdır.
      expect(await sdk.installIdentifier(), id);
      expect(h.store.get('install_id'), id);
    },
  );

  test(
    'izin yokken token alınmaz, ağa gidilmez, kimlik üretilmez ve yazılmaz',
    () async {
      var asked = false;
      final sdk = await h.start(
        grantedNoAd,
        platform: 'flutter_ios',
        attribution: _attribution,
        adServicesToken: () async {
          asked = true;
          return 'tok';
        },
      );
      final result = await sdk.bindInstall();
      expect(result.adServices.status, AdServicesStatus.skippedNoConsent);
      expect(result.installId, isNull);
      expect(asked, isFalse);
      expect(h.transport.requests, isEmpty);
      expect(h.store.get('install_id'), isNull);
      expect(await sdk.installIdentifier(), isNull);

      final pending = await Harness().start(
        null,
        platform: 'flutter_ios',
        attribution: _attribution,
      );
      expect(
        (await pending.bindInstall()).adServices.status,
        AdServicesStatus.skippedNoConsent,
      );
    },
  );

  test(
    'Android ve iOS yerel köprüsü yokken unsupported: ağ yok, kimlik yok',
    () async {
      final android = await h.start(
        grantedAd,
        attribution: _attribution,
        adServicesToken: () async => 'tok',
      );
      final first = await android.bindInstall();
      expect(first.adServices.status, AdServicesStatus.unsupported);
      expect(first.installId, isNull);
      expect(await android.installIdentifier(), isNull);

      final h2 = Harness();
      final ios = await h2.start(
        grantedAd,
        platform: 'flutter_ios',
        attribution: _attribution,
        adServicesToken: () async => null,
      );
      final second = await ios.bindInstall();
      expect(second.adServices.status, AdServicesStatus.unsupported);
      expect(h2.transport.requests, isEmpty);
    },
  );

  test(
    'attribution yapılandırması yoksa notConfigured, token okunmaz; kimlik hesap bağı için yine döner',
    () async {
      var asked = false;
      final sdk = await h.start(
        grantedAd,
        platform: 'flutter_ios',
        adServicesToken: () async {
          asked = true;
          return 'tok';
        },
      );
      final result = await sdk.bindInstall();
      expect(result.adServices.status, AdServicesStatus.notConfigured);
      expect(result.installId, isNotNull);
      expect(asked, isFalse);
      expect(h.transport.requests, isEmpty);
    },
  );

  test('token okunamazsa tokenUnavailable, sunucu hataları eşlenir', () async {
    final broken = await h.start(
      grantedAd,
      platform: 'flutter_ios',
      attribution: _attribution,
      adServicesToken: () async => throw StateError('apple'),
    );
    final first = await broken.bindInstall();
    expect(first.adServices.status, AdServicesStatus.tokenUnavailable);
    expect(first.installId, isNotNull);
    expect(h.transport.requests, isEmpty);

    Future<AdServicesSubmission> post(TransportResponse? response) async {
      final local = Harness();
      local.transport.responses.add(response);
      final sdk = await local.start(
        grantedAd,
        platform: 'flutter_ios',
        attribution: _attribution,
        adServicesToken: () async => 'tok',
      );
      return (await sdk.bindInstall()).adServices;
    }

    final rejected = await post(
      TransportResponse(400, '{"title":"Token geçersiz"}', null),
    );
    expect(rejected.status, AdServicesStatus.rejected);
    expect(rejected.httpStatus, 400);
    expect(rejected.detail, 'Token geçersiz');
    expect(
      (await post(TransportResponse(429, '', null))).status,
      AdServicesStatus.temporaryFailure,
    );
    expect(
      (await post(TransportResponse(503, 'x', null))).status,
      AdServicesStatus.temporaryFailure,
    );
    expect((await post(null)).status, AdServicesStatus.temporaryFailure);
  });

  test('izin geri çekilince ve reset ile kurulum kimliği silinir', () async {
    final sdk = await h.start(
      grantedAd,
      platform: 'flutter_ios',
      attribution: _attribution,
    );
    final id = await sdk.installIdentifier();
    expect(id, isNotNull);
    expect(h.store.get('install_id'), id);

    await sdk.reset();
    await sdk.settle();
    expect(h.store.get('install_id'), isNull);
    final renewed = await sdk.installIdentifier();
    expect(renewed, isNotNull);
    expect(renewed, isNot(id));

    await sdk.setConsent(const Consent(analytics: false));
    await sdk.settle();
    expect(h.store.get('install_id'), isNull);
    expect(await sdk.installIdentifier(), isNull);
  });

  test('yapılandırma doğrulaması: geçersiz attribution adresi reddedilir', () {
    expect(
      const FeralinConfig(
        projectKey: 'pk_test_unit',
        collectUrl: 'https://collect.example.com',
        attribution: AttributionConfig(apiUrl: 'ftp://x', projectId: 'p'),
      ).validationError(),
      isNotNull,
    );
    expect(
      const FeralinConfig(
        projectKey: 'pk_test_unit',
        collectUrl: 'https://collect.example.com',
        attribution: AttributionConfig(
          apiUrl: 'https://a.example',
          projectId: ' ',
        ),
      ).validationError(),
      isNotNull,
    );
    expect(
      const FeralinConfig(
        projectKey: 'pk_test_unit',
        collectUrl: 'https://collect.example.com',
        attribution: _attribution,
      ).validationError(),
      isNull,
    );
  });

  test(
    'önceden kayıtlı kimlik yeniden başlatmada okunur (kalıcı depo)',
    () async {
      final store = MemoryEventStore();
      await store.put('install_id', '01KALICIKIMLIK');
      h.store = store;
      final sdk = await h.start(
        grantedAd,
        platform: 'flutter_ios',
        attribution: _attribution,
      );
      expect(await sdk.installIdentifier(), '01KALICIKIMLIK');
    },
  );
}
