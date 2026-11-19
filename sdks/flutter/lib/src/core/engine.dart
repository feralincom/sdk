import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'attribution.dart';
import 'event_json.dart';
import 'event_signer.dart';
import 'event_store.dart';
import 'idempotency.dart';
import 'profile.dart';
import 'short_links.dart';
import 'transport.dart';
import 'types.dart';
import 'ulid.dart';

const String sdkName = 'feralin-flutter';
const String sdkVersion = '0.3.0';

const String _eventFirstOpen = 'app_first_open';
const String _eventDeepLink = 'deep_link_opened';
const String _propSource = 'attribution_source';
const String _propFrClick = 'fr_click';
const String _propInstallCode = 'fr_install_code';
// Sunucudaki kanonik biçimle aynı alfabe (Crockford Base32, I/L/O/U yok); tire, boşluk ve alt çizgi ayraçtır.
final RegExp _installCodePattern = RegExp(r'^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$');

String? _validInstallCode(String? raw) {
  final code = raw?.trim();
  return code != null && _installCodePattern.hasMatch(code) ? code : null;
}
const String _propFollowUp = 'consent_followup';
const String _propFirstOpenAt = 'first_open_at';
const String _propInstallStore = 'install_store';
const String _propEmulator = 'device_emulator';
const String _keyReferrerChecked = 'referrer_checked';
const String _keyDeferredDeepLink = 'deferred_deep_link';
const String _keyFollowUpId = 'referrer_followup_event_id';
const String _keyAnonymousId = 'anonymous_id';
const String _keyInstallId = 'install_id';
const String _keyFirstOpenId = 'first_open_event_id';
const String _keyFirstOpenDone = 'first_open_done';
const String _keyFirstOpenAt = 'first_open_at_ms';
const int _maxBatchEvents = 500;
const int _maxIdLength = 128;
const int _maxEventChars = 256 * 1024;
const int _maxBatchChars = 900 * 1024;
const int _baseBackoffMs = 5000;
const int _maxBackoffMs = 15 * 60 * 1000;
const int _maxBackoffShift = 10;
const int _maxRetryAfterSeconds = 3600;

/// Zamanlanmış görevi iptal etmek için.
abstract class ScheduledTask {
  void cancel();
}

class _TimerTask implements ScheduledTask {
  _TimerTask(this._timer);
  final Timer _timer;
  @override
  void cancel() => _timer.cancel();
}

typedef Scheduler =
    ScheduledTask Function(Duration delay, void Function() task);
typedef InstallReferrerReader = Future<AttributionParams?> Function();

/// iOS AdServices token okuyucusu: yerel köprü yoksa `null` (unsupported), Apple hatasında fırlatır.
typedef AdServicesTokenReader = Future<String?> Function();

/// Meta Install Referrer zarfını okur (Android yerel eklentisi); yoksa `null`.
typedef MetaReferrerReader = Future<String?> Function(String appId);

/// Kurulum mağazası sınıfını okur (Android yerel eklentisi); platformda yoksa `null`.
typedef InstallStoreReader = Future<String?> Function();

/// Uygulamanın emülatörde çalışıp çalışmadığını okur (Android yerel eklentisi); bilinmiyorsa `null`.
typedef EmulatorReader = Future<bool?> Function();

/// SDK çekirdeği (Flutter içe aktarmaz). Davranış Web ve Android SDK ile aynıdır: izin yoksa olay üretilmez ve
/// gönderilmez, izin reddedilince kuyruk silinir, izin bekleniyorsa kuyruk bekletilir. Depo yazımları tek sırada
/// yürür; HTTP bu sıranın dışındadır, böylece izin reddi süren bir isteği beklemez.
class FeralinEngine {
  FeralinEngine({
    required this.config,
    required this.platform,
    required this.linkSource,
    required Future<EventStore> Function() openStore,
    required Transport transport,
    required InstallReferrerReader referrer,
    required AppContext Function() appContext,
    AdServicesTokenReader? adServicesToken,
    MetaReferrerReader? metaReferrer,
    InstallStoreReader? installStore,
    EmulatorReader? emulator,
    ShortLinkFetcher? shortLinkFetcher,
    Scheduler? scheduler,
    int Function()? clock,
    Random? random,
    void Function(String)? log,
  }) : _openStore = openStore,
       _transport = transport,
       _referrer = referrer,
       _appContext = appContext,
       _adServicesToken = adServicesToken ?? (() async => null),
       _metaReferrer = metaReferrer ?? ((_) async => null),
       _installStore = installStore ?? (() async => null),
       _emulator = emulator ?? (() async => null),
       _shortLinkFetcher = shortLinkFetcher ?? ioShortLinkFetch,
       _scheduler =
           scheduler ?? ((delay, task) => _TimerTask(Timer(delay, task))),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random(),
       _log = log ?? ((_) {}),
       _consent = config.consent,
       _batchSize = config.batchSize.clamp(1, _maxBatchEvents),
       _endpoint =
           '${config.collectUrl.replaceFirst(RegExp(r'/+$'), '')}/v1/batch';

  final FeralinConfig config;

  /// UTP `platform` değeri: `flutter_android` veya `flutter_ios`.
  final String platform;

  /// Bu platformdaki bağlantı kanıtının adı: `app_link` veya `universal_link`.
  final String linkSource;

  final Future<EventStore> Function() _openStore;
  final Transport _transport;
  final InstallReferrerReader _referrer;
  final AppContext Function() _appContext;
  final AdServicesTokenReader _adServicesToken;
  final MetaReferrerReader _metaReferrer;
  final InstallStoreReader _installStore;
  final EmulatorReader _emulator;
  final ShortLinkFetcher _shortLinkFetcher;
  final Scheduler _scheduler;
  final int Function() _clock;
  final Random _random;
  final void Function(String) _log;
  final int _batchSize;
  final String _endpoint;

  late EventStore _store;
  Consent? _consent;
  String? _anonymousId;
  String? _installId;
  String? _sessionId;
  String? _userId;
  // Global özellikler (UTP §8.2): `fr_` ile başlamayan her olaya eklenir; olayın kendi özelliği aynı anahtarda kazanır.
  final Map<String, Object?> _globals = {};
  int _queued = 0;
  bool _foreground = false;
  int _lastBackgroundAt = 0;
  bool _inflight = false;
  int _failures = 0;
  int _notBefore = 0;
  int _serverNotBefore = 0;
  ScheduledTask? _pendingFlush;
  // Sonucu bilinmeyen batch aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda
  // kaybolduysa araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
  List<StoredEvent>? _pinnedBatch;
  bool _firstOpenStarted = false;
  // Kurulum eşleştirme kodu süreç başına bir kez, kuyruğa giren ilk olayla gider.
  late String? _pendingInstallCode = _validInstallCode(config.installCode);
  bool _referrerFollowUpStarted = false;
  int _deferredDeepLinkEpoch = 0;
  (DeepLink, int)? _pendingLink;
  AttributionParams? _linkEvidence;
  // Reklam ölçümü izni henüz bildirilmemişken gelen bağlantının kanıtı; yalnız bellekte, süreç ömrüyle sınırlı.
  (DeepLink, int)? _deferredLink;
  Future<void> _tail = Future<void>.value();
  Future<void>? _inflightRequest;
  Future<void>? _firstOpenRead;

  bool get _analyticsAllowed => _consent?.analytics == true;

  /// Attribution kanıtı (fr_click, utm_*, referrer okuma) yalnız açık reklam ölçümü izniyle kullanılır.
  bool get _advertisingAllowed =>
      _consent?.analytics == true && _consent?.advertising == true;

  /// Görevleri sırayla çalıştırır; görev hatası uygulamaya sızmaz.
  Future<void> _run(FutureOr<void> Function() task) {
    final next = _tail.then((_) => task()).catchError((Object error) {
      _log('görev hatası: ${error.runtimeType}');
    });
    _tail = next;
    return next;
  }

  /// Sıradaki tüm iş ve süren istek bitene kadar bekler (test ve kapanış için).
  Future<void> settle() async {
    Future<void>? seenTail;
    Future<void>? seenRequest;
    Future<void>? seenRead;
    while (!identical(seenTail, _tail) ||
        !identical(seenRequest, _inflightRequest) ||
        !identical(seenRead, _firstOpenRead)) {
      seenTail = _tail;
      seenRequest = _inflightRequest;
      seenRead = _firstOpenRead;
      await seenTail;
      await seenRequest;
      await seenRead;
    }
  }

  Future<void> start() => _run(() async {
    _store = await _openStore();
    _anonymousId = _store.get(_keyAnonymousId) ?? nextUlid(_clock());
    _installId = _store.get(_keyInstallId);
    _sessionId = nextUlid(_clock());
    _queued = _store.size;
    final consent = _consent;
    if (consent != null) await _applyConsent(consent);
  });

  /// İzin kararı. Ret: kuyruk ve depodaki kimlik silinir. Onay: kimlik yazılır, bekleyen olaylar serbest kalır.
  Future<void> setConsent(Consent value) {
    _consent = value;
    if (!value.analytics) _queued = 0;
    return _run(() => _applyConsent(value));
  }

  Future<void> _applyConsent(Consent value) async {
    // Yol reklam ölçümü iznine bağlıdır: izin kalkınca teslim edilmemiş yol tutulmaz.
    if (value.advertising != true) await _store.remove(_keyDeferredDeepLink);
    if (value.analytics) {
      final id = _anonymousId;
      if (id != null) await _store.put(_keyAnonymousId, id);
      if (value.advertising != true) {
        await _stripQueuedAttribution(value);
        _linkEvidence = null;
      }
      if (value.advertising == false) _deferredLink = null;
      final pending = _pendingLink;
      _pendingLink = null;
      if (pending != null) await _emitDeepLink(pending.$1, pending.$2);
      await _maybeFirstOpen();
      if (value.advertising == true) {
        await _emitDeferredLink();
        _maybeReferrerFollowUp();
      }
      _scheduleOrFlush();
    } else {
      _pendingLink = null;
      _linkEvidence = null;
      _deferredLink = null;
      _pinnedBatch = null;
      _cancelPending();
      await _store.remove(_keyDeferredDeepLink);
      await _store.clear();
      await _store.remove(_keyAnonymousId);
      _installId = null;
      await _store.remove(_keyInstallId);
      _queued = 0;
      _failures = 0;
      _notBefore = 0;
    }
  }

  /// İzin geri çekildiyse veya hiç verilmediyse bekleyen olay kanıt taşımaz. İlk açılış işareti yazılmış olduğu için olay silinirse kurulum
  /// bir daha sayılamazdı: olay kanıtsız kalır. Yalnız kanıt taşıyan follow-up atılır.
  Future<void> _stripQueuedAttribution(Consent current) async {
    var changed = false;
    for (final event in _store.peek(config.queueLimit)) {
      final clean = withoutAttribution(event.payload, current);
      if (clean == null) {
        await _store.ack([event.eventId]);
        changed = true;
      } else if (clean != event.payload) {
        await _store.replace(event.eventId, clean);
        changed = true;
      }
    }
    if (changed) {
      _pinnedBatch = null;
      _queued = _store.size;
    }
  }

  void identify(String id) {
    if (id.isEmpty || id.length > _maxIdLength) return;
    _userId = id;
  }

  /// Global özellikleri birleştirir; `null` değer anahtarı siler. Toplam en çok 50 anahtar; fazlası ve sözleşme dışı anahtar düşer.
  void setGlobalProperties(Map<String, Object?> properties) {
    final result = sanitizeProfileProperties(properties, allowNull: true);
    var dropped = result.dropped;
    result.properties.forEach((key, value) {
      if (value == null) {
        _globals.remove(key);
      } else if (_globals.containsKey(key) || _globals.length < maxProfileProperties) {
        _globals[key] = value;
      } else {
        dropped++;
      }
    });
    if (dropped > 0) _log('global özellik: $dropped özellik düştü');
  }

  /// Bütün global özellikleri siler.
  void clearGlobalProperties() => _globals.clear();

  /// Çıkış: oturum ve anonim kimlik yenilenir, kuyruk ve global özellikler silinir. İlk açılış işareti kuruluma aittir, korunur.
  Future<void> reset() {
    _userId = null;
    _globals.clear();
    return _run(() async {
      _installId = null;
      await _store.remove(_keyInstallId);
      _sessionId = nextUlid(_clock());
      _anonymousId = nextUlid(_clock());
      if (_analyticsAllowed) {
        await _store.put(_keyAnonymousId, _anonymousId!);
      } else {
        await _store.remove(_keyAnonymousId);
      }
      _pinnedBatch = null;
      _deferredLink = null;
      lastShortLink = null;
      _linkEvidence = null;
      _deferredDeepLinkEpoch++;
      await _store.remove(_keyDeferredDeepLink);
      await _store.clear();
      _queued = 0;
    });
  }

  /// Kurulum kimliği (ADR-0007): AdServices token'ı, kullanıcı onayı kararı ve hesap bağı aynı kimliğe bağlanır. Yalnız iOS'ta
  /// ve reklam ölçümü izniyle üretilir; aksi hâlde `null`.
  Future<String?> installIdentifier() async {
    await _tail;
    if (platform != 'flutter_ios' || !_advertisingAllowed) return null;
    String? id;
    await _run(() async {
      id = await _ensureInstallId();
    });
    return id;
  }

  Future<String> _ensureInstallId() async {
    final known = _installId ?? _store.get(_keyInstallId);
    if (known != null) {
      _installId = known;
      return known;
    }
    final created = nextUlid(_clock());
    _installId = created;
    // Kimlik yalnız izin denetiminden sonra diske yazılır (çağıranlar _advertisingAllowed'ı denetler).
    await _store.put(_keyInstallId, created);
    return created;
  }

  /// AdServices token'ını bu kurulum kimliğiyle gönderir ve kimliği döndürür. Android'de Play Install Referrer yolu kullanıldığından
  /// `unsupported` döner (no-op). Sunucu bugün Apple'a sormaz: sonuç atıf kararı değildir, kesin atıf iddia edilmez.
  Future<InstallBinding> bindInstall() async {
    if (platform != 'flutter_ios') {
      return const InstallBinding(
        null,
        AdServicesSubmission(AdServicesStatus.unsupported),
      );
    }
    await _tail;
    if (!_advertisingAllowed) {
      return const InstallBinding(
        null,
        AdServicesSubmission(AdServicesStatus.skippedNoConsent),
      );
    }
    final submission = await _submitAdServicesToken();
    // İzin gönderim sırasında geri çekildiyse kimlik de verilmez.
    return InstallBinding(await installIdentifier(), submission);
  }

  Future<AdServicesSubmission> _submitAdServicesToken() async {
    final attribution = config.attribution;
    if (attribution == null) {
      return const AdServicesSubmission(AdServicesStatus.notConfigured);
    }
    String? token;
    try {
      token = await _adServicesToken();
    } on Object catch (error) {
      _log('AdServices token alınamadı: ${error.runtimeType}');
      return const AdServicesSubmission(
        AdServicesStatus.tokenUnavailable,
        detail: 'AdServices token alınamadı',
      );
    }
    if (token == null || token.isEmpty) {
      return const AdServicesSubmission(AdServicesStatus.unsupported);
    }
    // İstek sürerken izin geri çekildiyse göndermeyiz.
    if (!_advertisingAllowed) {
      return const AdServicesSubmission(AdServicesStatus.skippedNoConsent);
    }
    final installId = await installIdentifier();
    if (installId == null) {
      return const AdServicesSubmission(AdServicesStatus.skippedNoConsent);
    }
    final root = attribution.apiUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final url =
        '$root/v1/projects/${Uri.encodeComponent(attribution.projectId)}/attribution/apple-adservices/tokens';
    final headers = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json, application/problem+json',
      'authorization': 'Bearer ${config.projectKey}',
      'user-agent': '$sdkName/$sdkVersion',
    };
    TransportResponse? response;
    try {
      response = await _transport.post(
        url,
        headers,
        jsonEncode({'token': token, 'install_id': installId}),
      );
    } on Object catch (error) {
      _log('taşıma hatası: ${error.runtimeType}');
    }
    if (response == null) {
      return const AdServicesSubmission(AdServicesStatus.temporaryFailure);
    }
    final status = response.status;
    if (status == 202) {
      return const AdServicesSubmission(
        AdServicesStatus.received,
        httpStatus: 202,
      );
    }
    final detail = _problemTitle(response.body);
    if (status == 429 || status >= 500) {
      return AdServicesSubmission(
        AdServicesStatus.temporaryFailure,
        httpStatus: status,
        detail: detail,
      );
    }
    return AdServicesSubmission(
      AdServicesStatus.rejected,
      httpStatus: status,
      detail: detail,
    );
  }

  /// Sorun gövdesinin `title` alanı; token ya da anahtar içermez.
  String? _problemTitle(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['title'] is String) {
        return decoded['title'] as String;
      }
    } on FormatException {
      // Gövde JSON değilse ayrıntı yoktur.
    }
    return null;
  }

  /// Ertelenmiş derin bağlantıyı bir kez verir. Android'de referrer okuması bitmesi beklenir.
  /// iOS karşılığı yoktur: App Store parametreyi kuruluma taşımaz, parmak iziyle eşleştirme yasaktır.
  Future<DeferredDeepLink> consumeDeferredDeepLink() async {
    if (platform != 'flutter_android') {
      return const DeferredDeepLink(DeferredDeepLinkStatus.notSupported);
    }
    await _tail;
    final read = _firstOpenRead;
    if (read != null) await read;
    late DeferredDeepLink result;
    await _run(() async {
      final path = _store.get(_keyDeferredDeepLink);
      if (!_advertisingAllowed) {
        result = const DeferredDeepLink(DeferredDeepLinkStatus.consentRequired);
      } else if (path != null) {
        await _store.remove(_keyDeferredDeepLink);
        result = DeferredDeepLink(DeferredDeepLinkStatus.delivered, path);
      } else {
        result = const DeferredDeepLink(DeferredDeepLinkStatus.none);
      }
    });
    return result;
  }

  /// Olay kimliği döner; izin yoksa veya ad geçersizse `null` ve olay üretilmez.
  String? track(String name, Map<String, Object?>? properties) {
    if (!_analyticsAllowed) {
      _log('izin yok, olay üretilmedi: $name');
      return null;
    }
    if (!isValidEventName(name)) {
      _log('geçersiz olay adı');
      return null;
    }
    final at = _clock();
    final id = nextUlid(at);
    var clean = sanitizeProperties(properties);
    if (_globals.isNotEmpty && !isSystemEvent(name)) {
      // Global önce, olayın kendi özelliği sonra yazılır: aynı anahtarda olay kazanır; toplam tavan yine sanitizeProperties'tedir.
      clean = sanitizeProperties({..._globals, ...clean});
    }
    _run(() => _produce(id, name, at, clean, null));
    return id;
  }

  /// Son çözümlenen kısa link; bellekte tutulur, diske yazılmaz.
  ResolvedShortLink? lastShortLink;

  /// Derin bağlantı URL'ini işler. Ham URL saklanmaz; izin beklenirken temizlenmiş hali yalnız bellekte tutulur.
  ///
  /// Fera Fly kısa linki (App Link / Universal Link doğrudan açıldı, yönlendirici atlandı) önce yönlendiriciden çözümlenir; dönen değer
  /// çözümlenen linktir. Adreste zaten tıklama kimliği varsa (yönlendiriciden geçmiş), kısa link değilse, analitik izni yoksa ya da
  /// çözümleme başarısızsa `null` döner ve adres olduğu gibi işlenir.
  Future<ResolvedShortLink?> handleLink(String? url) async {
    final link = DeepLink.parse(url);
    if (link == null) return null;
    Map<String, String>? resolveHeaders;
    await _run(() async {
      if (_analyticsAllowed &&
          link.params.frClick == null &&
          ShortLinks.isShortLink(url, config.shortLinkHosts)) {
        resolveHeaders = ShortLinks.headers(
          ios: platform.endsWith('_ios'),
          attribution: _advertisingAllowed,
        );
      } else {
        await _acceptLink(link);
      }
    });
    final headers = resolveHeaders;
    if (headers == null) return null;
    // Ağ isteği görev sırasının dışında yapılır: olay kuyruğu en çok 5 sn beklemesin.
    ResolvedShortLink? resolved;
    try {
      final response = await _shortLinkFetcher(url!, headers);
      if (response != null && response.status == 200) {
        resolved = ShortLinks.parse(response.body);
      }
    } on Object catch (error) {
      _log('kısa link çözümlenemedi: ${error.runtimeType}');
    }
    await _run(() async {
      lastShortLink = resolved;
      final synthetic = resolved == null
          ? null
          : ShortLinks.syntheticUrl(url!, resolved);
      await _acceptLink(DeepLink.parse(synthetic) ?? link);
    });
    return resolved;
  }

  Future<void> _acceptLink(DeepLink link) async {
    final at = _clock();
    final current = _consent;
    if (current == null) {
      _pendingLink = (link, at);
    } else if (current.analytics) {
      await _emitDeepLink(link, at);
    }
  }

  Future<void> _emitDeepLink(DeepLink link, int at) async {
    final props = <String, Object?>{};
    if (_advertisingAllowed) {
      if (!link.params.isEmpty) _linkEvidence = link.params;
      props[_propSource] = linkSource;
      link.params.writeTo(props);
    } else {
      // İzin yoksa attribution yok: açılış sayılır, kanıt gönderilmez. İzin henüz sorulmadıysa bellekte beklenir.
      props[_propSource] = AttributionSource.none;
      if (_consent?.advertising == null && !link.params.isEmpty) {
        _deferredLink = (link, at);
      }
    }
    await _produce(nextUlid(at), _eventDeepLink, at, props, link.cleanUrl);
    _flushIfForeground();
  }

  /// Reklam ölçümü izni sonradan geldi: açılış zaten sayıldığı için kanıt işaretli ayrı olayla taşınır.
  Future<void> _emitDeferredLink() async {
    final deferred = _deferredLink;
    if (deferred == null) return;
    _deferredLink = null;
    final (link, at) = deferred;
    final props = <String, Object?>{
      _propSource: linkSource,
      _propFollowUp: true,
    };
    link.params.writeTo(props);
    _linkEvidence = link.params;
    await _produce(nextUlid(at), _eventDeepLink, at, props, link.cleanUrl);
    _flushIfForeground();
  }

  Future<void> _maybeFirstOpen() async {
    if (_firstOpenStarted || !_analyticsAllowed) return;
    _firstOpenStarted = true;
    if (_store.get(_keyFirstOpenDone) != null) return;
    final at = _clock();
    // Referrer yalnız reklam ölçümü izniyle okunur; izin yoksa ilk açılış kanıtsız üretilir.
    if (!_advertisingAllowed) {
      await _completeFirstOpen(at, null);
      return;
    }
    // Okuma sırayı tutmaz: Play servisi yavaşsa olaylar ve izin reddi beklemez.
    _firstOpenRead = _readReferrer().then((params) {
      return _run(() => _completeFirstOpen(at, params));
    });
  }

  Future<AttributionParams?> _readReferrer() async {
    final epoch = _deferredDeepLinkEpoch;
    try {
      final params = await _referrer();
      // Çıkış süren okumadan önceki yolu geçersiz kılar: okuma bitince başka kullanıcıya teslim edilmesin.
      if (epoch != _deferredDeepLinkEpoch && params != null) {
        return AttributionParams(
          frClick: params.frClick,
          utm: params.utm,
          source: params.source,
        );
      }
      return params;
    } on Object catch (error) {
      _log('referrer okunamadı: ${error.runtimeType}');
      return null;
    }
  }

  Future<void> _completeFirstOpen(int at, AttributionParams? params) async {
    if (!_analyticsAllowed) {
      // İzin okuma sırasında geri çekildi: işaret yazılmadı, sonraki onayda yeniden denenir.
      _firstOpenStarted = false;
      return;
    }
    final props = <String, Object?>{};
    final link = _linkEvidence;
    final allowed = _advertisingAllowed;
    if (allowed &&
        params != null &&
        !params.isEmpty &&
        !params.isPlayOrganicDefault) {
      props[_propSource] = params.source;
      params.writeTo(props);
    } else if (allowed && link != null) {
      props[_propSource] = linkSource;
      link.writeTo(props);
    } else {
      props[_propSource] = AttributionSource.none;
    }
    final metaAppId = config.metaAppId;
    if (allowed && metaAppId != null) {
      // Meta reklamından gelen kurulumun şifreli kampanya verisi (Facebook/Instagram uygulaması); sunucu projenin anahtarıyla çözer.
      try {
        final meta = await _metaReferrer(metaAppId);
        if (meta != null && meta.isNotEmpty) props['meta_install_referrer'] = meta;
      } on Object catch (error) {
        _log('meta referrer okunamadı: ${error.runtimeType}');
      }
    }
    // Kurulum mağazası kişisel veri ya da atıf kanıtı değildir: reklam izninden bağımsız eklenir. Okuma hatası ilk açılışı durdurmaz.
    try {
      final store = InstallStore.sanitize(await _installStore());
      if (store != null) props[_propInstallStore] = store;
    } on Object catch (error) {
      _log('kurulum mağazası okunamadı: ${error.runtimeType}');
    }
    // Emülatör işareti yalnız `true` ise eklenir; cihaz kimliği değildir. Okuma hatası ilk açılışı durdurmaz.
    try {
      if (await _emulator() == true) props[_propEmulator] = true;
    } on Object catch (error) {
      _log('emülatör denetimi yapılamadı: ${error.runtimeType}');
    }
    // Dosya deposunda işlem yoktur. Kimlik olaydan önce yazılır: süreç arada ölürse aynı event_id ile
    // yeniden üretilir, kuyruk ve sunucu aynı kimliği tek olay sayar.
    final id = _store.get(_keyFirstOpenId) ?? nextUlid(at);
    await _store.put(_keyFirstOpenId, id);
    // Sonradan gelen izinde lookback gerçek ilk açılışa göre işlesin: izin anı kanıtın yaşını değiştirmemeli.
    await _store.put(_keyFirstOpenAt, '$at');
    await _produce(id, _eventFirstOpen, at, props, null);
    await _store.put(_keyFirstOpenDone, '1');
    if (allowed) {
      final path = params?.deepLinkPath;
      if (path != null) await _store.put(_keyDeferredDeepLink, path);
      await _store.put(_keyReferrerChecked, '1');
    }
    _flushIfForeground();
  }

  /// İlk açılış izinsiz üretildiyse ve reklam ölçümü izni sonradan geldiyse referrer o zaman, kurulumda bir kez okunur.
  /// Sunucu kurulum başına tek `app_first_open` kararı verdiği için kanıt işaretli `deep_link_opened` ile taşınır.
  void _maybeReferrerFollowUp() {
    if (_referrerFollowUpStarted || !_advertisingAllowed) return;
    if (_store.get(_keyFirstOpenDone) == null ||
        _store.get(_keyReferrerChecked) != null) {
      return;
    }
    _referrerFollowUpStarted = true;
    _firstOpenRead = _readReferrer().then((params) {
      return _run(() => _completeReferrerFollowUp(params));
    });
  }

  Future<void> _completeReferrerFollowUp(AttributionParams? params) async {
    _referrerFollowUpStarted = false;
    if (!_advertisingAllowed) return;
    if (params == null || params.isEmpty || params.isPlayOrganicDefault) {
      await _store.put(_keyReferrerChecked, '1');
      return;
    }
    final at = _clock();
    final props = <String, Object?>{
      _propSource: params.source,
      _propFollowUp: true,
    };
    final firstOpenAt = int.tryParse(_store.get(_keyFirstOpenAt) ?? '');
    if (firstOpenAt != null) props[_propFirstOpenAt] = formatTime(firstOpenAt);
    params.writeTo(props);
    final path = params.deepLinkPath;
    if (path != null) await _store.put(_keyDeferredDeepLink, path);
    final id = _store.get(_keyFollowUpId) ?? nextUlid(at);
    await _store.put(_keyFollowUpId, id);
    await _produce(id, _eventDeepLink, at, props, null);
    await _store.put(_keyReferrerChecked, '1');
    _flushIfForeground();
  }

  Future<void> _produce(
    String id,
    String name,
    int at,
    Map<String, Object?> properties,
    String? pageUrl,
  ) async {
    final current = _consent;
    if (current == null || !current.analytics) return;
    // Son güvence: uygulamanın kendi verdiği özellik dahil, fr_click izinsiz hiçbir olaya girmez.
    final safeProperties = Map<String, Object?>.of(properties);
    if (current.advertising != true) safeProperties.remove(_propFrClick);
    // Yapılandırmadaki kod ilk olaya eklenir; uygulamanın olay özelliği olarak verdiği kod dokunulmadan geçer.
    final code = _pendingInstallCode;
    if (code != null) safeProperties[_propInstallCode] = code;
    // Atıf olayları imzalanır (anahtar verildiyse): imza olayın kimliğine ve kurulum kimliğine bağlıdır.
    final key = config.signingKey;
    if (key != null && (name == _eventFirstOpen || name == _eventDeepLink)) {
      safeProperties[EventSigner.property] = EventSigner.sign(
        keyId: key.id,
        secret: key.secret,
        atSeconds: at ~/ 1000,
        eventId: id,
        eventName: name,
        anonymousId: _anonymousId ?? '',
      );
    }
    final payload = encodeEvent(
      eventId: id,
      eventName: name,
      occurredAtMs: at,
      platform: platform,
      sdkName: sdkName,
      sdkVersion: sdkVersion,
      anonymousId: _anonymousId,
      sessionId: _sessionId,
      userId: _userId,
      consent: current,
      properties: safeProperties,
      pageUrl: pageUrl,
      app: _appContext(),
    );
    if (payload.length > _maxEventChars) {
      _log('olay boyut sınırını aşıyor, atıldı: $name');
      return;
    }
    await _store.add(StoredEvent(id, payload), config.queueLimit);
    // Kod yalnız kuyruğa gerçekten giren olayla tüketilir: boyut sınırına takılan olay kodu harcamaz.
    if (code != null && identical(code, _pendingInstallCode)) _pendingInstallCode = null;
    _queued = _store.size;
    _scheduleOrFlush();
  }

  void _scheduleOrFlush() {
    if (_queued >= _batchSize) {
      _attemptFlush(null);
    } else if (_foreground &&
        _queued > 0 &&
        _pendingFlush == null &&
        !_inflight) {
      _scheduleAttempt(config.flushInterval.inMilliseconds);
    }
  }

  void _flushIfForeground() {
    if (_foreground) _attemptFlush(null);
  }

  void _scheduleAttempt(int delayMs) {
    _cancelPending();
    _pendingFlush = _scheduler(Duration(milliseconds: max(delayMs, 0)), () {
      _pendingFlush = null;
      _run(() => _attemptFlush(null));
    });
  }

  void _cancelPending() {
    _pendingFlush?.cancel();
    _pendingFlush = null;
  }

  /// Kuyruğu göndermeyi dener. Açık çağrı üstel bekleyişi atlar; sunucunun Retry-After süresine yine uyulur.
  Future<FlushResult> flush() {
    final completer = Completer<FlushResult>();
    _run(() {
      _notBefore = 0;
      try {
        _attemptFlush(completer);
      } on Object catch (error) {
        _log('gönderim başlatılamadı: ${error.runtimeType}');
        if (!completer.isCompleted) completer.complete(FlushResult.none);
      }
    });
    return completer.future;
  }

  void _attemptFlush(Completer<FlushResult>? completer) {
    final current = _consent;
    if (current == null || !current.analytics) {
      if (current != null) {
        _pinnedBatch = null;
        _run(_store.clear);
        _queued = 0;
      }
      completer?.complete(FlushResult.none);
      return;
    }
    if (_inflight || _queued == 0) {
      completer?.complete(FlushResult.none);
      return;
    }
    final now = _clock();
    final gate = max(_notBefore, _serverNotBefore);
    if (now < gate) {
      if (_foreground) _scheduleAttempt(gate - now);
      completer?.complete(FlushResult.none);
      return;
    }
    _cancelPending();
    final batch = _pinnedBatch ?? _takeBatch();
    final headers = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json, application/problem+json',
      'x-feralin-project-key': config.projectKey,
      'idempotency-key': idempotencyKeyFor(batch.map((e) => e.eventId)),
      'user-agent': '$sdkName/$sdkVersion',
    };
    _inflight = true;
    _inflightRequest = _send(batch, batchBody(now, batch), headers, completer);
  }

  Future<void> _send(
    List<StoredEvent> batch,
    String body,
    Map<String, String> headers,
    Completer<FlushResult>? completer,
  ) async {
    TransportResponse? response;
    try {
      response = await _transport.post(_endpoint, headers, body);
    } on Object catch (error) {
      _log('taşıma hatası: ${error.runtimeType}');
    }
    await _run(() async {
      _inflight = false;
      final result = await _handleResponse(batch, response);
      completer?.complete(result);
      if (_failures == 0 &&
          _queued > 0 &&
          (_foreground || _queued >= _batchSize)) {
        _attemptFlush(null);
      }
    });
    if (completer != null && !completer.isCompleted) {
      completer.complete(FlushResult.none);
    }
  }

  /// 1 MiB gövde sınırına takılmamak için olay sayısı ve karakter bütçesiyle batch keser.
  List<StoredEvent> _takeBatch() {
    final out = <StoredEvent>[];
    var chars = 0;
    for (final event in _store.peek(_batchSize)) {
      if (out.isNotEmpty && chars + event.payload.length > _maxBatchChars) {
        break;
      }
      out.add(event);
      chars += event.payload.length;
    }
    return out;
  }

  Future<FlushResult> _handleResponse(
    List<StoredEvent> batch,
    TransportResponse? response,
  ) async {
    final ids = batch.map((e) => e.eventId);
    final FlushResult result;
    if (response == null) {
      _log('ağ hatası, kuyrukta tutuluyor');
      _pinnedBatch = batch;
      _noteFailure(null);
      result = FlushResult(
        sent: batch.length,
        accepted: 0,
        rejected: 0,
        status: 0,
      );
    } else if (response.status == 202) {
      _pinnedBatch = null;
      await _store.ack(ids);
      _failures = 0;
      _notBefore = 0;
      _serverNotBefore = 0;
      Map<String, Object?>? json;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, Object?>) json = decoded;
      } on FormatException {
        json = null;
      }
      final accepted = json?['accepted'];
      final rejected = json?['rejected'];
      final batchId = json?['batch_id'];
      result = FlushResult(
        sent: batch.length,
        accepted: accepted is int ? accepted : batch.length,
        rejected: rejected is int ? rejected : 0,
        status: 202,
        batchId: batchId is String && batchId.isNotEmpty ? batchId : null,
      );
      _log('gönderildi: kabul=${result.accepted} ret=${result.rejected}');
    } else if (response.status >= 400 &&
        response.status < 500 &&
        response.status != 429) {
      _pinnedBatch = null;
      await _store.ack(ids);
      _log('kalıcı ret: ${response.status}');
      result = FlushResult(
        sent: batch.length,
        accepted: 0,
        rejected: batch.length,
        status: response.status,
      );
    } else {
      _log('geçici hata: ${response.status}');
      _pinnedBatch = batch;
      _noteFailure(response.retryAfterSeconds);
      result = FlushResult(
        sent: batch.length,
        accepted: 0,
        rejected: 0,
        status: response.status,
      );
    }
    _queued = _store.size;
    return result;
  }

  /// Üstel geri çekilme + yarım jitter. Yalnız ön plandayken yeniden denenir; arka planda cihaz uyandırılmaz.
  void _noteFailure(int? retryAfterSeconds) {
    _failures++;
    final shift = min(_failures - 1, _maxBackoffShift);
    final ceiling = min(_baseBackoffMs << shift, _maxBackoffMs);
    final delay = ceiling ~/ 2 + _random.nextInt(ceiling ~/ 2 + 1);
    final now = _clock();
    _notBefore = now + delay;
    if (retryAfterSeconds != null && retryAfterSeconds > 0) {
      _serverNotBefore =
          now + min(retryAfterSeconds, _maxRetryAfterSeconds) * 1000;
    }
    if (_foreground) _scheduleAttempt(max(_notBefore, _serverNotBefore) - now);
  }

  Future<void> onForeground() => _run(() {
    if (_foreground) return;
    final now = _clock();
    _foreground = true;
    if (_lastBackgroundAt > 0 &&
        now - _lastBackgroundAt >= config.sessionTimeout.inMilliseconds) {
      _sessionId = nextUlid(now);
    }
    if (_queued > 0) _attemptFlush(null);
  });

  Future<void> onBackground() => _run(() {
    _foreground = false;
    _lastBackgroundAt = _clock();
    _cancelPending();
    _attemptFlush(null);
  });

  /// Ağ geri geldi: üstel bekleyiş sıfırlanır, sunucunun Retry-After süresi korunur.
  Future<void> onNetworkAvailable() => _run(() {
    if (!_foreground || _queued == 0) return;
    _failures = 0;
    _notBefore = 0;
    _attemptFlush(null);
  });

  FeralinStatus status() => FeralinStatus(
    initialized: true,
    sdk: sdkName,
    version: sdkVersion,
    queued: _queued,
    consent: _consent,
    anonymousId: _anonymousId,
    sessionId: _sessionId,
    userId: _userId,
  );
}
