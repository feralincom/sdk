import 'dart:convert';
import 'dart:io';

import 'package:feralin_flutter/src/core/engine.dart';
import 'package:feralin_flutter/src/core/event_store.dart';
import 'package:feralin_flutter/src/core/queue_cipher.dart';
import 'package:feralin_flutter/src/core/transport.dart';
import 'package:feralin_flutter/src/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// 0.1.0 → 0.2.0 kuyruk geçişi ve geri dönüş (SDK-R09, `docs/sdk/upgrade-guide.md`). 0.1.0 dosyası her satırda bir olay JSON'u
/// tutar; şifreleyicisiz `FileEventStore` aynı biçimi yazar (git 057e4f7 öncesi `FileEventStore.add` satırı olduğu gibi ekler).
/// "Uygulama yeniden başlatma" aynı dizinin yeni depo ve yeni motorla açılmasıdır. Gerçek AES-GCM yerel taraftadır; burada sözleşme.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const granted = Consent(analytics: true);
  late Directory dir;
  late FakeQueueCipher cipher;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('feralin_upgrade_');
    cipher = FakeQueueCipher();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File queueFile() => File('${dir.path}/feralin_sdk/queue.jsonl');

  Future<FlushResult> flushNow(FeralinEngine sdk) async {
    final result = await sdk.flush();
    await sdk.settle();
    return result;
  }

  test('0.1 → 0.2: düz kuyruk kaybolmaz, şifrelenir; kesilen gönderim yeniden başlatmada aynı kimlik ve anahtarla bir kez kabul edilir', () async {
    // 0.1.0 biçimi: çevrimdışı biriken olaylar düz satır.
    final v1 = Harness()..store = await FileEventStore.open(dir);
    final old = await v1.start(granted);
    for (final name in ['a', 'b', 'c']) {
      old.track('sepet_$name', {'not': 'gizli-deger-$name'});
    }
    await old.settle();
    final pending = (await FileEventStore.open(dir)).peek(1000).map((e) => e.eventId).toList();
    expect(pending, hasLength(greaterThanOrEqualTo(3)));
    expect(queueFile().readAsStringSync(), contains('gizli-deger-a'));

    // 0.2.0 açılır, ilk gönderim 500 alır: hiçbir olay silinmez, dosyada düz metin kalmaz.
    final v2 = Harness()..store = await FileEventStore.open(dir, cipher: cipher);
    v2.transport.responses.add(const TransportResponse(500, '', null));
    final upgraded = await v2.start(granted);
    expect((await flushNow(upgraded)).status, 500);
    final text = queueFile().readAsStringSync();
    expect(text, isNot(contains('gizli-deger')));
    final rows = text.trim().split('\n').map((l) => jsonDecode(l) as Map<String, Object?>).toList();
    expect(rows.map((r) => r['event_id']), containsAll(pending));
    expect(rows.every((r) => (r['enc']! as String).startsWith(QueueCipher.prefix)), isTrue);

    // Yeniden başlatma: aynı olaylar aynı Idempotency-Key ile bir kez kabul edilir, kuyruk boşalır.
    final restarted = Harness()..store = await FileEventStore.open(dir, cipher: cipher);
    final again = await restarted.start(granted);
    expect((await flushNow(again)).status, 202);
    // Yalnız bu istek 202 aldı; 500 alan istek hiçbir olayı kabul ettirmedi.
    final accepted = restarted.sentEvents.map((e) => e['event_id']! as String).toList();
    for (final id in pending) {
      expect(accepted.where((e) => e == id), hasLength(1), reason: id);
    }
    expect(accepted.toSet(), hasLength(accepted.length));
    expect(
      restarted.transport.requests.single.headers['idempotency-key'],
      v2.transport.requests.single.headers['idempotency-key'],
    );
    expect(queueFile().existsSync(), isFalse);

    // Sonraki açılışta gönderilecek bir şey kalmaz.
    final third = Harness()..store = await FileEventStore.open(dir, cipher: cipher);
    await flushNow(await third.start(granted));
    expect(third.transport.requests, isEmpty);
  });

  test('0.2 → 0.1 → 0.2: 0.1 çevrimdışıyken şifreli satırları olduğu gibi bırakır; yeniden yükseltmede hepsi bir kez okunur', () async {
    StoredEvent event(String id) => StoredEvent(id, '{"event_id":"$id","event_name":"x","properties":{"not":"gizli-$id"}}');
    final v2 = await FileEventStore.open(dir, cipher: cipher);
    await v2.add(event('a'), 10);
    await v2.add(event('b'), 10);
    // 0.1.0 çevrimdışı bir olay ekler: satırı dosya sonuna olduğu gibi yazar, şifreli satırları yeniden yazmaz.
    queueFile().writeAsStringSync('${event('c').payload}\n', mode: FileMode.append);

    final back = await FileEventStore.open(dir, cipher: cipher);
    expect(back.peek(10).map((e) => e.eventId), ['a', 'b', 'c']);
    expect(back.peek(10).map((e) => e.payload), [event('a').payload, event('b').payload, event('c').payload]);
    expect(queueFile().readAsStringSync(), isNot(contains('gizli-')));
    final reopened = await FileEventStore.open(dir, cipher: cipher);
    expect(reopened.peek(10).map((e) => e.eventId), ['a', 'b', 'c']);
    await reopened.ack(['a', 'b', 'c']);
    expect((await FileEventStore.open(dir, cipher: cipher)).size, 0);
  });

  test('0.1 okuyucusu şifreli satırı olay sanar: gövde olay adı taşımaz (toplayıcı tek tek reddeder, belgelenen kayıp)', () async {
    final v2 = await FileEventStore.open(dir, cipher: cipher);
    await v2.add(const StoredEvent('a', '{"event_id":"a","event_name":"odeme"}'), 10);
    // 0.1.0 `_load`: `event_id` taşıyan her JSON satırı olduğu gibi gövde sayılır (057e4f7 öncesi event_store.dart).
    final line = queueFile().readAsLinesSync().single;
    final asV1Payload = jsonDecode(line) as Map<String, Object?>;
    expect(asV1Payload.keys.toSet(), {'event_id', 'enc'});
    expect(asV1Payload.containsKey('event_name'), isFalse);
  });
}
