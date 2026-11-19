import 'dart:convert';

import 'package:feralin_flutter/src/core/short_links.dart';
import 'package:feralin_flutter/src/core/transport.dart';
import 'package:feralin_flutter/src/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const grantedAd = Consent(analytics: true, advertising: true);
const grantedNoAd = Consent(analytics: true, advertising: false);
const denied = Consent(analytics: false);

const _click = 'clk_AbCdEfGh12345678';

String _body({
  String code = 'kampanya',
  String? path = '/urun/42',
  String? click = _click,
  Map<String, String> utm = const {'campaign': 'yaz', 'source': 'ig'},
}) => jsonEncode({
  'code': code,
  'destination': 'https://apps.apple.com/app/id1',
  'deep_link_path': path,
  'utm': utm,
  'click_id': click,
  'rule': 'ios_url',
});

class _Recorder {
  _Recorder(this.response);

  final TransportResponse? response;
  final List<(String, Map<String, String>)> calls = [];

  Future<TransportResponse?> call(
    String url,
    Map<String, String> headers,
  ) async {
    calls.add((url, headers));
    return response;
  }
}

Future<void> _flush(dynamic sdk) async {
  await sdk.settle();
  await sdk.flush();
  await sdk.settle();
}

void main() {
  group('ShortLinks yardımcıları', () {
    test('yalnız https ve listedeki host ya da alt alanı kısa linktir', () {
      const hosts = ['fera.fly'];
      expect(ShortLinks.isShortLink('https://fera.fly/abc', hosts), isTrue);
      expect(
        ShortLinks.isShortLink('https://marka.fera.fly/abc', hosts),
        isTrue,
      );
      expect(ShortLinks.isShortLink('https://FERA.FLY/abc', hosts), isTrue);
      expect(ShortLinks.isShortLink('http://fera.fly/abc', hosts), isFalse);
      expect(
        ShortLinks.isShortLink('https://sahtefera.fly/abc', hosts),
        isFalse,
      );
      expect(
        ShortLinks.isShortLink('https://fera.fly.kotu.com/abc', hosts),
        isFalse,
      );
      expect(ShortLinks.isShortLink(null, hosts), isFalse);
      expect(ShortLinks.isShortLink('https://fera.fly/abc', const []), isFalse);
    });

    test('başlıklar cihaz sınıfını verir, izin yoksa kanıt kapatılır', () {
      final ios = ShortLinks.headers(ios: true, attribution: true);
      expect(ios['Accept'], 'application/vnd.feralin.link+json');
      expect(ios['User-Agent'], contains('iPhone'));
      expect(ios.containsKey('Feralin-Attribution'), isFalse);
      final android = ShortLinks.headers(ios: false, attribution: false);
      expect(android['User-Agent'], contains('Android'));
      expect(android['Feralin-Attribution'], 'off');
    });

    test('yanıt çözülür; bozuk alanlar düşürülür', () {
      final ok = ShortLinks.parse(_body())!;
      expect(ok.code, 'kampanya');
      expect(ok.deepLinkPath, '/urun/42');
      expect(ok.clickId, _click);
      expect(ok.utm, {'campaign': 'yaz', 'source': 'ig'});

      final bad = ShortLinks.parse(
        jsonEncode({
          'code': 'k1',
          'deep_link_path': '//kotu.com/x',
          'click_id': 'kısa',
          'utm': {'campaign': 'yaz', 'email': 'a@b.c'},
        }),
      )!;
      expect(bad.deepLinkPath, isNull);
      expect(bad.clickId, isNull);
      expect(bad.utm, {'campaign': 'yaz'});

      expect(ShortLinks.parse('<html>'), isNull);
      expect(ShortLinks.parse('[]'), isNull);
      expect(ShortLinks.parse(jsonEncode({'code': ''})), isNull);
      expect(ShortLinks.parse(jsonEncode({'code': '../x'})), isNull);
    });

    test('sentetik adres aynı host, derin yol, fr_click ve utm taşır', () {
      final url = ShortLinks.syntheticUrl(
        'https://marka.fera.fly/kampanya?gizli=1',
        ShortLinks.parse(_body())!,
      );
      expect(
        url,
        'https://marka.fera.fly/urun/42?fr_click=$_click&utm_campaign=yaz&utm_source=ig',
      );
      final noPath = ShortLinks.syntheticUrl(
        'https://fera.fly/k',
        ShortLinks.parse(_body(path: null, click: null, utm: const {}))!,
      );
      expect(noPath, 'https://fera.fly/');
    });
  });

  group('motor kısa link akışı', () {
    late Harness h;
    setUp(() => h = Harness());

    test('kısa link çözümlenir, olay tıklama kimliği ve UTM taşır', () async {
      final fetch = _Recorder(TransportResponse(200, _body(), null));
      final sdk = await h.start(
        grantedAd,
        platform: 'flutter_ios',
        linkSource: 'universal_link',
        shortLinkFetcher: fetch.call,
      );
      await _flush(sdk);
      h.transport.requests.clear();

      final resolved = await sdk.handleLink('https://marka.fera.fly/kampanya');
      await _flush(sdk);

      expect(resolved?.code, 'kampanya');
      expect(resolved?.deepLinkPath, '/urun/42');
      expect(sdk.lastShortLink?.code, 'kampanya');
      expect(fetch.calls.single.$1, 'https://marka.fera.fly/kampanya');
      expect(fetch.calls.single.$2['User-Agent'], contains('iPhone'));
      expect(fetch.calls.single.$2.containsKey('Feralin-Attribution'), isFalse);
      final event = h.sentEvents.single;
      expect(event['event_name'], 'deep_link_opened');
      expect(propsOf(event)['fr_click'], _click);
      expect(propsOf(event)['utm_campaign'], 'yaz');
      expect(propsOf(event)['attribution_source'], 'universal_link');
      expect(
        (event['context']! as Map)['page_url'],
        'https://marka.fera.fly/urun/42',
      );
    });

    test('reklam izni yoksa kanıt istenmez ve gönderilmez', () async {
      final fetch = _Recorder(TransportResponse(200, _body(), null));
      final sdk = await h.start(grantedNoAd, shortLinkFetcher: fetch.call);
      await _flush(sdk);
      h.transport.requests.clear();

      await sdk.handleLink('https://fera.fly/kampanya');
      await _flush(sdk);

      expect(fetch.calls.single.$2['Feralin-Attribution'], 'off');
      expect(fetch.calls.single.$2['User-Agent'], contains('Android'));
      final event = h.sentEvents.single;
      expect(propsOf(event).containsKey('fr_click'), isFalse);
      expect(propsOf(event)['attribution_source'], 'none');
    });

    test('analitik izni yoksa istek yapılmaz, olay üretilmez', () async {
      final fetch = _Recorder(TransportResponse(200, _body(), null));
      final sdk = await h.start(denied, shortLinkFetcher: fetch.call);
      final resolved = await sdk.handleLink('https://fera.fly/kampanya');
      await _flush(sdk);
      expect(resolved, isNull);
      expect(fetch.calls, isEmpty);
      expect(h.sentNames, isNot(contains('deep_link_opened')));
    });

    test('izin henüz yoksa istek yapılmaz', () async {
      final fetch = _Recorder(TransportResponse(200, _body(), null));
      final sdk = await h.start(null, shortLinkFetcher: fetch.call);
      await sdk.handleLink('https://fera.fly/kampanya');
      await sdk.settle();
      expect(fetch.calls, isEmpty);
    });

    test(
      'adreste fr_click varsa ya da host kısa alan değilse çözümleme yok',
      () async {
        final fetch = _Recorder(TransportResponse(200, _body(), null));
        final sdk = await h.start(grantedAd, shortLinkFetcher: fetch.call);
        await sdk.handleLink('https://fera.fly/urun?fr_click=$_click');
        await sdk.handleLink('https://go.example.com/kampanya');
        await _flush(sdk);
        expect(fetch.calls, isEmpty);
        expect(h.sentNames.where((n) => n == 'deep_link_opened').length, 2);
      },
    );

    test('çözümleme başarısızsa adres olduğu gibi tek kez sayılır', () async {
      for (final response in [
        null,
        const TransportResponse(404, '{}', null),
        const TransportResponse(200, '<html>', null),
      ]) {
        final local = Harness();
        final fetch = _Recorder(response);
        final sdk = await local.start(grantedAd, shortLinkFetcher: fetch.call);
        await _flush(sdk);
        local.transport.requests.clear();
        final resolved = await sdk.handleLink('https://fera.fly/kampanya');
        await _flush(sdk);
        expect(resolved, isNull);
        final event = local.sentEvents.single;
        expect(event['event_name'], 'deep_link_opened');
        expect(
          (event['context']! as Map)['page_url'],
          'https://fera.fly/kampanya',
        );
      }
    });

    test('çözümleyici fırlatırsa uygulamaya sızmaz', () async {
      final sdk = await h.start(
        grantedAd,
        shortLinkFetcher: (url, headers) async => throw StateError('ağ'),
      );
      final resolved = await sdk.handleLink('https://fera.fly/kampanya');
      await _flush(sdk);
      expect(resolved, isNull);
      expect(h.sentNames, contains('deep_link_opened'));
    });

    test('markalı alan listeye eklenince çözümlenir', () async {
      final fetch = _Recorder(TransportResponse(200, _body(), null));
      final sdk = await h.start(
        grantedAd,
        shortLinkFetcher: fetch.call,
        shortLinkHosts: const ['fera.fly', 'go.marka.com'],
      );
      await sdk.handleLink('https://go.marka.com/kampanya');
      await sdk.settle();
      expect(fetch.calls.single.$1, 'https://go.marka.com/kampanya');
    });
  });
}
