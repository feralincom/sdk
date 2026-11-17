// `fr_error` sözleşmesi (X4): hata sınıfı adı, temizlenmiş kısa mesaj, normalize edilmiş çerçevelerin özeti olan parmak izi ve en üst
// çerçeve. Ham yığın izi, satır numarası, dosya yolu ve kullanıcı verisi GİTMEZ. Sembolleştirme yoktur (`--obfuscate` ile
// derlenmiş uygulamada gizlenmiş adlar olduğu gibi gider). Kurallar Android ve Web SDK'larıyla aynıdır; toplayıcı mesajı ayrıca temizler.

import 'dart:math' as math;

/// Hata olayı için kaynak değerleri.
const String errorOriginUncaught = 'uncaught_exception';

/// Yakalanmış (try/catch) hata.
const String errorOriginHandled = 'handled';

/// Mesaj üst sınırı.
const int errorMaxMessage = 200;
const int _maxType = 64;
const int _maxFrame = 160;
const int _fingerprintFrames = 5;
const int _maxStackLines = 50;

final RegExp _url = RegExp(r'\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"' "'" r'<>]+');
final RegExp _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
final RegExp _uuid = RegExp(
  r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
);
final RegExp _token = RegExp(r'\b[A-Za-z0-9_\-+/=]{24,}\b');
final RegExp _number = RegExp(r'\+?\d[\d\s\-().]{5,}\d');
final RegExp _digit = RegExp(r'\d');
final RegExp _frameLine = RegExp(r'^#\d+\s+(.*?)\s+\((.*)\)$');
final RegExp _lineCol = RegExp(r':\d+(?::\d+)?$');

// Çerçeve sistemi: uygulama çerçevesi varsa parmak izine girmez.
const List<String> _frameworkPrefixes = ['dart:', 'package:flutter/', 'package:flutter_test/'];

/// Mesajdan e-posta, URL, UUID, uzun sayı ve belirteçleri çıkarır; 200 karaktere kırpar.
String scrubErrorMessage(String message) {
  var text = message.replaceAll(_url, '[url]');
  text = text.replaceAll(_email, '[email]');
  text = text.replaceAll(_uuid, '[id]');
  text = text.replaceAllMapped(
    _token,
    (m) => _digit.hasMatch(m[0]!) ? '[token]' : m[0]!,
  );
  text = text.replaceAllMapped(
    _number,
    (m) => _digit.allMatches(m[0]!).length >= 7 ? '[num]' : m[0]!,
  );
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.substring(0, math.min(text.length, errorMaxMessage));
}

/// FNV-1a 64 bit; 16 küçük harf onaltılı. Web SDK'sıyla aynı özet (yığın dışı karşılaştırma için).
String fnv1a64(String text) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final unit in text.codeUnits) {
    hash = ((hash ^ BigInt.from(unit)) * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Dart yığın izini normalize çerçevelere çevirir (`işlev@dosya`). Satır, sütun ve paket yolu atılır; `<asynchronous suspension>` yok sayılır.
List<String> normalizeStackFrames(StackTrace? stack) {
  if (stack == null) return const [];
  final all = <({String name, String location, String frame})>[];
  for (final raw in stack.toString().split('\n').take(_maxStackLines)) {
    final match = _frameLine.firstMatch(raw.trim());
    if (match == null) continue;
    final name = (match[1] ?? '').trim();
    final location = (match[2] ?? '').replaceFirst(_lineCol, '');
    final file = location.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ?? 'unknown';
    final fn = name.isEmpty ? '<anonymous>' : name.substring(0, math.min(name.length, 60));
    all.add((name: fn, location: location, frame: '$fn@$file'));
  }
  final app = all.where((f) => !_frameworkPrefixes.any(f.location.startsWith)).toList();
  return (app.isNotEmpty ? app : all).map((f) => f.frame).toList();
}

/// Hata gövdesi; sözleşme alanlarının tamamı. `appVersion` ≤32 karakterse eklenir.
Map<String, Object?> errorProperties(
  Object error,
  StackTrace? stack, {
  required String origin,
  required bool fatal,
  String? appVersion,
}) {
  var type = error.runtimeType.toString();
  if (type.length > _maxType) type = type.substring(0, _maxType);
  final message = scrubErrorMessage(error is Error || error is Exception ? _messageOf(error) : error.toString());
  final frames = normalizeStackFrames(stack ?? (error is Error ? error.stackTrace : null));
  final basis = frames.isNotEmpty
      ? frames.take(_fingerprintFrames).join('|')
      : message.replaceAll(RegExp(r'\d+'), '#');
  final out = <String, Object?>{
    'error_type': type,
    if (message.isNotEmpty) 'message': message,
    'fingerprint': fnv1a64('$type|$basis'),
    if (frames.isNotEmpty) 'top_frame': frames.first.substring(0, math.min(frames.first.length, _maxFrame)),
    'frame_count': math.min(frames.length, 1000),
    if (appVersion != null && appVersion.isNotEmpty && appVersion.length <= 32) 'app_version': appVersion,
    'handled': origin == errorOriginHandled,
    'fatal': fatal,
    'origin': origin,
  };
  return out;
}

String _messageOf(Object error) {
  try {
    return error.toString();
  } on Object {
    return '';
  }
}

/// Hata fırtınası sınırı: süreç başına en çok [maxEvents] olay, aynı parmak izi için en çok [maxPerFingerprint]. Örnekleme [sampleRate]
/// ile (0..1); rastgele kaynak test için verilebilir.
class ErrorLimiter {
  /// Sınırlayıcıyı kurar.
  ErrorLimiter({
    this.maxEvents = 20,
    this.maxPerFingerprint = 3,
    this.sampleRate = 1.0,
    double Function()? random,
  }) : _random = random ?? math.Random().nextDouble;

  /// Toplam üst sınır.
  final int maxEvents;

  /// Parmak izi başına üst sınır.
  final int maxPerFingerprint;

  /// Örnekleme oranı.
  final double sampleRate;
  final double Function() _random;
  int _total = 0;
  final Map<String, int> _perFingerprint = {};

  /// Olay gönderilebilir mi; izin verilirse sayaçları artırır.
  bool allow(String fingerprint) {
    if (_total >= maxEvents) return false;
    if (sampleRate < 1.0 && _random() >= sampleRate) return false;
    final seen = _perFingerprint[fingerprint] ?? 0;
    if (seen >= maxPerFingerprint) return false;
    _perFingerprint[fingerprint] = seen + 1;
    _total++;
    return true;
  }
}
