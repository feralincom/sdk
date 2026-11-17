/// UTP §8.2 kimlik yöntemleri (`group`, `setUserProperties`, `setGlobalProperties`). Kurallar bütün SDK'larda ve toplayıcıda
/// (`services/collect/internal/httpapi/profile_filter.go`) birebir aynıdır; toplayıcı ayrıca projenin izin listesini uygular.
library;

/// Grup olayı adı; React Native, Unity ve Android ile aynı.
const String groupEventName = 'fr_group';

/// Kullanıcı özellikleri olayı adı.
const String userPropertiesEventName = 'fr_user_properties';

/// Çağrı başına ve global haritada en çok özellik sayısı.
const int maxProfileProperties = 50;
const int _maxValueLength = 256;
const int _maxGroupIdLength = 128;

final RegExp _key = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$');
final RegExp _email = RegExp(r'[^\s@]+@[^\s@]+\.[^\s@]+');
final RegExp _control = RegExp(r'[\u0000-\u001F\u007F-\u009F]');
final RegExp _upper = RegExp(r'[A-Z]');
final RegExp _lowerOrDigit = RegExp(r'[a-z0-9]');

// İstemci doğrulama beyan edemez: bu anahtarlar düşer, toplayıcı da düşürür.
const Set<String> _reservedKeys = {
  'verified',
  'verification',
  'verification_source',
  'receipt_provider',
  'receipt_digest',
  'receipt',
};

// Kişisel veri anahtar kuralı (toplayıcıdaki piiTokens, piiFragments, piiExact ile aynı listeler).
const Set<String> _piiTokens = {
  'email', 'mail', 'phone', 'tel', 'telephone', 'mobile', 'msisdn', 'gsm', //
  'ip', 'ipv4', 'ipv6', 'ssn', 'tckn', 'passport', 'password', 'iban', //
  'address', 'adres', 'eposta', 'telefon', 'soyad', 'surname', 'firstname', //
  'lastname', 'fullname', 'birthdate', 'birthday', 'dob',
};
const List<String> _piiFragments = [
  'email', 'phonenumber', 'ipaddress', 'firstname', 'lastname', 'fullname', //
  'surname', 'soyad', 'eposta', 'telefon', 'password', 'birthdate',
];
const Set<String> _piiExact = {'name', 'username', 'displayname', 'isim', 'ad'};

/// Sistem olayı (`fr_` önekli) mı; global özellikler bunlara eklenmez.
bool isSystemEvent(String name) => name.startsWith('fr_');

/// Anahtarı sözcüklere böler: küçük harf ya da rakamdan sonra gelen büyük harf yeni sözcük başlatır; alt çizgi ayırır.
List<String> profileKeyTokens(String key) {
  final buffer = StringBuffer();
  for (var i = 0; i < key.length; i++) {
    final c = key[i];
    if (i > 0 && _upper.hasMatch(c) && _lowerOrDigit.hasMatch(key[i - 1])) {
      buffer.write('_');
    }
    buffer.write(c.toLowerCase());
  }
  return buffer.toString().split('_').where((t) => t.isNotEmpty).toList();
}

/// Anahtar kişisel veriye (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) benziyor mu.
bool isPiiLikeKey(String key) {
  final tokens = profileKeyTokens(key);
  if (tokens.any(_piiTokens.contains)) return true;
  final joined = tokens.join();
  if (_piiExact.contains(joined)) return true;
  return _piiFragments.any(joined.contains);
}

/// Grup kimliği kuralı: 1-128 karakter, yalnız boşluk değil, `@` ve kontrol karakteri yok.
bool isValidGroupId(String groupId) =>
    groupId.trim().isNotEmpty &&
    groupId.length <= _maxGroupIdLength &&
    !groupId.contains('@') &&
    !_control.hasMatch(groupId);

bool _validKey(String key) =>
    _key.hasMatch(key) && !_reservedKeys.contains(key) && !isPiiLikeKey(key);

/// Değer dizge (≤256, kontrol karakteri ve e-posta biçimi yok), sonlu sayı ya da mantıksal ise kendisi; değilse `null`.
Object? _cleanValue(Object? value) {
  if (value is String) {
    if (value.length > _maxValueLength ||
        _email.hasMatch(value) ||
        _control.hasMatch(value)) {
      return null;
    }
    return value;
  }
  if (value is bool || value is int) return value;
  if (value is double) return value.isFinite ? value : null;
  return null;
}

/// Temizleme sonucu: kalan özellikler ve düşen anahtar sayısı.
final class ProfileSanitized {
  /// Sözleşmeye uyan özellikler; global haritada `null` değer silme isteğidir.
  final Map<String, Object?> properties;

  /// Düşen anahtar sayısı (biçim, ayrılmış alan, kişisel veri, değer türü ya da 50 sınırı).
  final int dropped;

  /// Sonucu kurar.
  const ProfileSanitized(this.properties, this.dropped);
}

/// Özellikleri sözleşmeye indirger. Çağrı başına en çok 50 özellik tutulur. [allowNull] yalnız global haritada kullanılır.
ProfileSanitized sanitizeProfileProperties(
  Map<String, Object?>? properties, {
  bool allowNull = false,
}) {
  final out = <String, Object?>{};
  var dropped = 0;
  if (properties == null) return ProfileSanitized(out, 0);
  for (final entry in properties.entries) {
    if (!_validKey(entry.key)) {
      dropped++;
      continue;
    }
    Object? clean;
    if (!(allowNull && entry.value == null)) {
      clean = _cleanValue(entry.value);
      if (clean == null) {
        dropped++;
        continue;
      }
    }
    if (out.length >= maxProfileProperties && !out.containsKey(entry.key)) {
      dropped++;
      continue;
    }
    out[entry.key] = clean;
  }
  return ProfileSanitized(out, dropped);
}

/// `fr_group` özellikleri: temizlenmiş özellikler ve `group_id`. Grup kimliği sözleşmeye uymazsa `null` (olay üretilmez).
Map<String, Object?>? groupEventProperties(
  String groupId,
  Map<String, Object?>? traits, {
  void Function(String)? log,
}) {
  if (!isValidGroupId(groupId)) {
    log?.call('fr_group: geçersiz group_id, olay üretilmedi');
    return null;
  }
  final result = sanitizeProfileProperties(traits);
  if (result.dropped > 0) log?.call('fr_group: ${result.dropped} özellik düştü');
  return {...result.properties, 'group_id': groupId};
}

/// `fr_user_properties` özellikleri; geçerli özellik kalmazsa `null` (olay üretilmez).
Map<String, Object?>? userPropertiesEventProperties(
  Map<String, Object?> properties, {
  void Function(String)? log,
}) {
  final result = sanitizeProfileProperties(properties);
  if (result.dropped > 0) {
    log?.call('fr_user_properties: ${result.dropped} özellik düştü');
  }
  if (result.properties.isEmpty) {
    log?.call('fr_user_properties: geçerli özellik yok, olay üretilmedi');
    return null;
  }
  return result.properties;
}
