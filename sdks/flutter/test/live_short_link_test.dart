import 'dart:io';

import 'package:feralin_flutter/src/core/short_links.dart';
import 'package:feralin_flutter/src/core/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Canlı yönlendiriciye karşı sözleşme denemesi. Yalnız `FERALIN_LIVE_SHORT_LINK` verilince koşar (ör. `https://fera.fly/x55gpts`);
/// reklam izni kapalı başlıkla istenir, böylece canlıda tıklama kanıtı yazılmaz.
void main() {
  final url = Platform.environment['FERALIN_LIVE_SHORT_LINK'];
  test(
    'canlı kısa link JSON ile çözümlenir',
    () async {
      for (final ios in [true, false]) {
        final response = await ioShortLinkFetch(
          url!,
          ShortLinks.headers(ios: ios, attribution: false),
        );
        expect(response?.status, 200);
        final resolved = ShortLinks.parse(response!.body);
        expect(resolved, isNotNull);
        expect(resolved!.code, isNotEmpty);
        expect(resolved.clickId, isNull);
        final synthetic = ShortLinks.syntheticUrl(url, resolved);
        expect(synthetic, startsWith('https://${Uri.parse(url).host}/'));
      }
    },
    skip: url == null ? 'FERALIN_LIVE_SHORT_LINK verilmedi' : false,
  );
}
