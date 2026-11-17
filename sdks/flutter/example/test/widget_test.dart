import 'package:feralin_flutter_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SDK başlatılmadan da ekran açılır ve düğmeler fırlatmaz', (
    tester,
  ) async {
    await tester.pumpWidget(const SampleApp());
    expect(find.textContaining('Feralin'), findsWidgets);
    await tester.tap(find.text('Send test event'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
