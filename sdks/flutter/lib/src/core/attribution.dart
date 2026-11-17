/// Sözleşmedeki `properties.attribution_source` değerleri.
abstract final class AttributionSource {
  static const String playInstallReferrer = 'play_install_referrer';
  static const String appLink = 'app_link';
  static const String universalLink = 'universal_link';
  static const String none = 'none';
}

const Set<String> _utmKeys = {
  'utm_source',
  'utm_medium',
  'utm_campaign',
  'utm_term',
  'utm_content',
};
const String _frClick = 'fr_click';
const String _frDeepLink = 'fr_dl';
const int _maxDeepLinkLength = 200;
// Link-router ve saas-api ile aynı kural: şema ve host taşıyamaz, yalnız uygulama içi yol.
final RegExp _deepLinkPattern = RegExp(r"^/[A-Za-z0-9._~!$'()*+,;=:@%/?&-]*$");

// Kodlanmış nokta, bölü, ters bölü, kontrol karakteri ya da bozuk kaçış: `%2e%2e` URL birleştirmede üst dizine çıkar.
final RegExp _deepLinkUnsafeEscape = RegExp(
  r'%(?:2e|2f|5c|0[0-9a-f]|1[0-9a-f]|7f|[^0-9a-f]|[0-9a-f](?:[^0-9a-f]|$)|$)',
  caseSensitive: false,
);

bool _isValidDeepLinkPath(String path) =>
    path.length <= _maxDeepLinkLength &&
    _deepLinkPattern.hasMatch(path) &&
    !path.startsWith('//') &&
    !_deepLinkUnsafeEscape.hasMatch(path) &&
    !path.split('?').first.split('/').contains('..');
const int _maxValueLength = 256;
final RegExp _frClickPattern = RegExp(r'^[A-Za-z0-9._~-]{1,256}$');

/// Referrer veya URL'den alınmasına izin verilen tek veri: `fr_click` ve standart `utm_*`.
class AttributionParams {
  const AttributionParams({this.frClick, this.utm = const {}, this.deepLinkPath});

  static const AttributionParams empty = AttributionParams();

  final String? frClick;
  final Map<String, String> utm;

  /// Ertelenmiş derin bağlantı yolu. Kanıt değildir, olaya yazılmaz.
  final String? deepLinkPath;

  bool get isEmpty => frClick == null && utm.isEmpty;

  /// Play'in tıklama yokken döndürdüğü varsayılan (`organic` / `(not set)`) kanıt sayılmaz.
  bool get isPlayOrganicDefault =>
      frClick == null &&
      (utm['utm_medium']?.toLowerCase() == 'organic' ||
          utm['utm_source'] == '(not set)');

  void writeTo(Map<String, Object?> target) {
    if (frClick != null) target[_frClick] = frClick;
    target.addAll(utm);
  }

  /// Sorgu dizgisini izin listesiyle ayrıştırır. Bilinmeyen parametre okunmaz ve saklanmaz.
  /// Bozuk kodlanmış parça yok sayılır; aynı anahtarın ilk değeri geçerlidir.
  static AttributionParams parseQuery(String? raw) {
    if (raw == null || raw.trim().isEmpty) return empty;
    var text = raw;
    // Bazı kampanya araçları referrer'ın tamamını bir kez daha kodlar.
    if (!text.contains('=') && text.toLowerCase().contains('%3d')) {
      text = _decode(text) ?? text;
    }
    String? frClick;
    String? deepLinkPath;
    final utm = <String, String>{};
    for (final pair in text.split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final key = _decode(pair.substring(0, eq));
      if (key == null ||
          (key != _frClick && key != _frDeepLink && !_utmKeys.contains(key))) {
        continue;
      }
      final value = _decode(pair.substring(eq + 1))?.trim() ?? '';
      if (value.isEmpty) continue;
      if (key == _frClick) {
        if (frClick == null && _frClickPattern.hasMatch(value)) {
          frClick = value;
        }
      } else if (key == _frDeepLink) {
        if (deepLinkPath == null && _isValidDeepLinkPath(value)) {
          deepLinkPath = value;
        }
      } else if (!utm.containsKey(key)) {
        utm[key] = value.length > _maxValueLength
            ? value.substring(0, _maxValueLength)
            : value;
      }
    }
    // Yol tıklama kimliğiyle birlikte gelir; kimliksiz değer Feralin linkinden gelmemiştir.
    return AttributionParams(
      frClick: frClick,
      utm: utm,
      deepLinkPath: frClick == null ? null : deepLinkPath,
    );
  }

  /// Yerel kanaldan gelen haritayı aynı izin listesinden yeniden geçirir.
  static AttributionParams fromMap(Map<Object?, Object?> map) {
    final query = <String>[];
    map.forEach((key, value) {
      if (key is String && value is String) {
        query.add(
          '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}',
        );
      }
    });
    return parseQuery(query.join('&'));
  }

  static String? _decode(String text) {
    try {
      return Uri.decodeQueryComponent(text);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// Temizlenmiş derin bağlantı: yalnız scheme+host+path ile izin listesindeki parametreler kalır.
class DeepLink {
  const DeepLink(this.cleanUrl, this.params);

  static const int _maxUrlLength = 2048;
  static final RegExp _validHost = RegExp(r'^[a-z0-9.\-:]+$');

  final String cleanUrl;
  final AttributionParams params;

  /// Yalnız http(s) kabul edilir; özel şemalar başka uygulamalarca taklit edilebildiği için kanıt sayılmaz.
  static DeepLink? parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final Uri uri;
    try {
      uri = Uri.parse(raw);
    } on FormatException {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    // Uri.parse geçersiz karakteri kodlayıp kabul eder; Android'deki java.net.URI ile aynı sonuç için reddedilir.
    if (!_validHost.hasMatch(uri.host)) return null;
    final port = uri.hasPort ? ':${uri.port}' : '';
    final clean = '$scheme://${uri.host}$port${uri.path}';
    if (clean.length > _maxUrlLength) return null;
    return DeepLink(clean, AttributionParams.parseQuery(uri.query));
  }
}
