import 'dart:io';

import 'package:feralin_flutter/src/core/attribution.dart';
import 'package:feralin_flutter/src/core/idempotency.dart';
import 'package:feralin_flutter/src/core/types.dart';
import 'package:feralin_flutter/src/core/ulid.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('referrer izin listesi dışını okumaz', () {
    final params = AttributionParams.parseQuery(
      'utm_source=google&utm_medium=cpc&utm_campaign=y%C4%B1l&utm_term=a+b&utm_content=c'
      '&fr_click=clk-1_2.3~4&gclid=X&utm_foo=bar&email=a%40b.c',
    );
    expect(params.frClick, 'clk-1_2.3~4');
    expect(params.utm, {
      'utm_source': 'google',
      'utm_medium': 'cpc',
      'utm_campaign': 'yıl',
      'utm_term': 'a b',
      'utm_content': 'c',
    });
  });

  test('çift kodlanmış referrer ayrıştırılır', () {
    final params = AttributionParams.parseQuery(
      'fr_click%3Dclk_1%26utm_source%3Dads',
    );
    expect(params.frClick, 'clk_1');
    expect(params.utm['utm_source'], 'ads');
  });

  test('bozuk ve boş girdiler güvenli', () {
    expect(AttributionParams.parseQuery(null).isEmpty, isTrue);
    expect(AttributionParams.parseQuery('').isEmpty, isTrue);
    expect(
      AttributionParams.parseQuery('&&=&fr_click&utm_source=').isEmpty,
      isTrue,
    );
    expect(AttributionParams.parseQuery('fr_click=%ZZ').isEmpty, isTrue);
    expect(
      AttributionParams.parseQuery('fr_click=a%20b%3Cscript').frClick,
      isNull,
    );
    expect(
      AttributionParams.parseQuery('fr_click=${'a' * 257}').frClick,
      isNull,
    );
  });

  test('utm değeri kesilir, ilk değer geçerli', () {
    final params = AttributionParams.parseQuery(
      'utm_source=${'a' * 300}&utm_source=b&fr_click=one&fr_click=two',
    );
    expect(params.utm['utm_source'], hasLength(256));
    expect(params.frClick, 'one');
  });

  test('organik varsayılan tanınır', () {
    expect(
      AttributionParams.parseQuery(
        'utm_source=google-play&utm_medium=organic',
      ).isPlayOrganicDefault,
      isTrue,
    );
    expect(
      AttributionParams.parseQuery(
        'utm_source=(not%20set)&utm_medium=(not%20set)',
      ).isPlayOrganicDefault,
      isTrue,
    );
    expect(
      AttributionParams.parseQuery(
        'utm_source=ads&utm_medium=cpc',
      ).isPlayOrganicDefault,
      isFalse,
    );
    expect(
      AttributionParams.parseQuery(
        'fr_click=c1&utm_medium=organic',
      ).isPlayOrganicDefault,
      isFalse,
    );
  });

  test('kanal haritası aynı izin listesinden geçer', () {
    final params = AttributionParams.fromMap({
      'fr_click': 'c1',
      'utm_source': 'y ı',
      'gclid': 'x',
      'sayi': 1,
    });
    expect(params.frClick, 'c1');
    expect(params.utm, {'utm_source': 'y ı'});
  });

  test('derin bağlantı temizlenir', () {
    final link = DeepLink.parse(
      'HTTPS://user:pw@go.example.com:8443/a/b?token=s&fr_click=c1#frag',
    )!;
    expect(link.cleanUrl, 'https://go.example.com:8443/a/b');
    expect(link.params.frClick, 'c1');
  });

  test('derin bağlantı geçersizleri', () {
    expect(DeepLink.parse(null), isNull);
    expect(DeepLink.parse('myapp://x?fr_click=1'), isNull);
    expect(DeepLink.parse('https://bad host/x'), isNull);
    expect(DeepLink.parse('https:///yalniz-yol'), isNull);
    expect(DeepLink.parse('https://e.com/${'a' * 3000}'), isNull);
  });

  test('idempotency Web ve Android SDK test vektörüyle aynı', () {
    // packages/sdk-web/src/index.ts idempotencyKeyFor ile Node üzerinde üretilen değer.
    const a = '01JZZZZZZZZZZZZZZZZZZZZZZZ';
    const b = '01ABCDEFGHJKMNPQRSTVWXYZ01';
    expect(idempotencyKeyFor([a, b]), '51f0149954ab02da-2');
    expect(idempotencyKeyFor([b, a]), idempotencyKeyFor([a, b]));
  });

  test('ulid biçimi, monotonluk ve Android ile aynı zaman öneki', () {
    final first = nextUlid(1700000000000);
    final second = nextUlid(1700000000000);
    expect(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(first), isTrue);
    expect(second.substring(0, 10), first.substring(0, 10));
    expect(second.compareTo(first), greaterThan(0));
    expect(first.substring(0, 10), '01HF7YAT00');
  });

  test('yapılandırma doğrulama', () {
    FeralinConfig config(String key, String url) =>
        FeralinConfig(projectKey: key, collectUrl: url);
    expect(config('sk_live_x', 'https://e.com').validationError(), isNotNull);
    expect(config('', 'https://e.com').validationError(), isNotNull);
    expect(config('pk_test', 'ftp://e.com').validationError(), isNotNull);
    expect(config('pk_test', 'https://e.com').validationError(), isNull);
  });

  test('çekirdek saf Dart: Flutter içe aktarmaz', () {
    final core = Directory(
      'lib/src/core',
    ).listSync().whereType<File>().toList();
    expect(core, isNotEmpty);
    for (final file in core) {
      final imports = file
          .readAsLinesSync()
          .where((line) => line.startsWith('import '))
          .where((line) => line.contains('package:'));
      expect(imports, isEmpty, reason: file.path);
    }
  });
}
