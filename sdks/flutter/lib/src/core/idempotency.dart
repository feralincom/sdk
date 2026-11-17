/// Web ve Android SDK ile aynı anahtar: sıralı tüm event_id'lerin FNV-1a 64 özeti + olay sayısı.
/// Dart'ın yerel `int` türü 64 bitte taşar; bu paket web hedefi desteklemediğinden güvenlidir.
String idempotencyKeyFor(Iterable<String> eventIds) {
  final ids = eventIds.toList()..sort();
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final unit in ids.join(',').codeUnits) {
    hash = (hash ^ unit) * prime;
  }
  // toRadixString işaretli çalışır; iki yarım ayrı biçimlenerek işaretsiz onaltılık elde edilir.
  final high = ((hash >> 32) & 0xffffffff).toRadixString(16).padLeft(8, '0');
  final low = (hash & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return '$high$low-${ids.length}';
}
