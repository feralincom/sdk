import 'dart:convert';
import 'dart:io';

import 'queue_cipher.dart';

class StoredEvent {
  const StoredEvent(this.eventId, this.payload);

  final String eventId;
  final String payload;
}

/// Kalıcı kuyruk ve küçük anahtar-değer deposu. Okumalar bellekten, yazmalar sırayla diske.
/// Motor bütün yazmaları tek sırada çalıştırır; eşzamanlı yazma olmaz.
abstract class EventStore {
  int get size;
  List<StoredEvent> peek(int limit);
  String? get(String key);
  Future<void> add(StoredEvent event, int limit);
  Future<void> ack(Iterable<String> eventIds);

  /// Bekleyen olayın gövdesini kimliğini ve sırasını değiştirmeden yeniler; olay yoksa bir şey yapmaz.
  Future<void> replace(String eventId, String payload);
  Future<void> clear();
  Future<void> put(String key, String value);
  Future<void> remove(String key);
}

/// Disk açılamazsa SDK'nın çalışmayı sürdürmesi için (ve testlerde) kullanılan bellek içi kuyruk.
class MemoryEventStore implements EventStore {
  final List<StoredEvent> _events = [];
  final Map<String, String> _values = {};

  @override
  int get size => _events.length;

  @override
  List<StoredEvent> peek(int limit) => _events.take(limit).toList();

  @override
  String? get(String key) => _values[key];

  @override
  Future<void> add(StoredEvent event, int limit) async {
    if (_events.every((e) => e.eventId != event.eventId)) _events.add(event);
    if (_events.length > limit) {
      _events.removeRange(0, _events.length - limit);
    }
  }

  @override
  Future<void> ack(Iterable<String> eventIds) async {
    final ids = eventIds.toSet();
    _events.removeWhere((e) => ids.contains(e.eventId));
  }

  @override
  Future<void> replace(String eventId, String payload) async {
    final index = _events.indexWhere((e) => e.eventId == eventId);
    if (index >= 0) _events[index] = StoredEvent(eventId, payload);
  }

  @override
  Future<void> clear() async => _events.clear();

  @override
  Future<void> put(String key, String value) async => _values[key] = value;

  @override
  Future<void> remove(String key) async => _values.remove(key);
}

/// Dosya kuyruğu: olay eklemek yalnız satır ekler (kuyruğu baştan yazmak pil tüketirdi); onay ve taşmada
/// geçici dosya + yeniden adlandırma ile atomik yazar. Bozuk son satır (yarım yazım) açılışta atılır.
/// Disk hatası yutulur: bellek durumu geçerli kalır, olay bir sonraki tam yazımda diske ulaşır.
///
/// [QueueCipher] verilirse olay gövdeleri diskte AES-256-GCM ile şifrelidir (Android çekirdeğiyle aynı `enc1:` biçimi); satır
/// `{"event_id":"…","enc":"enc1:…"}` olur, böylece olay kimliği açık kalır ve satır başka kimliğe taşınırsa açılmaz. Anahtar alınamazsa
/// düz metne DÜŞÜLMEZ: olay bellekte kalır, dosyaya dokunulmaz. Eski sürümün düz metin satırları ilk okumada şifreli yazılır.
/// Anahtar-değer alanı (anonim kimlik, işaretler) olay gövdesi değildir ve olduğu gibi kalır.
class FileEventStore implements EventStore {
  FileEventStore._(this._queueFile, this._stateFile, this._log, this._cipher);

  final File _queueFile;
  final File _stateFile;
  final void Function(String) _log;
  final QueueCipher? _cipher;
  final List<StoredEvent> _events = [];

  /// Olay kimliği → diskteki şifreli gövde; her olay bir kez şifrelenir, yeniden yazımlar bunu kullanır.
  final Map<String, String> _sealed = {};
  Map<String, String> _values = {};
  bool _keyUsable = true;
  bool _diskWritable = true;

  /// [directory] altında kendi klasörünü oluşturur ve mevcut kuyruğu okur. [cipher] `null` ise gövdeler düz metin yazılır
  /// (yalnız testler; paket girişi her zaman şifreleyici verir).
  static Future<FileEventStore> open(
    Directory directory, {
    void Function(String)? log,
    QueueCipher? cipher,
  }) async {
    final root = Directory(
      '${directory.path}${Platform.pathSeparator}feralin_sdk',
    );
    await root.create(recursive: true);
    final store = FileEventStore._(
      File('${root.path}${Platform.pathSeparator}queue.jsonl'),
      File('${root.path}${Platform.pathSeparator}state.json'),
      log ?? (_) {},
      cipher,
    );
    await store._load();
    return store;
  }

  Future<void> _load() async {
    final cipher = _cipher;
    if (cipher != null) {
      _keyUsable = await cipher.encrypt('probe', 'probe') != null;
      if (!_keyUsable) {
        _log('kuyruk anahtarı alınamadı: olaylar yalnız bellekte tutulur');
      }
    }
    _diskWritable = _keyUsable;
    var rewrite = false;
    if (await _queueFile.exists()) {
      for (final line in await _queueFile.readAsLines()) {
        if (line.isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map || decoded['event_id'] is! String) continue;
          final id = decoded['event_id'] as String;
          final sealed = decoded['enc'];
          if (decoded.length == 2 &&
              sealed is String &&
              sealed.startsWith(QueueCipher.prefix)) {
            final plain = _keyUsable && cipher != null
                ? await cipher.decrypt(sealed, id)
                : null;
            if (plain != null) {
              _events.add(StoredEvent(id, plain));
              _sealed[id] = sealed;
            } else if (_keyUsable && cipher != null) {
              // Bozuk ya da anahtarı kayıp satır: gönderilemeyecek veri sonsuza dek birikmez.
              _log('açılamayan şifreli kuyruk satırı atıldı');
              rewrite = true;
            } else {
              // Anahtar şimdilik yok: satır diskte kalsın, dosya baştan yazılmasın.
              _diskWritable = false;
            }
          } else {
            _events.add(StoredEvent(id, line));
            if (cipher != null) rewrite = true;
          }
        } on FormatException {
          _log('bozuk kuyruk satırı atıldı');
        }
      }
    }
    if (await _stateFile.exists()) {
      try {
        final decoded = jsonDecode(await _stateFile.readAsString());
        if (decoded is Map) {
          _values = {
            for (final entry in decoded.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
          };
        }
      } on FormatException {
        _log('bozuk durum dosyası yok sayıldı');
      }
    }
    // Eski düz metin satırlar ve atılan satırlar için dosya şifreli olarak bir kez baştan yazılır.
    if (rewrite) await _rewriteQueue();
  }

  @override
  int get size => _events.length;

  @override
  List<StoredEvent> peek(int limit) => _events.take(limit).toList();

  @override
  String? get(String key) => _values[key];

  @override
  Future<void> add(StoredEvent event, int limit) async {
    if (_events.any((e) => e.eventId == event.eventId)) return;
    _events.add(event);
    if (_events.length > limit) {
      final dropped = _events.sublist(0, _events.length - limit);
      _events.removeRange(0, _events.length - limit);
      for (final e in dropped) {
        _sealed.remove(e.eventId);
      }
      await _rewriteQueue();
      return;
    }
    final line = await _lineFor(event);
    if (line == null) return;
    await _guard(
      () => _queueFile.writeAsString('$line\n', mode: FileMode.append, flush: true),
    );
  }

  @override
  Future<void> ack(Iterable<String> eventIds) async {
    final ids = eventIds.toSet();
    final before = _events.length;
    _events.removeWhere((e) => ids.contains(e.eventId));
    _sealed.removeWhere((id, _) => ids.contains(id));
    if (_events.length != before) await _rewriteQueue();
  }

  @override
  Future<void> replace(String eventId, String payload) async {
    final index = _events.indexWhere((e) => e.eventId == eventId);
    if (index < 0) return;
    _events[index] = StoredEvent(eventId, payload);
    _sealed.remove(eventId);
    await _rewriteQueue();
  }

  /// İzin geri çekilince kuyruk, anahtar alınamasa bile diskten silinir.
  @override
  Future<void> clear() async {
    _events.clear();
    _sealed.clear();
    _diskWritable = _keyUsable;
    await _guard(() async {
      if (await _queueFile.exists()) await _queueFile.delete();
    });
  }

  @override
  Future<void> put(String key, String value) async {
    if (_values[key] == value) return;
    _values[key] = value;
    await _writeState();
  }

  @override
  Future<void> remove(String key) async {
    if (_values.remove(key) != null) await _writeState();
  }

  /// Diske yazılacak satır; yazma kapalıysa ya da şifrelenemezse `null` (olay bellekte kalır).
  Future<String?> _lineFor(StoredEvent event) async {
    final cipher = _cipher;
    if (cipher == null) return event.payload;
    if (!_diskWritable) return null;
    var sealed = _sealed[event.eventId];
    if (sealed == null) {
      sealed = await cipher.encrypt(event.payload, event.eventId);
      if (sealed == null) {
        _log('olay şifrelenemedi: bellekte tutuluyor');
        return null;
      }
      _sealed[event.eventId] = sealed;
    }
    return jsonEncode({'event_id': event.eventId, 'enc': sealed});
  }

  /// Boş kuyruk diskte iz bırakmaz; izin verilmemiş kullanıcıda dosya hiç oluşmaz. Bir olay şifrelenemezse dosya olduğu gibi kalır.
  Future<void> _rewriteQueue() => _guard(() async {
    if (!_diskWritable) return;
    if (_events.isEmpty) {
      if (await _queueFile.exists()) await _queueFile.delete();
      return;
    }
    final buffer = StringBuffer();
    for (final event in _events) {
      final line = await _lineFor(event);
      if (line == null) return;
      buffer
        ..write(line)
        ..write('\n');
    }
    await _replace(_queueFile, buffer.toString());
  });

  Future<void> _writeState() => _guard(() async {
    if (_values.isEmpty) {
      if (await _stateFile.exists()) await _stateFile.delete();
      return;
    }
    await _replace(_stateFile, jsonEncode(_values));
  });

  Future<void> _replace(File target, String text) async {
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(text, flush: true);
    await temp.rename(target.path);
  }

  Future<void> _guard(Future<void> Function() write) async {
    try {
      await write();
    } on FileSystemException catch (e) {
      _log('depo yazılamadı: ${e.osError?.errorCode ?? 'bilinmiyor'}');
    }
  }
}
