import 'dart:io';

import 'package:feralin_flutter/src/core/event_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('feralin_store_'));
  tearDown(() => dir.deleteSync(recursive: true));

  StoredEvent event(String id) => StoredEvent(id, '{"event_id":"$id"}');
  File queueFile() => File('${dir.path}/feralin_sdk/queue.jsonl');
  File stateFile() => File('${dir.path}/feralin_sdk/state.json');

  test('kuyruk ve durum yeniden açılışta kalır', () async {
    final first = await FileEventStore.open(dir);
    await first.add(event('a'), 10);
    await first.add(event('b'), 10);
    await first.put('first_open_done', '1');
    final second = await FileEventStore.open(dir);
    expect(second.size, 2);
    expect(second.peek(10).map((e) => e.eventId), ['a', 'b']);
    expect(second.peek(10).first.payload, '{"event_id":"a"}');
    expect(second.get('first_open_done'), '1');
  });

  test('olay eklemek yalnız satır ekler, onay kalanı yazar', () async {
    final store = await FileEventStore.open(dir);
    await store.add(event('a'), 10);
    await store.add(event('b'), 10);
    expect(queueFile().readAsLinesSync(), hasLength(2));
    await store.ack(['a']);
    final reopened = await FileEventStore.open(dir);
    expect(reopened.peek(10).map((e) => e.eventId), ['b']);
  });

  test('yarım yazılmış son satır atılır, kalanlar okunur', () async {
    final store = await FileEventStore.open(dir);
    await store.add(event('a'), 10);
    queueFile().writeAsStringSync('{"event_id":"yari', mode: FileMode.append);
    final reopened = await FileEventStore.open(dir);
    expect(reopened.peek(10).map((e) => e.eventId), ['a']);
  });

  test('bozuk durum dosyası düşürmez', () async {
    final store = await FileEventStore.open(dir);
    await store.put('k', 'v');
    stateFile().writeAsStringSync('{bozuk');
    final reopened = await FileEventStore.open(dir);
    expect(reopened.get('k'), isNull);
  });

  test('sınır aşılınca en eski atılır, aynı kimlik eklenmez', () async {
    final store = await FileEventStore.open(dir);
    await store.add(event('a'), 2);
    await store.add(event('a'), 2);
    expect(store.size, 1);
    await store.add(event('b'), 2);
    await store.add(event('c'), 2);
    expect(store.peek(10).map((e) => e.eventId), ['b', 'c']);
    final reopened = await FileEventStore.open(dir);
    expect(reopened.peek(10).map((e) => e.eventId), ['b', 'c']);
  });

  test('replace gövdeyi değiştirir, sırayı korur, yeniden açılışta kalır', () async {
    final store = await FileEventStore.open(dir);
    await store.add(const StoredEvent('a', '{"event_id":"a"}'), 10);
    await store.add(const StoredEvent('b', '{"event_id":"b"}'), 10);
    await store.replace('a', '{"event_id":"a","x":1}');
    await store.replace('yok', '{"event_id":"yok"}');
    final again = await FileEventStore.open(dir);
    expect(again.peek(10).map((e) => e.payload).toList(), [
      '{"event_id":"a","x":1}',
      '{"event_id":"b"}',
    ]);
  });

  test('temizleme dosyayı kaldırır, durum korunur', () async {
    final store = await FileEventStore.open(dir);
    await store.add(event('a'), 10);
    await store.put('m', '1');
    await store.clear();
    expect(queueFile().existsSync(), isFalse);
    expect(store.size, 0);
    expect(store.get('m'), '1');
    await store.remove('m');
    expect(stateFile().existsSync(), isFalse);
  });

  test('izin verilmeyen kullanıcıda dosya oluşmaz', () async {
    await FileEventStore.open(dir);
    expect(queueFile().existsSync(), isFalse);
    expect(stateFile().existsSync(), isFalse);
  });

  test('yazma hatası fırlatmaz, bellek durumu geçerli kalır', () async {
    final store = await FileEventStore.open(dir);
    // Kuyruk yolunu dizine çevirerek disk hatası üretilir.
    Directory(queueFile().path).createSync();
    await store.add(event('a'), 10);
    expect(store.size, 1);
  });
}
