import 'package:feralin_flutter/src/core/attribution.dart';
import 'package:feralin_flutter/src/core/engine.dart';
import 'package:feralin_flutter/src/core/event_store.dart';
import 'package:feralin_flutter/src/core/idempotency.dart';
import 'package:feralin_flutter/src/core/transport.dart';
import 'package:feralin_flutter/src/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const granted = Consent(analytics: true);
const grantedAd = Consent(analytics: true, advertising: true);
const grantedNoAd = Consent(analytics: true, advertising: false);
const denied = Consent(analytics: false);

class _ThrowingTransport implements Transport {
  @override
  Future<TransportResponse?> post(
    String url,
    Map<String, String> headers,
    String body,
  ) => throw StateError('beklenmeyen');
}

void main() {
  late Harness h;

  setUp(() => h = Harness());

  Future<FlushResult> flushNow(FeralinEngine sdk) async {
    final result = await sdk.flush();
    await sdk.settle();
    return result;
  }

  group('izin', () {
    test('izin bekleniyorken olay üretilmez ve referrer okunmaz', () async {
      final sdk = await h.start(null);
      expect(sdk.track('purchase', null), isNull);
      await sdk.settle();
      expect(h.store.size, 0);
      expect(h.referrerReads, 0);
      expect(h.store.get('anonymous_id'), isNull);
      expect((await flushNow(sdk)).status, 0);
      expect(h.transport.requests, isEmpty);
    });

    test('izin bekleniyorken depodaki kuyruk silinmez, onayda gider', () async {
      await h.store.add(
        const StoredEvent(
          '01OLDEVENT00000000000000000',
          '{"event_id":"01OLDEVENT00000000000000000"}',
        ),
        10,
      );
      final sdk = await h.start(null);
      await flushNow(sdk);
      expect(h.store.size, 1);
      expect(h.transport.requests, isEmpty);
      await sdk.setConsent(granted);
      await sdk.settle();
      await flushNow(sdk);
      expect(
        h.sentEvents.any((e) => e['event_id'] == '01OLDEVENT00000000000000000'),
        isTrue,
      );
    });

    test('ret kuyruk ve kimliği siler, sonraki olay üretilmez', () async {
      final sdk = await h.start(granted);
      sdk.track('a', null);
      await sdk.settle();
      expect(h.store.size, greaterThan(0));
      expect(h.store.get('anonymous_id'), isNotNull);
      await sdk.setConsent(denied);
      await sdk.settle();
      expect(h.store.size, 0);
      expect(sdk.status().queued, 0);
      expect(h.store.get('anonymous_id'), isNull);
      expect(sdk.track('b', null), isNull);
      await flushNow(sdk);
      expect(h.transport.requests, isEmpty);
    });

    test('açılışta bilinen ret kuyruğu siler', () async {
      await h.store.add(
        const StoredEvent('01OLDEVENT00000000000000000', '{}'),
        10,
      );
      await h.store.put('anonymous_id', 'eski');
      await h.start(denied);
      expect(h.store.size, 0);
      expect(h.store.get('anonymous_id'), isNull);
    });
  });

  group('ilk açılış', () {
    test('kurulum başına bir kez', () async {
      final first = await h.start(grantedAd);
      await flushNow(first);
      expect(h.sentNames, ['app_first_open']);
      expect(h.referrerReads, 1);
      final second = await h.start(grantedAd);
      second.track('second_run', null);
      await second.settle();
      await flushNow(second);
      expect(h.sentNames, ['app_first_open', 'second_run']);
      expect(h.referrerReads, 1);
    });

    test(
      'izin sonrasına ertelenir, ret-onay döngüsünde tekrarlanmaz',
      () async {
        final sdk = await h.start(null);
        await sdk.setConsent(denied);
        await sdk.settle();
        expect(h.referrerReads, 0);
        expect(h.store.get('first_open_done'), isNull);
        await sdk.setConsent(granted);
        await sdk.settle();
        await flushNow(sdk);
        await sdk.setConsent(denied);
        await sdk.setConsent(granted);
        await sdk.settle();
        await flushNow(sdk);
        expect(h.sentNames, ['app_first_open']);
      },
    );

    test(
      'süreç olay ile işaret arasında ölürse aynı event_id yeniden üretilir',
      () async {
        await h.store.put('first_open_event_id', '01CRASHEDFIRSTOPEN00000000');
        final sdk = await h.start(granted);
        await flushNow(sdk);
        expect(h.sentEvents.single['event_id'], '01CRASHEDFIRSTOPEN00000000');
        expect(h.store.get('first_open_done'), '1');
      },
    );

    test('ertelenmiş yol bir kez teslim edilir, olaya yazılmaz', () async {
      h.referrerResult = AttributionParams.parseQuery(
        'fr_click=clk_1&fr_dl=%2Furun%2F42%3Frenk%3Dmavi',
      );
      final sdk = await h.start(grantedAd);
      final first = await sdk.consumeDeferredDeepLink();
      expect(first.status, DeferredDeepLinkStatus.delivered);
      expect(first.path, '/urun/42?renk=mavi');
      final second = await sdk.consumeDeferredDeepLink();
      expect(second.status, DeferredDeepLinkStatus.none);
      await flushNow(sdk);
      final props = propsOf(h.sentEvents.single);
      expect(props.containsKey('fr_dl'), isFalse);
      expect(props.toString().contains('urun/42'), isFalse);
    });

    test('reklam izni yoksa yol verilmez, izin gelince verilir', () async {
      h.referrerResult = AttributionParams.parseQuery('fr_click=clk_1&fr_dl=%2Fa');
      final sdk = await h.start(const Consent(analytics: true, advertising: false));
      final before = await sdk.consumeDeferredDeepLink();
      expect(before.status, DeferredDeepLinkStatus.consentRequired);
      await sdk.setConsent(grantedAd);
      final after = await sdk.consumeDeferredDeepLink();
      expect(after.status, DeferredDeepLinkStatus.delivered);
      expect(after.path, '/a');
    });

    test('izin reddi ve çıkış teslim edilmemiş yolu siler', () async {
      h.referrerResult = AttributionParams.parseQuery('fr_click=clk_1&fr_dl=%2Fa');
      final sdk = await h.start(grantedAd);
      await sdk.settle();
      await sdk.reset();
      final result = await sdk.consumeDeferredDeepLink();
      expect(result.status, DeferredDeepLinkStatus.none);
    });

    test('iOS dürüstçe desteklenmiyor der; izin istetmez, depoya bakmaz', () async {
      h.referrerResult = AttributionParams.parseQuery('fr_click=clk_1&fr_dl=%2Fa');
      final sdk = await h.start(const Consent(analytics: true), platform: 'flutter_ios');
      final result = await sdk.consumeDeferredDeepLink();
      expect(result.status, DeferredDeepLinkStatus.notSupported);
      expect(result.path, isNull);
    });

    test('geçersiz yol ve kimliksiz yol alınmaz', () {
      for (final bad in ['https%3A%2F%2Fk.example', '%2F%2Fk.example', 'urun', '%2Fa%2F..%2Fb', '%2Fa%0Ab', '%2F%252e%252e%2Fadmin', '%2F%252F%252Fk.example', '%2F%255c%255ck', '%2Fa%250Ab', '%2Fa%25', '%2Fa%25ZZ']) {
        expect(AttributionParams.parseQuery('fr_click=c&fr_dl=$bad').deepLinkPath, isNull, reason: bad);
      }
      expect(AttributionParams.parseQuery('fr_dl=%2Fa').deepLinkPath, isNull);
      expect(AttributionParams.parseQuery('fr_dl=%2Fa').isEmpty, isTrue);
    });

    test('referrerden yalnız izin listesi taşınır', () async {
      h.referrerResult = AttributionParams.parseQuery(
        'fr_click=clk_1&utm_source=ads&gclid=gizli&email=a%40b.c',
      );
      final sdk = await h.start(grantedAd);
      await flushNow(sdk);
      final props = propsOf(h.sentEvents.single);
      expect(props['attribution_source'], 'play_install_referrer');
      expect(props['fr_click'], 'clk_1');
      expect(props['utm_source'], 'ads');
      expect(h.transport.requests.single.body, isNot(contains('gclid')));
      expect(h.transport.requests.single.body, isNot(contains('email')));
    });

    test('organik varsayılan kanıt sayılmaz', () async {
      h.referrerResult = AttributionParams.parseQuery(
        'utm_source=google-play&utm_medium=organic',
      );
      final sdk = await h.start(grantedAd);
      await flushNow(sdk);
      final props = propsOf(h.sentEvents.single);
      expect(props['attribution_source'], 'none');
      expect(props.containsKey('utm_source'), isFalse);
    });

    test('referrer hatası düşürmez, kaynak none', () async {
      h.referrerError = StateError('kanal yok');
      final sdk = await h.start(grantedAd);
      await flushNow(sdk);
      expect(propsOf(h.sentEvents.single)['attribution_source'], 'none');
    });

    test('iOS: kanıt yoksa none, platform flutter_ios', () async {
      final sdk = await h.start(
        granted,
        platform: 'flutter_ios',
        linkSource: AttributionSource.universalLink,
      );
      await flushNow(sdk);
      final event = h.sentEvents.single;
      expect(event['platform'], 'flutter_ios');
      expect(propsOf(event)['attribution_source'], 'none');
    });

    test('iOS: evrensel bağlantı universal_link olarak işlenir', () async {
      final sdk = await h.start(
        grantedAd,
        platform: 'flutter_ios',
        linkSource: AttributionSource.universalLink,
      );
      await flushNow(sdk);
      h.transport.requests.clear();
      await sdk.handleLink(
        'https://go.example.com/o?fr_click=clk_ios&token=SIR',
      );
      await sdk.settle();
      await flushNow(sdk);
      final event = h.sentEvents.single;
      expect(event['event_name'], 'deep_link_opened');
      expect(propsOf(event)['attribution_source'], 'universal_link');
      expect(propsOf(event)['fr_click'], 'clk_ios');
      expect(h.transport.requests.single.body, isNot(contains('SIR')));
    });
  });

  group('derin bağlantı', () {
    test('her açılışta üretilir, sorgu ve parça temizlenir', () async {
      final sdk = await h.start(grantedAd);
      await flushNow(sdk);
      h.transport.requests.clear();
      const url =
          'https://go.example.com/o/x?fr_click=clk_9&utm_campaign=yaz&token=SIR&email=a%40b.c#frag';
      await sdk.handleLink(url);
      await sdk.handleLink(url);
      await sdk.settle();
      await flushNow(sdk);
      expect(h.sentNames, ['deep_link_opened', 'deep_link_opened']);
      final event = h.sentEvents.first;
      expect(propsOf(event)['attribution_source'], 'app_link');
      expect(propsOf(event)['fr_click'], 'clk_9');
      expect(propsOf(event)['utm_campaign'], 'yaz');
      expect(
        (event['context']! as Map)['page_url'],
        'https://go.example.com/o/x',
      );
      final body = h.transport.requests.map((r) => r.body).join();
      expect(body, isNot(contains('SIR')));
      expect(body, isNot(contains('frag')));
      expect(body, isNot(contains('a@b.c')));
    });

    test('izin bekleyen bağlantı ret halinde unutulur', () async {
      final sdk = await h.start(null);
      await sdk.handleLink('https://go.example.com/o?fr_click=clk_2');
      await sdk.settle();
      expect(h.store.size, 0);
      await sdk.setConsent(denied);
      await sdk.setConsent(granted);
      await sdk.settle();
      await flushNow(sdk);
      expect(h.sentNames, isNot(contains('deep_link_opened')));
    });

    test(
      'onayda bekleyen bağlantı üretilir ve ilk açılışa kanıt olur',
      () async {
        final sdk = await h.start(null);
        await sdk.handleLink('https://go.example.com/o?fr_click=clk_3');
        await sdk.settle();
        await sdk.setConsent(grantedAd);
        await sdk.settle();
        await flushNow(sdk);
        final byName = {for (final e in h.sentEvents) e['event_name']: e};
        expect(
          propsOf(byName['app_first_open']!)['attribution_source'],
          'app_link',
        );
        expect(propsOf(byName['app_first_open']!)['fr_click'], 'clk_3');
        expect(propsOf(byName['deep_link_opened']!)['fr_click'], 'clk_3');
      },
    );

    test('özel şema kanıt sayılmaz', () async {
      final sdk = await h.start(granted);
      await flushNow(sdk);
      h.transport.requests.clear();
      await sdk.handleLink('myapp://open?fr_click=clk_4');
      await sdk.settle();
      await flushNow(sdk);
      expect(h.transport.requests, isEmpty);
    });
  });

  group('olay', () {
    test('şemaya uyar, parmak izi alanı taşımaz', () async {
      final sdk = await h.start(granted);
      await flushNow(sdk);
      h.transport.requests.clear();
      sdk.track('purchase', {
        'amount': 10.5,
        'bad key': 1,
        'nan': double.nan,
        'obj': Object(),
      });
      await sdk.settle();
      await flushNow(sdk);
      final event = h.sentEvents.single;
      expect(event['platform'], 'flutter_android');
      expect(event['schema_version'], 1);
      expect((event['sdk']! as Map)['name'], 'feralin-flutter');
      expect((event['consent']! as Map)['analytics'], isTrue);
      expect(propsOf(event).keys, ['amount']);
      expect((event['context']! as Map).keys.toSet(), {
        'locale',
        'timezone',
        'app',
      });
      expect(
        RegExp(
          r'^[0-9A-HJKMNP-TV-Z]{26}$',
        ).hasMatch(event['event_id']! as String),
        isTrue,
      );
      expect(
        RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
        ).hasMatch(event['occurred_at']! as String),
        isTrue,
      );
      final body = h.transport.requests.single.body;
      for (final name in [
        'ip',
        'gaid',
        'advertising_id',
        'android_id',
        'device_model',
        'screen',
      ]) {
        expect(body, isNot(contains('"$name"')));
      }
    });

    test('geçersiz olay adı üretilmez', () async {
      final sdk = await h.start(granted);
      expect(sdk.track('Bad-Name', null), isNull);
      expect(sdk.track('a' * 101, null), isNull);
    });

    test('boyut sınırını aşan olay atılır', () async {
      final sdk = await h.start(granted);
      await flushNow(sdk);
      sdk.track('huge', {'v': 'x' * (300 * 1024)});
      await sdk.settle();
      expect(h.store.size, 0);
    });

    test(
      'reset kimliği yeniler, kuyruğu siler, ilk açılış işaretini korur',
      () async {
        final sdk = await h.start(granted);
        await flushNow(sdk);
        final before = sdk.status();
        sdk.identify('user_1');
        sdk.track('a', null);
        await sdk.settle();
        await sdk.reset();
        final after = sdk.status();
        expect(h.store.size, 0);
        expect(after.userId, isNull);
        expect(after.anonymousId, isNot(before.anonymousId));
        expect(after.sessionId, isNot(before.sessionId));
        expect(h.store.get('first_open_done'), '1');
      },
    );
  });

  group('reklam ölçümü izni', () {
    test('izin yoksa referrer okunmaz, fr_click gitmez', () async {
      h.referrerResult = AttributionParams.parseQuery(
        'fr_click=clk_secret&utm_source=ads',
      );
      for (final consent in [granted, grantedNoAd]) {
        h.transport.requests.clear();
        h.store = MemoryEventStore();
        final sdk = await h.start(consent);
        await flushNow(sdk);
        final event = h.sentEvents.single;
        expect(event['event_name'], 'app_first_open');
        expect(propsOf(event)['attribution_source'], 'none');
        expect(propsOf(event).containsKey('fr_click'), isFalse);
        expect(propsOf(event).containsKey('utm_source'), isFalse);
        expect(h.transport.requests.single.body, isNot(contains('clk_secret')));
      }
      expect(h.referrerReads, 0);
    });

    test('consent alanı yalnız verildiyse gider', () async {
      final sdk = await h.start(granted);
      await flushNow(sdk);
      final first = h.sentEvents.single['consent']! as Map;
      expect(first.containsKey('advertising'), isFalse);
      expect(sdk.status().consent?.advertising, isNull);
      h.transport.requests.clear();
      await sdk.setConsent(grantedNoAd);
      sdk.track('a', null);
      await sdk.settle();
      await flushNow(sdk);
      expect((h.sentEvents.single['consent']! as Map)['advertising'], isFalse);
      expect(sdk.status().consent?.advertising, isFalse);
    });

    test('izin varsa fr_click ve consent birlikte gider', () async {
      h.referrerResult = AttributionParams.parseQuery('fr_click=clk_ok');
      final sdk = await h.start(grantedAd);
      await flushNow(sdk);
      final event = h.sentEvents.single;
      expect(propsOf(event)['fr_click'], 'clk_ok');
      expect((event['consent']! as Map)['advertising'], isTrue);
    });

    test(
      'izin sonradan gelirse referrer o zaman okunur, bir kez gider',
      () async {
        h.referrerResult = AttributionParams.parseQuery(
          'fr_click=clk_later&utm_source=ads&gclid=x',
        );
        final sdk = await h.start(granted);
        await flushNow(sdk);
        expect(h.referrerReads, 0);
        final firstOpen = h.sentEvents.single;
        expect(propsOf(firstOpen)['attribution_source'], 'none');
        final firstOpenAt = firstOpen['occurred_at'];
        h.transport.requests.clear();

        // İzin ilk açılıştan çok sonra gelir: olay zamanı izin anıdır, first_open_at ilk açılışı korur.
        h.clock.now += 3 * 24 * 3600 * 1000;
        await sdk.setConsent(grantedAd);
        await sdk.settle();
        await flushNow(sdk);
        expect(h.referrerReads, 1);
        final event = h.sentEvents.single;
        // Sunucu kurulum başına tek app_first_open kararı verir.
        expect(event['event_name'], 'deep_link_opened');
        expect(propsOf(event)['attribution_source'], 'play_install_referrer');
        expect(propsOf(event)['fr_click'], 'clk_later');
        expect(propsOf(event)['consent_followup'], isTrue);
        expect(propsOf(event)['first_open_at'], firstOpenAt);
        expect(event['occurred_at'], isNot(firstOpenAt));
        expect(h.transport.requests.single.body, isNot(contains('gclid')));

        // Ret-onay döngüsü ve yeni süreç ikinci kez üretmez.
        h.transport.requests.clear();
        await sdk.setConsent(grantedNoAd);
        await sdk.setConsent(grantedAd);
        await sdk.settle();
        await h.start(grantedAd);
        expect(h.referrerReads, 1);
        expect(h.transport.requests, isEmpty);
      },
    );

    test('sonradan gelen izinde organik referrer olay üretmez', () async {
      h.referrerResult = AttributionParams.parseQuery(
        'utm_source=google-play&utm_medium=organic',
      );
      final sdk = await h.start(granted);
      await flushNow(sdk);
      h.transport.requests.clear();
      await sdk.setConsent(grantedAd);
      await sdk.settle();
      await flushNow(sdk);
      expect(h.transport.requests, isEmpty);
      expect(h.store.get('referrer_checked'), '1');
    });

    test(
      'izinsiz bağlantı kanıtsız gider, izin gelince işaretli olayla',
      () async {
        final sdk = await h.start(granted);
        await flushNow(sdk);
        h.transport.requests.clear();
        await sdk.handleLink(
          'https://go.example.com/o/x?fr_click=clk_link&utm_campaign=yaz',
        );
        await sdk.settle();
        await flushNow(sdk);
        final plain = h.sentEvents.single;
        expect(plain['event_name'], 'deep_link_opened');
        expect(propsOf(plain)['attribution_source'], 'none');
        expect(propsOf(plain).containsKey('fr_click'), isFalse);
        expect(propsOf(plain).containsKey('utm_campaign'), isFalse);
        expect(
          (plain['context']! as Map)['page_url'],
          'https://go.example.com/o/x',
        );
        h.transport.requests.clear();

        await sdk.setConsent(grantedAd);
        await sdk.settle();
        await flushNow(sdk);
        final followUp = h.sentEvents.firstWhere(
          (e) => propsOf(e).containsKey('fr_click'),
        );
        expect(followUp['event_name'], 'deep_link_opened');
        expect(propsOf(followUp)['attribution_source'], 'app_link');
        expect(propsOf(followUp)['fr_click'], 'clk_link');
        expect(propsOf(followUp)['consent_followup'], isTrue);
      },
    );

    test('açık ret halinde bağlantı kanıtı saklanmaz', () async {
      final sdk = await h.start(grantedNoAd);
      await flushNow(sdk);
      h.transport.requests.clear();
      await sdk.handleLink('https://go.example.com/o/x?fr_click=clk_link');
      await sdk.settle();
      await flushNow(sdk);
      h.transport.requests.clear();
      await sdk.setConsent(grantedAd);
      await sdk.settle();
      await flushNow(sdk);
      expect(
        h.transport.requests.map((r) => r.body).join(),
        isNot(contains('clk_link')),
      );
    });

    test('izin geri çekilince kuyruktaki bağlantı olayı kanıtsız gider', () async {
      final sdk = await h.start(grantedAd);
      await flushNow(sdk);
      h.transport.requests.clear();
      await sdk.handleLink(
        'https://go.example.com/o/x?fr_click=clk_queued&utm_campaign=yaz',
      );
      sdk.track('plain', null);
      await sdk.settle();
      expect(h.store.size, 2);
      await sdk.setConsent(grantedNoAd);
      await sdk.settle();
      // Açılış sayılmaya devam eder.
      expect(h.store.size, 2);
      await flushNow(sdk);
      expect(h.sentNames, ['deep_link_opened', 'plain']);
      final body = h.transport.requests.single.body;
      expect(body, isNot(contains('clk_queued')));
      expect(body, isNot(contains('utm_campaign')));
      final event = h.sentEvents.firstWhere(
        (e) => e['event_name'] == 'deep_link_opened',
      );
      expect(propsOf(event)['attribution_source'], 'none');
      expect((event['consent']! as Map)['advertising'], isFalse);
    });

    test(
      'gönderilmemiş ilk açılış izin geri çekilince kanıtsız kalır',
      () async {
        h.referrerResult = AttributionParams.parseQuery(
          'fr_click=clk_first&utm_source=ads',
        );
        final sdk = await h.start(grantedAd);
        await sdk.settle();
        expect(h.store.size, 1);
        final id = h.store.peek(1).single.eventId;
        expect(h.store.peek(1).single.payload, contains('clk_first'));

        await sdk.setConsent(grantedNoAd);
        await sdk.settle();
        // Olay kaybolmaz, kimliği korunur.
        expect(h.store.size, 1);
        expect(h.store.peek(1).single.eventId, id);
        await flushNow(sdk);
        final event = h.sentEvents.single;
        expect(event['event_name'], 'app_first_open');
        expect(event['event_id'], id);
        expect(propsOf(event)['attribution_source'], 'none');
        expect(propsOf(event).containsKey('fr_click'), isFalse);
        expect(propsOf(event).containsKey('utm_source'), isFalse);
        expect((event['consent']! as Map)['advertising'], isFalse);
        expect(h.transport.requests.single.body, isNot(contains('clk_first')));
        // İşaret korunur, ikinci ilk açılış üretilmez.
        expect(h.store.get('first_open_done'), '1');
      },
    );

    test('izin alanı kalkınca bekleyen ilk açılış kanıtsız ve alansız kalır', () async {
      h.referrerResult = AttributionParams.parseQuery('fr_click=clk_first');
      final sdk = await h.start(grantedAd);
      await sdk.settle();
      await sdk.setConsent(granted);
      await sdk.settle();
      await flushNow(sdk);
      final event = h.sentEvents.single;
      expect(propsOf(event).containsKey('fr_click'), isFalse);
      expect((event['consent']! as Map).containsKey('advertising'), isFalse);
    });

    test('yalnız kanıt taşıyan follow-up izin geri çekilince atılır', () async {
      h.referrerResult = AttributionParams.parseQuery('fr_click=clk_later');
      final sdk = await h.start(granted);
      await flushNow(sdk);
      h.transport.requests.clear();
      await sdk.setConsent(grantedAd);
      await sdk.settle();
      expect(h.store.size, 1);
      await sdk.setConsent(grantedNoAd);
      await sdk.settle();
      expect(h.store.size, 0);
      await flushNow(sdk);
      expect(h.transport.requests, isEmpty);
    });

    test('uygulama özelliği olarak fr_click izinsiz gitmez', () async {
      final sdk = await h.start(granted);
      await flushNow(sdk);
      h.transport.requests.clear();
      sdk.track('purchase', {'fr_click': 'clk_manual', 'amount': 1});
      await sdk.settle();
      await flushNow(sdk);
      final props = propsOf(h.sentEvents.single);
      expect(props.containsKey('fr_click'), isFalse);
      expect(props['amount'], 1);
    });
  });

  group('kurulum eşleştirme kodu', () {
    test('yalnız ilk olayla gider', () async {
      final sdk = await h.start(granted, installCode: ' abcde-fghjk ');
      sdk.track('purchase', {'amount': 1});
      await sdk.settle();
      await flushNow(sdk);
      final withCode = h.sentEvents
          .where((e) => propsOf(e).containsKey('fr_install_code'))
          .toList();
      expect(withCode, hasLength(1));
      expect(propsOf(withCode.single)['fr_install_code'], 'abcde-fghjk');
      expect(withCode.single['event_id'], h.sentEvents.first['event_id']);
    });

    test('bozuk kod gitmez', () async {
      // I ve O alfabede yoktur: yapılandırmadaki bozuk kod hiçbir olaya eklenmez.
      final sdk = await h.start(granted, installCode: 'ABCDEFGHIO');
      sdk.track('purchase', {'amount': 1});
      await sdk.settle();
      await flushNow(sdk);
      expect(
        h.transport.requests.every((r) => !r.body.contains('fr_install_code')),
        isTrue,
      );
      expect(propsOf(h.sentEvents.last)['amount'], 1);
    });
  });

  group('gönderim', () {
    test('anahtar yalnız başlıkta', () async {
      final sdk = await h.start(granted);
      await flushNow(sdk);
      final request = h.transport.requests.single;
      expect(request.url, 'https://collect.example.com/v1/batch');
      expect(request.headers['x-feralin-project-key'], 'pk_test_unit');
      expect(request.url, isNot(contains('pk_test_unit')));
      expect(request.body, isNot(contains('pk_test_unit')));
      expect(request.headers['user-agent'], 'feralin-flutter/$sdkVersion');
    });

    test('idempotency tüm kimliklerden, yeniden denemede aynı', () async {
      final sdk = await h.start(granted);
      h.transport.responses.add(null);
      sdk.track('a', null);
      sdk.track('b', null);
      await sdk.settle();
      await flushNow(sdk);
      await flushNow(sdk);
      final first = h.transport.requests[0];
      final second = h.transport.requests[1];
      expect(
        first.headers['idempotency-key'],
        second.headers['idempotency-key'],
      );
      expect(
        first.headers['idempotency-key'],
        idempotencyKeyFor(first.events.map((e) => e['event_id']! as String)),
      );
    });

    test(
      'yanıtı kaybolan batch aynı içerik ve anahtarla yeniden denenir',
      () async {
        final sdk = await h.start(granted);
        await flushNow(sdk);
        h.transport.requests.clear();
        sdk.track('a', null);
        await sdk.settle();
        // Sunucu yazdı ama yanıt yolda kayboldu: istemci sonucu bilmiyor.
        h.transport.responses.add(null);
        await flushNow(sdk);
        // Araya yeni olay girse de ilk batch değişmez.
        sdk.track('b', null);
        await sdk.settle();
        await flushNow(sdk);
        final first = h.transport.requests[0];
        final retry = h.transport.requests[1];
        expect(
          first.headers['idempotency-key'],
          retry.headers['idempotency-key'],
        );
        expect(
          first.events.map((e) => e['event_id']),
          retry.events.map((e) => e['event_id']),
        );
        // Sabit batch onaylanınca kalan olay kendi anahtarıyla gider.
        await flushNow(sdk);
        expect(
          h.transport.requests.map(
            (r) => r.events.map((e) => e['event_name']).toList(),
          ),
          [
            ['a'],
            ['a'],
            ['b'],
          ],
        );
        expect(h.store.size, 0);
      },
    );

    test('ret sonrası sabit batch gönderilmez', () async {
      final sdk = await h.start(granted);
      await flushNow(sdk);
      h.transport.requests.clear();
      sdk.track('a', null);
      await sdk.settle();
      h.transport.responses.add(null);
      await flushNow(sdk);
      await sdk.setConsent(denied);
      await sdk.setConsent(granted);
      await sdk.settle();
      await flushNow(sdk);
      expect(h.transport.requests, hasLength(1));
    });

    test('durum kodları Web SDK ile aynı', () async {
      final sdk = await h.start(granted);
      h.transport.responses.add(const TransportResponse(500, '', null));
      expect((await flushNow(sdk)).status, 500);
      expect(h.store.size, 1);
      h.transport.responses.add(const TransportResponse(429, '', 3));
      expect((await flushNow(sdk)).status, 429);
      expect(h.store.size, 1);
      await h.clock.advance(4000, sdk);
      h.transport.responses.add(const TransportResponse(400, '{}', null));
      final rejected = await flushNow(sdk);
      expect(rejected.status, 400);
      expect(rejected.rejected, 1);
      expect(h.store.size, 0);
    });

    test('kabul cevabı batch kimliği ve sayıları taşır', () async {
      final sdk = await h.start(granted);
      h.transport.responses.add(
        const TransportResponse(
          202,
          '{"batch_id":"BATCH","accepted":0,"rejected":1}',
          null,
        ),
      );
      final result = await flushNow(sdk);
      expect(result.batchId, 'BATCH');
      expect(result.rejected, 1);
      expect(h.store.size, 0);
    });

    test('çevrimdışı kuyruk ağ gelince boşalır', () async {
      h.transport.responses.add(null);
      final sdk = await h.start(granted);
      await sdk.onForeground();
      await sdk.settle();
      expect(h.store.size, 1);
      expect(h.transport.requests, hasLength(1));
      expect(h.clock.pendingDelays, hasLength(1));
      await sdk.onNetworkAvailable();
      await sdk.settle();
      expect(h.store.size, 0);
      expect(h.transport.requests, hasLength(2));
    });

    test('geri çekilme üstel ve üst sınırlı', () async {
      h.transport.responses.addAll(
        List.filled(30, const TransportResponse(503, '', null)),
      );
      final sdk = await h.start(granted);
      await sdk.onForeground();
      await sdk.settle();
      final delays = <int>[];
      for (var i = 0; i < 12; i++) {
        final delay = h.clock.pendingDelays.single;
        delays.add(delay);
        await h.clock.advance(delay, sdk);
      }
      expect(delays[0], inInclusiveRange(2500, 5000));
      expect(delays[1], inInclusiveRange(5000, 10000));
      expect(delays[2], inInclusiveRange(10000, 20000));
      expect(delays.every((d) => d <= 15 * 60000), isTrue);
      expect(delays.last, greaterThanOrEqualTo(7 * 60000));
    });

    test('Retry-After ağ gelse bile korunur', () async {
      h.transport.responses.add(const TransportResponse(429, '', 120));
      final sdk = await h.start(granted);
      await sdk.onForeground();
      await sdk.settle();
      expect(h.transport.requests, hasLength(1));
      await sdk.onNetworkAvailable();
      await sdk.settle();
      expect(h.transport.requests, hasLength(1));
      await h.clock.advance(121000, sdk);
      expect(h.transport.requests, hasLength(2));
    });

    test('arka planda zamanlayıcı kalmaz, ön plana dönünce boşalır', () async {
      h.transport.responses.add(null);
      final sdk = await h.start(granted);
      await sdk.onForeground();
      await sdk.settle();
      expect(h.clock.pendingDelays, hasLength(1));
      await sdk.onBackground();
      await sdk.settle();
      expect(h.clock.pendingDelays, isEmpty);
      await h.clock.advance(3600000, sdk);
      final before = h.transport.requests.length;
      await sdk.onForeground();
      await sdk.settle();
      expect(h.transport.requests.length, before + 1);
      expect(h.store.size, 0);
    });

    test('kuyruk boşken zamanlayıcı kurulmaz', () async {
      final sdk = await h.start(granted);
      await sdk.onForeground();
      await sdk.settle();
      expect(h.store.size, 0);
      expect(h.clock.pendingDelays, isEmpty);
    });

    test('ön plandaki olay aralık sonunda gönderilir', () async {
      final sdk = await h.start(granted);
      await sdk.onForeground();
      await sdk.settle();
      h.transport.requests.clear();
      sdk.track('a', null);
      await sdk.settle();
      expect(h.transport.requests, isEmpty);
      expect(h.clock.pendingDelays, [15000]);
      await h.clock.advance(15000, sdk);
      expect(h.transport.requests, hasLength(1));
    });

    test('kuyruk üst sınırı en eskiyi atar', () async {
      final sdk = await h.start(granted, queueLimit: 3);
      for (final name in ['a', 'b', 'c', 'd', 'e']) {
        sdk.track(name, null);
      }
      await sdk.settle();
      expect(h.store.size, 3);
      expect(sdk.status().queued, 3);
    });

    test('batch boyutuna ulaşınca gönderilir', () async {
      final sdk = await h.start(granted, batchSize: 2);
      await flushNow(sdk);
      h.transport.requests.clear();
      for (var i = 0; i < 5; i++) {
        sdk.track('x', null);
      }
      await sdk.settle();
      expect(h.transport.requests.every((r) => r.events.length <= 2), isTrue);
      await flushNow(sdk);
      expect(h.store.size, 0);
      expect(h.sentEvents, hasLength(5));
    });

    test('büyük olaylar gövde bütçesini aşmaz', () async {
      final sdk = await h.start(granted, batchSize: 100);
      await flushNow(sdk);
      h.transport.requests.clear();
      final big = 'x' * (200 * 1024);
      for (var i = 0; i < 6; i++) {
        sdk.track('big', {'v': big});
      }
      await sdk.settle();
      await flushNow(sdk);
      await flushNow(sdk);
      expect(
        h.transport.requests.every((r) => r.body.length < 1024 * 1024),
        isTrue,
      );
      expect(h.transport.requests.length, greaterThanOrEqualTo(2));
      expect(h.store.size, 0);
    });

    test('taşıma hatası uygulamaya sızmaz, olay kaybolmaz', () async {
      final sdk = await h.start(
        granted,
        transportOverride: _ThrowingTransport(),
      );
      final result = await flushNow(sdk);
      expect(result.status, 0);
      expect(h.store.size, 1);
    });

    test('oturum zaman aşımında yenilenir, kısa geçişte korunur', () async {
      final sdk = await h.start(granted);
      await sdk.onForeground();
      await sdk.settle();
      final first = sdk.status().sessionId;
      await sdk.onBackground();
      await h.clock.advance(60000, sdk);
      await sdk.onForeground();
      await sdk.settle();
      expect(sdk.status().sessionId, first);
      await sdk.onBackground();
      await h.clock.advance(30 * 60000, sdk);
      await sdk.onForeground();
      await sdk.settle();
      expect(sdk.status().sessionId, isNot(first));
    });
  });
}
