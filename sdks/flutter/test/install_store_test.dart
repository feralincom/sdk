import 'package:flutter_test/flutter_test.dart';

import 'package:feralin_flutter/src/core/attribution.dart';
import 'package:feralin_flutter/src/core/engine.dart';
import 'package:feralin_flutter/src/core/types.dart';

import 'support.dart';

/// Kurulum mağazası: ilk açılışa reklam izninden bağımsız eklenir; liste dışı değer (paket adı) olaya yazılmaz; okuma hatası ilk
/// açılışı durdurmaz.
Future<Map<String, Object?>> firstOpenProps(
  Consent consent, {
  InstallStoreReader? installStore,
}) async {
  final h = Harness();
  final sdk = await h.start(consent, installStore: installStore);
  await sdk.settle();
  await sdk.flush();
  await sdk.settle();
  final first = h.sentEvents.where((e) => e['event_name'] == 'app_first_open');
  expect(first, hasLength(1));
  return propsOf(first.single);
}

void main() {
  test('reklam izni olsa da olmasa da ilk açılışa eklenir', () async {
    for (final advertising in [true, false]) {
      var reads = 0;
      final props = await firstOpenProps(
        Consent(analytics: true, advertising: advertising),
        installStore: () async {
          reads++;
          return 'samsung_galaxy_store';
        },
      );
      expect(props['install_store'], 'samsung_galaxy_store');
      expect(reads, 1);
    }
  });

  test('kapalı listedeki her değer geçer', () async {
    for (final value in InstallStore.values) {
      final props = await firstOpenProps(
        const Consent(analytics: true, advertising: false),
        installStore: () async => value,
      );
      expect(props['install_store'], value);
    }
    expect(InstallStore.values, hasLength(11));
  });

  test('liste dışı değer (paket adı) olaya yazılmaz', () async {
    for (final value in [
      'com.ornek.ozelmagaza',
      'com.android.vending',
      '',
      ' google_play',
    ]) {
      final props = await firstOpenProps(
        const Consent(analytics: true, advertising: true),
        installStore: () async => value,
      );
      expect(props.containsKey('install_store'), isFalse, reason: value);
      expect(props.values.contains(value), isFalse, reason: value);
    }
    expect(InstallStore.sanitize(42), isNull);
    expect(InstallStore.sanitize(null), isNull);
  });

  test('okuma hatası ya da değer yokluğu ilk açılışı durdurmaz', () async {
    final failed = await firstOpenProps(
      const Consent(analytics: true, advertising: true),
      installStore: () async => throw StateError('paket bilgisi yok'),
    );
    expect(failed.containsKey('install_store'), isFalse);
    expect(failed['attribution_source'], 'none');

    final missing = await firstOpenProps(
      const Consent(analytics: true, advertising: false),
      installStore: () async => null,
    );
    expect(missing.containsKey('install_store'), isFalse);

    // Okuyucu verilmemiş (iOS ve eski kurulum): alan yok.
    final absent = await firstOpenProps(
      const Consent(analytics: true, advertising: true),
    );
    expect(absent.containsKey('install_store'), isFalse);
  });

  test('analitik izni yoksa okunmaz ve olay üretilmez', () async {
    var reads = 0;
    final h = Harness();
    final sdk = await h.start(
      const Consent(analytics: false),
      installStore: () async {
        reads++;
        return 'google_play';
      },
    );
    await sdk.settle();
    await sdk.flush();
    await sdk.settle();
    expect(h.sentEvents, isEmpty);
    expect(reads, 0);
  });
}
