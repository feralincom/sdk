import 'dart:convert';
import 'dart:io';

import 'package:feralin_flutter/src/core/event_store.dart';
import 'package:feralin_flutter/src/platform_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Şifreli kuyruk: satır biçimi Android çekirdeğiyle (`enc1:`, ilişkilendirilmiş veri olay kimliği) uyumludur. Gerçek AES-GCM yerel
/// tarafta (Kotlin ve Swift) koşar ve oradaki testlerle sınanır; burada sözleşme ve dosya davranışı sınanır.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FakeQueueCipher cipher;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('feralin_enc_');
    cipher = FakeQueueCipher();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File queueFile() => File('${dir.path}/feralin_sdk/queue.jsonl');
  StoredEvent event(String id, [String extra = 'gizli-deger']) =>
      StoredEvent(id, '{"event_id":"$id","name":"x","note":"$extra"}');

  test('gövde diskte düz metin değildir; olay kimliği açık, satır enc1 biçimindedir', () async {
    final store = await FileEventStore.open(dir, cipher: cipher);
    await store.add(event('a'), 10);
    final text = queueFile().readAsStringSync();
    expect(text, isNot(contains('gizli-deger')));
    final row = jsonDecode(text.trim()) as Map<String, Object?>;
    expect(row.keys.toSet(), {'event_id', 'enc'});
    expect(row['event_id'], 'a');
    expect(row['enc'], startsWith('enc1:'));
  });

  test('yeniden açılışta olaylar çözülür, sıra ve gövde korunur', () async {
    final first = await FileEventStore.open(dir, cipher: cipher);
    await first.add(event('a'), 10);
    await first.add(event('b'), 10);
    final second = await FileEventStore.open(dir, cipher: cipher);
    expect(second.peek(10).map((e) => e.eventId), ['a', 'b']);
    expect(second.peek(10).first.payload, event('a').payload);
  });

  test('aynı event_id ikinci kez eklenmez, sınır aşılınca en eski atılır', () async {
    final store = await FileEventStore.open(dir, cipher: cipher);
    await store.add(event('a'), 2);
    await store.add(event('a'), 2);
    await store.add(event('b'), 2);
    await store.add(event('c'), 2);
    final reopened = await FileEventStore.open(dir, cipher: cipher);
    expect(reopened.peek(10).map((e) => e.eventId), ['b', 'c']);
  });

  test('her olay bir kez şifrelenir; onay ve yeniden yazım yeniden şifrelemez', () async {
    final store = await FileEventStore.open(dir, cipher: cipher);
    await store.add(event('a'), 10);
    await store.add(event('b'), 10);
    await store.add(event('c'), 10);
    final before = cipher.encryptCalls;
    await store.ack(['a']);
    expect(cipher.encryptCalls, before);
    expect(
      (await FileEventStore.open(dir, cipher: cipher)).peek(10).map((e) => e.eventId),
      ['b', 'c'],
    );
  });

  test('replace yeni gövdeyi şifreli yazar', () async {
    final store = await FileEventStore.open(dir, cipher: cipher);
    await store.add(event('a'), 10);
    await store.replace('a', '{"event_id":"a","yeni":"sir-2"}');
    expect(queueFile().readAsStringSync(), isNot(contains('sir-2')));
    final reopened = await FileEventStore.open(dir, cipher: cipher);
    expect(reopened.peek(10).single.payload, '{"event_id":"a","yeni":"sir-2"}');
  });

  test('eski düz metin satırlar ilk okumada şifrelenir', () async {
    await FileEventStore.open(dir);
    queueFile().writeAsStringSync(
      '${event('a').payload}\n${event('b').payload}\n',
    );
    final store = await FileEventStore.open(dir, cipher: cipher);
    expect(store.peek(10).map((e) => e.eventId), ['a', 'b']);
    expect(store.peek(10).first.payload, event('a').payload);
    final text = queueFile().readAsStringSync();
    expect(text, isNot(contains('gizli-deger')));
    expect(text.trim().split('\n'), hasLength(2));
    final reopened = await FileEventStore.open(dir, cipher: cipher);
    expect(reopened.peek(10).map((e) => e.eventId), ['a', 'b']);
  });

  test('başka kimliğe taşınan ya da bozulan satır açılmaz ve atılır', () async {
    final store = await FileEventStore.open(dir, cipher: cipher);
    await store.add(event('a'), 10);
    await store.add(event('b'), 10);
    final rows = queueFile().readAsLinesSync().map((l) => jsonDecode(l) as Map<String, Object?>).toList();
    // 'a' satırının şifreli gövdesi 'b' kimliğine yapıştırılır.
    rows[1]['enc'] = rows[0]['enc'];
    queueFile().writeAsStringSync(rows.map(jsonEncode).join('\n'));
    final reopened = await FileEventStore.open(dir, cipher: cipher);
    expect(reopened.peek(10).map((e) => e.eventId), ['a']);
    final after = await FileEventStore.open(dir, cipher: cipher);
    expect(after.peek(10).map((e) => e.eventId), ['a']);
  });

  test('anahtar alınamazsa düz metne düşülmez: olay bellekte kalır, dosya oluşmaz', () async {
    cipher.available = false;
    final store = await FileEventStore.open(dir, cipher: cipher);
    await store.add(event('a'), 10);
    await store.add(event('b'), 10);
    expect(store.peek(10).map((e) => e.eventId), ['a', 'b']);
    expect(queueFile().existsSync(), isFalse);
    await store.ack(['a']);
    expect(queueFile().existsSync(), isFalse);
    expect(store.size, 1);
  });

  test('anahtar yokken mevcut şifreli dosyaya dokunulmaz, anahtar gelince okunur', () async {
    final first = await FileEventStore.open(dir, cipher: cipher);
    await first.add(event('a'), 10);
    final snapshot = queueFile().readAsStringSync();
    cipher.available = false;
    final locked = await FileEventStore.open(dir, cipher: cipher);
    expect(locked.size, 0);
    await locked.add(event('b'), 10);
    await locked.ack(['b']);
    expect(queueFile().readAsStringSync(), snapshot);
    cipher.available = true;
    final unlocked = await FileEventStore.open(dir, cipher: cipher);
    expect(unlocked.peek(10).map((e) => e.eventId), ['a']);
  });

  test('anahtar yokken izin geri çekilirse kuyruk dosyası yine silinir', () async {
    final first = await FileEventStore.open(dir, cipher: cipher);
    await first.add(event('a'), 10);
    cipher.available = false;
    final locked = await FileEventStore.open(dir, cipher: cipher);
    await locked.clear();
    expect(queueFile().existsSync(), isFalse);
  });

  test('durum alanı (kimlik, işaretler) olay gövdesi değildir ve düz kalır', () async {
    final store = await FileEventStore.open(dir, cipher: cipher);
    await store.put('first_open_done', '1');
    expect(File('${dir.path}/feralin_sdk/state.json').readAsStringSync(), contains('first_open_done'));
  });

  group('PlatformQueueCipher', () {
    const channel = MethodChannel('com.feralin/flutter');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('kanal çağrısı düz metin ve ilişkilendirilmiş veriyi iletir', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return 'enc1:abcd';
      });
      expect(await PlatformQueueCipher().encrypt('GOVDE', 'olay1'), 'enc1:abcd');
      expect(seen!.method, 'encryptQueue');
      expect(seen!.arguments, {'plain': 'GOVDE', 'aad': 'olay1'});
      await PlatformQueueCipher().decrypt('enc1:abcd', 'olay1');
      expect(seen!.method, 'decryptQueue');
      expect(seen!.arguments, {'stored': 'enc1:abcd', 'aad': 'olay1'});
    });

    test('yerel taraf yoksa, hata verirse ya da biçim dışı dönerse null', () async {
      expect(await PlatformQueueCipher().encrypt('x', 'a'), isNull);
      expect(await PlatformQueueCipher().decrypt('enc1:00', 'a'), isNull);
      messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'x'));
      expect(await PlatformQueueCipher().encrypt('x', 'a'), isNull);
      expect(await PlatformQueueCipher().decrypt('enc1:00', 'a'), isNull);
      messenger.setMockMethodCallHandler(channel, (call) async => 'duz metin');
      expect(await PlatformQueueCipher().encrypt('x', 'a'), isNull);
    });
  });
}
