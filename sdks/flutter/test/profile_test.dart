import 'package:feralin_flutter/feralin_flutter.dart';
import 'package:feralin_flutter/src/core/profile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// UTP §8.2 kimlik yöntemleri: group, setUserProperties, setGlobalProperties (toplayıcı profile_filter.go ile aynı kurallar).
void main() {
  test('kişisel veri anahtarı kuralı toplayıcıyla aynı', () {
    const pii = [
      'email', 'userEmail', 'contact_email_address', 'phone_number', 'phoneNumber', 'userIP', 'ipv4', //
      'first_name', 'lastName', 'name', 'username', 'ad', 'soyadi', 'home_address', 'tckn',
    ];
    const safe = ['plan', 'plan_name', 'zip', 'hotel_tier', 'membership', 'ad_network'];
    for (final key in pii) {
      expect(isPiiLikeKey(key), isTrue, reason: key);
    }
    for (final key in safe) {
      expect(isPiiLikeKey(key), isFalse, reason: key);
    }
  });

  test('kullanıcı özelliği: kişisel veri, ayrılmış alan ve sözleşme dışı değer düşer', () {
    final logs = <String>[];
    final props = userPropertiesEventProperties({
      'plan': 'pro',
      'tier': 2,
      'beta': true,
      'email': 'a@b.co',
      'verified': true,
      'note': 'x' * 257,
      'nested': {'a': 1},
      'list': [1],
      'ratio': double.nan,
      'contact': 'x@y.io',
      'bad-key': 1,
    }, log: logs.add);
    expect(props, {'plan': 'pro', 'tier': 2, 'beta': true});
    expect(logs.single, contains('8 özellik'));
    expect(userPropertiesEventProperties({'email': 'x'}), isNull);
    expect(userPropertiesEventProperties({}), isNull);
  });

  test('çağrı başına 50 özellik', () {
    final many = {for (var i = 0; i < 70; i++) 'k$i': i};
    expect(userPropertiesEventProperties(many)!.length, maxProfileProperties);
  });

  test('geçersiz grup kimliği olay üretmez, group_id ezilemez', () {
    for (final id in ['', '   ', 'ekip@acme.com', 'a\u0001b', 'g' * 129]) {
      expect(groupEventProperties(id, null), isNull, reason: id);
    }
    expect(
      groupEventProperties('acme-team', {'plan': 'team', 'group_id': 'sahte', 'owner_email': 'x', 'seats': 12}),
      {'plan': 'team', 'seats': 12, 'group_id': 'acme-team'},
    );
  });

  test('motor: global birleşir, olay özelliği ezer, null siler, fr_ olayına eklenmez, reset siler', () async {
    final h = Harness();
    final sdk = await h.start(const Consent(analytics: true));
    sdk.setGlobalProperties({'app_release': '1.2.0', 'region': 'eu', 'email': 'x'});
    sdk.setGlobalProperties({'region': null, 'channel': 'app'});
    sdk.track('checkout_started', {'channel': 'promo'});
    sdk.track(userPropertiesEventName, userPropertiesEventProperties({'plan': 'pro'}));
    sdk.track(groupEventName, groupEventProperties('acme', null));
    await sdk.settle();
    await sdk.flush();
    await sdk.settle();
    Map<String, Object?> props(String name) =>
        h.sentEvents.firstWhere((e) => e['event_name'] == name)['properties']! as Map<String, Object?>;
    final plain = props('checkout_started');
    expect(plain['app_release'], '1.2.0');
    expect(plain['channel'], 'promo');
    expect(plain.containsKey('region'), isFalse);
    expect(plain.containsKey('email'), isFalse);
    expect(props(userPropertiesEventName), {'plan': 'pro'});
    expect(props(groupEventName), {'group_id': 'acme'});

    await sdk.reset();
    sdk.track('after_reset', null);
    await sdk.settle();
    await sdk.flush();
    await sdk.settle();
    final after = h.sentEvents.lastWhere((e) => e['event_name'] == 'after_reset');
    expect((after['properties'] as Map<String, Object?>?)?.containsKey('app_release') ?? false, isFalse);
  });

  test('motor: global toplamı 50 anahtarı aşmaz, clearGlobalProperties siler', () async {
    final h = Harness();
    final sdk = await h.start(const Consent(analytics: true));
    sdk.setGlobalProperties({for (var i = 0; i < 40; i++) 'a$i': i});
    sdk.setGlobalProperties({for (var i = 0; i < 40; i++) 'b$i': i});
    sdk.track('page_view', null);
    sdk.clearGlobalProperties();
    sdk.track('page_view_clean', null);
    await sdk.settle();
    await sdk.flush();
    await sdk.settle();
    final first = h.sentEvents.firstWhere((e) => e['event_name'] == 'page_view');
    expect((first['properties']! as Map).length, maxProfileProperties);
    final cleared = h.sentEvents.firstWhere((e) => e['event_name'] == 'page_view_clean');
    expect(cleared.containsKey('properties') ? (cleared['properties']! as Map).length : 0, 0);
  });

  test('facade başlatılmadan fırlatmaz', () {
    expect(Feralin.group('acme'), isNull);
    expect(Feralin.setUserProperties({'plan': 'pro'}), isNull);
    Feralin.setGlobalProperties({'plan': 'pro'});
    Feralin.clearGlobalProperties();
  });
}
