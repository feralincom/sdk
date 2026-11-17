import 'dart:convert';

import 'event_store.dart';
import 'types.dart';

/// Olaya eklenen bağlam: IP, reklam kimliği, cihaz modeli, ekran veya başka parmak izi alanı içermez.
class AppContext {
  const AppContext({
    this.locale,
    this.timezone,
    this.appVersion,
    this.appBuild,
  });

  final String? locale;
  final String? timezone;
  final String? appVersion;
  final String? appBuild;
}

const int _maxProperties = 100;
const int _maxDepth = 8;
final RegExp _propertyName = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$');
final RegExp _eventName = RegExp(r'^[a-z][a-z0-9_]*$');
final Object _dropped = Object();

bool isValidEventName(String name) =>
    name.length <= 100 && _eventName.hasMatch(name);

String formatTime(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

/// Geçersiz anahtarı ve serileştirilemeyen değeri atar, 100 özellikte keser, çağıranın haritasını kopyalar.
Map<String, Object?> sanitizeProperties(Map<String, Object?>? properties) {
  if (properties == null || properties.isEmpty) return const {};
  final out = <String, Object?>{};
  for (final entry in properties.entries) {
    if (out.length >= _maxProperties) break;
    if (!_propertyName.hasMatch(entry.key)) continue;
    final clean = _sanitizeValue(entry.value, 0);
    if (!identical(clean, _dropped) && clean != null) out[entry.key] = clean;
  }
  return out;
}

Object? _sanitizeValue(Object? value, int depth) {
  if (depth > _maxDepth) return _dropped;
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double) {
    return value.isFinite ? value : _dropped;
  }
  if (value is Map) {
    final out = <String, Object?>{};
    value.forEach((Object? k, Object? v) {
      if (k is! String) return;
      final clean = _sanitizeValue(v, depth + 1);
      if (!identical(clean, _dropped)) out[k] = clean;
    });
    return out;
  }
  if (value is Iterable) {
    return value
        .map((Object? v) => _sanitizeValue(v, depth + 1))
        .where((Object? v) => !identical(v, _dropped))
        .toList();
  }
  return _dropped;
}

/// UTP v1 kodlaması (`packages/schemas/utp/v1/event.schema.json`).
String encodeEvent({
  required String eventId,
  required String eventName,
  required int occurredAtMs,
  required String platform,
  required String sdkName,
  required String sdkVersion,
  required String? anonymousId,
  required String? sessionId,
  required String? userId,
  required Consent consent,
  required Map<String, Object?> properties,
  required String? pageUrl,
  required AppContext app,
}) {
  final appFields = <String, String>{
    if (app.appVersion != null && app.appVersion!.length <= 32)
      'version': app.appVersion!,
    if (app.appBuild != null && app.appBuild!.length <= 32)
      'build': app.appBuild!,
  };
  final context = <String, Object>{
    'page_url': ?pageUrl,
    if (app.locale != null && app.locale!.length <= 16) 'locale': app.locale!,
    if (app.timezone != null && app.timezone!.length <= 64)
      'timezone': app.timezone!,
    if (appFields.isNotEmpty) 'app': appFields,
  };
  return jsonEncode(<String, Object?>{
    'event_id': eventId,
    'event_name': eventName,
    'occurred_at': formatTime(occurredAtMs),
    'platform': platform,
    'schema_version': 1,
    'sdk': {'name': sdkName, 'version': sdkVersion},
    'anonymous_id': ?anonymousId,
    'session_id': ?sessionId,
    'user_id': ?userId,
    if (properties.isNotEmpty) 'properties': properties,
    'consent': consent.toJson(),
    if (context.isNotEmpty) 'context': context,
  });
}

const Set<String> _attributionEvents = {'app_first_open', 'deep_link_opened'};
const List<String> _utmKeys = [
  'utm_source',
  'utm_medium',
  'utm_campaign',
  'utm_term',
  'utm_content',
];

/// Reklam ölçümü izni kalktığında bekleyen olayı kanıtsız hale getirir. İlk açılış ve bağlantı açılışı sayılmaya devam eder: tıklama
/// kimliği, UTM ve kaynak silinir, izin bloğu güncel karara çekilir. Yalnız kanıt taşıyan follow-up olayının başka içeriği yoktur, `null`
/// döner ve atılır. Çözülemeyen gövde kanıt taşıyabileceği için de `null` döner.
String? withoutAttribution(String payload, Consent consent) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final rawProperties = decoded['properties'];
  final properties = rawProperties is Map<String, Object?>
      ? rawProperties
      : null;
  if (properties?['consent_followup'] == true) return null;
  final attributionEvent = _attributionEvents.contains(decoded['event_name']);
  if (!attributionEvent && properties?.containsKey('fr_click') != true) {
    return payload;
  }
  if (properties != null) {
    properties.remove('fr_click');
    if (attributionEvent) {
      for (final key in _utmKeys) {
        properties.remove(key);
      }
      properties.remove('first_open_at');
      if (properties.containsKey('attribution_source')) {
        properties['attribution_source'] = 'none';
      }
    }
    if (properties.isEmpty) decoded.remove('properties');
  }
  if (attributionEvent) decoded['consent'] = consent.toJson();
  return jsonEncode(decoded);
}

/// Depodaki JSON metinlerinden yeniden ayrıştırmadan batch gövdesi kurar.
String batchBody(int sentAtMs, List<StoredEvent> events) {
  final buffer = StringBuffer(
    '{"sent_at":"${formatTime(sentAtMs)}","events":[',
  );
  buffer.writeAll(events.map((e) => e.payload), ',');
  buffer.write(']}');
  return buffer.toString();
}
