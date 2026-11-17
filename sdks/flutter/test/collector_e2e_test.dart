@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:feralin_flutter/src/core/attribution.dart';
import 'package:feralin_flutter/src/core/engine.dart';
import 'package:feralin_flutter/src/core/event_json.dart';
import 'package:feralin_flutter/src/core/event_store.dart';
import 'package:feralin_flutter/src/core/idempotency.dart';
import 'package:feralin_flutter/src/core/transport.dart';
import 'package:feralin_flutter/src/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingTransport implements Transport {
  _CountingTransport(this._inner);

  final Transport _inner;
  int calls = 0;

  @override
  Future<TransportResponse?> post(
    String url,
    Map<String, String> headers,
    String body,
  ) {
    calls++;
    return _inner.post(url, headers, body);
  }
}

/// Gerçek `services/collect` ile uçtan uca. Yalnız FERALIN_E2E_COLLECT_URL ve FERALIN_E2E_PROJECT_KEY tanımlıysa
/// koşar; yoksa atlanır ve bu atlanma "doğrulandı" sayılmaz. Çalıştırma: sdks/flutter/scripts/e2e-collect.sh
///
/// Veritabanı paylaşımlıdır: başka bir süreç aynı anda satır yazabilir veya yayımlayabilir. Bu yüzden testler sayaç
/// farkına bakmaz; kendi batch_id ve event_id değerlerini denetim dosyasına yazar, betik satır bazında doğrular.
void main() {
  final url = Platform.environment['FERALIN_E2E_COLLECT_URL'] ?? '';
  final key = Platform.environment['FERALIN_E2E_PROJECT_KEY'] ?? '';
  final skip = url.isEmpty || key.isEmpty
      ? 'FERALIN_E2E_COLLECT_URL/FERALIN_E2E_PROJECT_KEY tanımlı değil'
      : null;
  final referrerWithClick = AttributionParams.parseQuery(
    'fr_click=e2e_click_flutter_0000001&utm_source=e2e&gclid=atilmali',
  );

  void record(String line) {
    Directory('build/e2e').createSync(recursive: true);
    File(
      'build/e2e/flutter-outbox-checks.txt',
    ).writeAsStringSync('$line\n', mode: FileMode.append);
  }

  Future<FeralinEngine> engine(
    Consent? consent, {
    EventStore? store,
    Transport? transport,
    String projectKey = '',
    String platform = 'flutter_android',
    String linkSource = AttributionSource.appLink,
    AttributionParams? referrer,
  }) async {
    final created = FeralinEngine(
      config: FeralinConfig(
        projectKey: projectKey.isEmpty ? key : projectKey,
        collectUrl: url,
        consent: consent,
      ),
      platform: platform,
      linkSource: linkSource,
      openStore: () async => store ?? MemoryEventStore(),
      transport: transport ?? IoHttpTransport(),
      referrer: () async => referrer,
      appContext: () => const AppContext(
        locale: 'tr-TR',
        timezone: 'Europe/Istanbul',
        appVersion: '0.1.0',
        appBuild: '1',
      ),
    );
    await created.start();
    await created.settle();
    return created;
  }

  Future<Map<String, Object?>> getStats() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$url/v1/stats'));
      final response = await request.close();
      return jsonDecode(await utf8.decodeStream(response))
          as Map<String, Object?>;
    } finally {
      client.close(force: true);
    }
  }

  Future<(int, Map<String, Object?>)> rawBatch(
    String body,
    String idempotencyKey,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$url/v1/batch'));
      request.headers
        ..set('content-type', 'application/json')
        ..set('x-feralin-project-key', key)
        ..set('idempotency-key', idempotencyKey);
      request.write(body);
      final response = await request.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decodeStream(response)) as Map<String, Object?>,
      );
    } finally {
      client.close(force: true);
    }
  }

  test('reklam izniyle fr_click outboxa yazılır', () async {
    expect((await getStats())['outbox'], 'postgres');
    final store = MemoryEventStore();
    final sdk = await engine(
      const Consent(analytics: true, advertising: true),
      store: store,
      referrer: referrerWithClick,
    );
    final eventId = sdk.track('e2e_flutter_purchase', {
      'amount': 12.5,
      'currency': 'TRY',
    });
    expect(eventId, isNotNull);
    await sdk.handleLink(
      'https://go.example.com/o/e2e?fr_click=e2e_click_flutter_link001&utm_campaign=yaz&token=GIZLI',
    );
    await sdk.settle();
    final result = await sdk.flush();
    await sdk.settle();
    expect(result.status, 202);
    expect(result.sent, 3);
    expect(result.accepted, 3);
    expect(result.batchId, isNotNull);
    expect(store.size, 0);
    record('frclick ${result.batchId}');
  }, skip: skip);

  test('yalnız analitik izniyle fr_click gitmez', () async {
    final store = MemoryEventStore();
    final sdk = await engine(
      const Consent(analytics: true),
      store: store,
      referrer: referrerWithClick,
    );
    await sdk.handleLink(
      'https://go.example.com/o/e2e?fr_click=e2e_click_flutter_noad001&token=GIZLI',
    );
    await sdk.settle();
    final result = await sdk.flush();
    await sdk.settle();
    expect(result.status, 202);
    expect(result.accepted, 2);
    record('nofrclick ${result.batchId}');
  }, skip: skip);

  test('izin sonradan gelirse kanıt ayrı olayla gider', () async {
    final store = MemoryEventStore();
    final sdk = await engine(
      const Consent(analytics: true),
      store: store,
      referrer: referrerWithClick,
    );
    final first = await sdk.flush();
    await sdk.settle();
    expect(first.status, 202);
    record('nofrclick ${first.batchId}');
    await sdk.setConsent(const Consent(analytics: true, advertising: true));
    await sdk.settle();
    final second = await sdk.flush();
    await sdk.settle();
    expect(second.status, 202);
    expect(second.accepted, 1);
    record('frclick ${second.batchId}');
  }, skip: skip);

  test('iOS değerleriyle kanıtsız ilk açılış kabul edilir', () async {
    final sdk = await engine(
      const Consent(analytics: true, advertising: true),
      platform: 'flutter_ios',
      linkSource: AttributionSource.universalLink,
    );
    await sdk.handleLink(
      'https://go.example.com/u?fr_click=e2e_click_flutter_ios0001',
    );
    await sdk.settle();
    final result = await sdk.flush();
    await sdk.settle();
    expect(result.status, 202);
    expect(result.accepted, 2);
    expect(result.rejected, 0);
    record('frclick ${result.batchId}');
  }, skip: skip);

  test('izinsiz olay için hiç istek yapılmaz', () async {
    for (final consent in [null, const Consent(analytics: false)]) {
      final transport = _CountingTransport(IoHttpTransport());
      final sdk = await engine(consent, transport: transport);
      expect(sdk.track('e2e_no_consent', null), isNull);
      expect((await sdk.flush()).status, 0);
      await sdk.settle();
      expect(transport.calls, 0);
    }
  }, skip: skip);

  test('sunucu izinsiz olayı reddeder', () async {
    final id = '01JE2EDARTNO${DateTime.now().millisecondsSinceEpoch}';
    final body = jsonEncode({
      'events': [
        {
          'event_id': id,
          'event_name': 'e2e_denied',
          'occurred_at': formatTime(DateTime.now().millisecondsSinceEpoch),
          'platform': 'flutter_android',
          'schema_version': 1,
          'consent': {'analytics': false},
        },
      ],
    });
    final (status, json) = await rawBatch(body, idempotencyKeyFor([id]));
    expect(status, 202);
    expect(json['accepted'], 0);
    expect(json['rejected'], 1);
    expect((json['rejected_reasons']! as Map)['consent_denied'], 1);
    record('absent $id');
  }, skip: skip);

  test('yanlış anahtar kalıcı rettir, olaylar atılır', () async {
    final store = MemoryEventStore();
    final sdk = await engine(
      const Consent(analytics: true),
      store: store,
      projectKey: 'pk_test_yanlis_anahtar',
    );
    final result = await sdk.flush();
    await sdk.settle();
    expect(result.status, 401);
    expect(store.size, 0);
  }, skip: skip);
}
