import 'package:feralin_flutter/feralin_flutter.dart';
import 'package:feralin_flutter/src/core/error_event.dart';
import 'package:feralin_flutter/src/core/event_json.dart';
import 'package:feralin_flutter/src/core/signal_events.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// X4: `fr_error`, oyun olayları ve `fr_ad_revenue` sözleşmeleri; ham yığın izi ve PII gitmez, parmak izi kararlıdır, sözleşme dışı girdi olay üretmez.
void main() {
  final stack = StackTrace.fromString('''
#0      OrderScreen.submit (package:shop/screens/order.dart:42:7)
#1      _InkResponseState.handleTap (package:flutter/src/material/ink_well.dart:1181:21)
<asynchronous suspension>
#2      main.<anonymous closure> (package:shop/main.dart:9:3)
''');

  test('yığın izi normalize edilir: satır, sütun ve yol gitmez, çerçeve sistemi atılır', () {
    final frames = normalizeStackFrames(stack);
    expect(frames, ['OrderScreen.submit@order.dart', 'main.<anonymous closure>@main.dart']);
  });

  test('hata gövdesi sözleşme alanlarını taşır, ham yığın gitmez', () {
    final props = errorProperties(
      StateError('sipariş başarısız'),
      stack,
      origin: errorOriginUncaught,
      fatal: false,
      appVersion: '1.4.2',
    );
    expect(props['error_type'], 'StateError');
    expect(props['top_frame'], 'OrderScreen.submit@order.dart');
    expect(props['frame_count'], 2);
    expect(props['app_version'], '1.4.2');
    expect(props['handled'], isFalse);
    expect(props['origin'], 'uncaught_exception');
    expect(props['fingerprint'], matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(props.values.any((v) => v.toString().contains('order.dart:42')), isFalse);
    expect(props.containsKey('stack'), isFalse);
  });

  test('aynı hata satır kaysa da aynı parmak izini üretir, farklı hata farklı', () {
    final a = errorProperties(StateError('x'), stack, origin: 'handled', fatal: false)['fingerprint'];
    final moved = StackTrace.fromString(stack.toString().replaceAll(':42:7', ':99:1'));
    expect(errorProperties(StateError('x'), moved, origin: 'handled', fatal: false)['fingerprint'], a);
    expect(errorProperties(ArgumentError('x'), stack, origin: 'handled', fatal: false)['fingerprint'], isNot(a));
  });

  test('mesajdaki kişisel veri temizlenir', () {
    final text = scrubErrorMessage('ali@example.com sipariş 5551234567 https://x.test/a?t=1 eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 sürüm 1.4.2');
    expect(text, isNot(contains('ali@')));
    expect(text, isNot(contains('5551234567')));
    expect(text, isNot(contains('x.test')));
    expect(text, isNot(contains('eyJ')));
    expect(text, contains('[email]'));
    expect(text, contains('1.4.2'));
    expect(scrubErrorMessage('a' * 500).length, lessThanOrEqualTo(errorMaxMessage));
    expect(scrubErrorMessage('UnsupportedOperationException'), 'UnsupportedOperationException');
  });

  test('sınırlayıcı aynı parmak izini ve toplamı sınırlar', () {
    final limiter = ErrorLimiter(maxEvents: 4, maxPerFingerprint: 2);
    expect(limiter.allow('a'), isTrue);
    expect(limiter.allow('a'), isTrue);
    expect(limiter.allow('a'), isFalse);
    expect(limiter.allow('b'), isTrue);
    expect(limiter.allow('c'), isTrue);
    expect(limiter.allow('d'), isFalse);
    expect(ErrorLimiter(sampleRate: 0.5, random: () => 0.9).allow('x'), isFalse);
    expect(ErrorLimiter(sampleRate: 0.5, random: () => 0.1).allow('x'), isTrue);
  });

  test('oyun olayları sözleşmeye uyar', () {
    expect(levelStartProperties('level_3', 2), {'level_id': 'level_3', 'attempt': 2});
    expect(levelCompleteProperties('l1', null, 1200, 45000), {'level_id': 'l1', 'score': 1200, 'duration_ms': 45000});
    expect(levelFailProperties('l1', null, null, null, 'timeout')!['fail_reason'], 'timeout');
    expect(levelStartProperties('', null), isNull);
    expect(levelStartProperties('x' * 65, null), isNull);
    expect(levelStartProperties('l', 0), isNull);
    expect(levelCompleteProperties('l', null, -1, null), isNull);
    expect(levelCompleteProperties('l', null, null, 86400001), isNull);
    expect(economyProperties('gold', 50, 'quest', null), {'currency_name': 'gold', 'amount': 50, 'reason': 'quest'});
    expect(economyProperties('gold', 0, null, null), isNull);
    expect(economyProperties('gold', maxEconomyAmount + 1, null, null), isNull);
    expect(economyProperties('', 5, null, null), isNull);
    expect(rewardedShownProperties('level_end', 'admob'), {'placement': 'level_end', 'network': 'admob'});
    expect(rewardedCompleteProperties('p', null, 10, 'gold')!['reward_amount'], 10);
    expect(rewardedShownProperties('', null), isNull);
    expect(iapInitiatedProperties('pack_small', 'shop', 'tx_1')!['transaction_id'], 'tx_1');
    expect(iapOfferShownProperties('', null), isNull);
  });

  test('reklam geliri sözleşmeye uyar, verified düşer', () {
    final props = adRevenueProperties(
      const AdRevenueInput(
        network: 'admob',
        adFormat: AdFormat.rewarded,
        revenueMicros: 12500,
        currency: 'USD',
        adUnit: 'ca-app-pub-1/2',
        precision: AdPrecision.estimated,
        placement: 'level_end',
        properties: {'verified': true, 'receipt_digest': 'x', 'extra': 'y'},
      ),
    )!;
    expect(props['network'], 'admob');
    expect(props['ad_format'], 'rewarded');
    expect(props['revenue_micros'], 12500);
    expect(props['currency'], 'USD');
    expect(props['precision'], 'estimated');
    expect(props.containsKey('verified'), isFalse);
    expect(props.containsKey('receipt_digest'), isFalse);
    expect(props['extra'], 'y');
    const bad = [
      AdRevenueInput(network: 'AdMob', adFormat: AdFormat.banner, revenueMicros: 1, currency: 'USD'),
      AdRevenueInput(network: '', adFormat: AdFormat.banner, revenueMicros: 1, currency: 'USD'),
      AdRevenueInput(network: 'admob', adFormat: AdFormat.banner, revenueMicros: -1, currency: 'USD'),
      AdRevenueInput(network: 'admob', adFormat: AdFormat.banner, revenueMicros: maxRevenueMicros + 1, currency: 'USD'),
      AdRevenueInput(network: 'admob', adFormat: AdFormat.banner, revenueMicros: 1, currency: 'usd'),
      AdRevenueInput(network: 'admob', adFormat: AdFormat.banner, revenueMicros: 1, currency: 'USD', adUnit: ''),
    ];
    for (final input in bad) {
      expect(adRevenueProperties(input), isNull, reason: input.network);
    }
    expect(sanitizeProperties(props)['revenue_micros'], 12500);
  });

  test('SDK kapalıyken yeni yöntemler null döner ve uygulamayı düşürmez', () {
    debugPrint('SDK başlatılmadı');
    expect(Feralin.trackAdRevenue(const AdRevenueInput(network: 'admob', adFormat: AdFormat.banner, revenueMicros: 1, currency: 'USD')), isNull);
    expect(Feralin.trackLevelStart('l1'), isNull);
    expect(Feralin.captureError(StateError('x')), isNull);
  });
}
