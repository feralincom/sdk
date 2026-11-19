import 'dart:convert';

/// Fera Fly kısa link çözümlemesi. Uygulama `https://marka.fera.fly/kod` gibi bir App Link / Universal Link ile doğrudan açıldığında
/// işletim sistemi yönlendiriciye uğramaz; SDK aynı adresi `application/vnd.feralin.link+json` türüyle ister. Yönlendirici linkin derin
/// yolunu, UTM'sini ve (izin varsa) tıklama kimliğini döner; bu bilgi tarayıcı yönlendirmesinde zaten herkese açıktır.
class ResolvedShortLink {
  const ResolvedShortLink({
    required this.code,
    required this.deepLinkPath,
    required this.utm,
    required this.clickId,
  });

  final String code;

  /// Uygulamanın açacağı yol; link yol taşımıyorsa `null`.
  final String? deepLinkPath;

  /// Anahtarlar `source`, `medium`, `campaign`, `term`, `content`.
  final Map<String, String> utm;

  /// Yönlendiricinin yazdığı tıklama kimliği; reklam ölçümü izni yoksa ya da attribution kapalı linkte `null`.
  final String? clickId;
}

abstract final class ShortLinks {
  static const String accept = 'application/vnd.feralin.link+json';
  static final RegExp _click = RegExp(r'^[A-Za-z0-9_-]{16,64}$');
  static final RegExp _code = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static const Set<String> _utmKeys = {
    'source',
    'medium',
    'campaign',
    'term',
    'content',
  };
  static const int _maxUtmValue = 256;
  static const int _maxPath = 200;

  /// `https` ve host listedeki bir host ya da onun alt alanı. Benzer adlı host (`sahtefera.fly`) kabul edilmez.
  static bool isShortLink(String? raw, List<String> hosts) {
    if (raw == null || raw.trim().isEmpty) return false;
    final Uri uri;
    try {
      uri = Uri.parse(raw);
    } on FormatException {
      return false;
    }
    if (uri.scheme.toLowerCase() != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    return hosts
        .map((h) => h.trim().toLowerCase())
        .where((h) => h.isNotEmpty)
        .any((h) => host == h || host.endsWith('.$h'));
  }

  /// Çözümleme isteğinin başlıkları. Kullanıcı-ajanı yalnız cihaz sınıfını verir (yönlendirici iOS/Android hedefini buna göre seçer); cihaz
  /// modeli gönderilmez. Reklam ölçümü izni yoksa `Feralin-Attribution: off`: yönlendirici tıklamayı toplam sayar, IP içeren kanıt yazmaz.
  static Map<String, String> headers({
    required bool ios,
    required bool attribution,
  }) {
    final headers = <String, String>{
      'Accept': accept,
      'User-Agent': ios
          ? 'FeralinSDK (iPhone; CPU iPhone OS 17_0 like Mac OS X)'
          : 'FeralinSDK (Linux; Android 14)',
    };
    if (!attribution) headers['Feralin-Attribution'] = 'off';
    return headers;
  }

  /// Yanıtı çözer; biçim bozuksa `null` (SDK çözümlemesiz açılışa düşer).
  static ResolvedShortLink? parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final code = decoded['code'];
    if (code is! String || !_code.hasMatch(code)) return null;
    final rawPath = decoded['deep_link_path'];
    final path =
        rawPath is String &&
            rawPath.startsWith('/') &&
            !rawPath.startsWith('//') &&
            rawPath.length <= _maxPath
        ? rawPath
        : null;
    final rawClick = decoded['click_id'];
    final click = rawClick is String && _click.hasMatch(rawClick)
        ? rawClick
        : null;
    final utm = <String, String>{};
    final rawUtm = decoded['utm'];
    if (rawUtm is Map<String, Object?>) {
      rawUtm.forEach((key, value) {
        if (_utmKeys.contains(key) && value is String && value.isNotEmpty) {
          utm[key] = value.length > _maxUtmValue
              ? value.substring(0, _maxUtmValue)
              : value;
        }
      });
    }
    return ResolvedShortLink(
      code: code,
      deepLinkPath: path,
      utm: utm,
      clickId: click,
    );
  }

  /// Çözülen linki mevcut derin bağlantı akışına verilecek adrese çevirir: aynı host, derin yol (yoksa `/`), `fr_click` ve `utm_*`.
  /// Böylece izin kuralları (reklam izni yoksa tıklama kimliği gönderilmez) tek yerde, motorun derin bağlantı akışında uygulanır.
  static String? syntheticUrl(String original, ResolvedShortLink resolved) {
    final Uri uri;
    try {
      uri = Uri.parse(original);
    } on FormatException {
      return null;
    }
    if (uri.host.isEmpty) return null;
    final query = <String>[
      if (resolved.clickId != null)
        'fr_click=${Uri.encodeQueryComponent(resolved.clickId!)}',
      for (final entry in resolved.utm.entries)
        'utm_${entry.key}=${Uri.encodeQueryComponent(entry.value)}',
    ].join('&');
    final path = resolved.deepLinkPath?.split('?').first ?? '/';
    return 'https://${uri.host}$path${query.isEmpty ? '' : '?$query'}';
  }

  /// Adresin yolu; ayrıştırılamazsa `/`.
  static String pathOf(String? raw) {
    try {
      final path = Uri.parse(raw ?? '').path;
      return path.isEmpty ? '/' : path;
    } on FormatException {
      return '/';
    }
  }
}
