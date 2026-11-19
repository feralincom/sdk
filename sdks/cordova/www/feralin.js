'use strict';
// Feralin Cordova eklentisi: JS yüzü. Doğrulama burada, davranış yerel çekirdeklerdedir (Android: sdks/android, iOS: sdks/swift).
// Kuyruk, izin, kimlik, idempotency ve yeniden deneme yerel katmandadır. Hiçbir metot uygulamaya hata fırlatmaz ve reddedilen Promise
// döndürmez: yerel katman yoksa ya da hata verirse sonuç güvenli varsayılandır (null, false, boş sonuç).

var SDK_NAME = 'cordova-plugin-feralin';
var SDK_VERSION = '0.1.0';
var SERVICE = 'Feralin';

// Biçimler toplayıcı şeması (packages/schemas/utp/v1/event.schema.json) ve öteki SDK'larla aynıdır.
var EVENT_NAME_PATTERN = /^[a-z][a-z0-9_]*$/;
var PROPERTY_KEY_PATTERN = /^[a-zA-Z][a-zA-Z0-9_]{0,63}$/;
var MAX_PROPERTIES = 100;
var INSTALL_CODE_PATTERN = /^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$/;
var SIGNING_KEY_ID_PATTERN = /^sgn_[a-z0-9]{12,40}$/;
var META_APP_ID_PATTERN = /^[0-9]{5,20}$/;
var CURRENCY_PATTERN = /^[A-Z]{3}$/;
// Kaldırma ölçümü bildiriminin anahtarı (Android FeralinEngine.UNINSTALL_CHECK_KEY, Swift isUninstallCheck ile aynı).
var UNINSTALL_CHECK_KEY = 'fr_uninstall_check';
var PURCHASE_TYPES = ['purchase', 'subscription_start', 'subscription_renew', 'subscription_cancel'];
var RECEIPT_PROVIDERS = ['apple', 'google', 'stripe'];
// İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, toplayıcı da düşürür.
var REVENUE_RESERVED_KEYS = ['verified', 'verification', 'verification_source', 'receipt_provider', 'receipt_digest', 'receipt'];
var DEFERRED_STATUSES = ['delivered', 'none', 'consent_required', 'not_initialized', 'pending', 'not_configured', 'failed'];
var FIRST_OPEN_STATUSES = ['sent', 'automatic', 'already_sent', 'skipped', 'not_initialized'];

function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isPositiveInteger(value) {
  return typeof value === 'number' && Number.isInteger(value) && value > 0;
}

/** Olay adı toplayıcı desenine uyuyorsa adı, uymuyorsa null döner. */
function validEventName(name) {
  return typeof name === 'string' && name.length >= 1 && name.length <= 100 && EVENT_NAME_PATTERN.test(name) ? name : null;
}

/** Değer JSON'a birebir dönüşüyorsa kopyasını, dönüşmüyorsa undefined döner (işlev, sonsuz sayı, döngü). */
function jsonValue(value, depth) {
  if (value === null) return null;
  if (typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number') return Number.isFinite(value) ? value : undefined;
  if (depth > 8) return undefined;
  if (Array.isArray(value)) {
    var list = [];
    for (var i = 0; i < value.length; i++) {
      var item = jsonValue(value[i], depth + 1);
      if (item !== undefined) list.push(item);
    }
    return list;
  }
  if (isObject(value)) {
    var out = {};
    Object.keys(value).forEach(function (key) {
      var child = jsonValue(value[key], depth + 1);
      if (child !== undefined) out[key] = child;
    });
    return out;
  }
  return undefined;
}

/** Özellik anahtarlarını şema desenine göre süzer; en çok 100 özellik. Geçerli özellik yoksa null. */
function sanitizeProperties(properties) {
  if (!isObject(properties)) return null;
  var out = {};
  var count = 0;
  var keys = Object.keys(properties);
  for (var i = 0; i < keys.length && count < MAX_PROPERTIES; i++) {
    var key = keys[i];
    if (!PROPERTY_KEY_PATTERN.test(key)) continue;
    var value = jsonValue(properties[key], 0);
    if (value === undefined) continue;
    out[key] = value;
    count++;
  }
  return count > 0 ? out : null;
}

/** `analytics` zorunlu; öteki alanlar verilmediyse gönderilmez (varsayılan olarak verilmiş sayılmaz). */
function normalizeConsent(consent) {
  if (!isObject(consent) || typeof consent.analytics !== 'boolean') return null;
  var out = { analytics: consent.analytics };
  if (typeof consent.advertising === 'boolean') out.advertising = consent.advertising;
  if (typeof consent.personalization === 'boolean') out.personalization = consent.personalization;
  if (typeof consent.session_replay === 'boolean') out.session_replay = consent.session_replay;
  return out;
}

/**
 * Yapılandırmayı doğrular. Yalnız public anahtar (pk_) kabul edilir; gizli anahtar (sk_) ya da bozuk imza anahtarı yapılandırma
 * hatasıdır ve null döner (yerel katmana hiç gitmez).
 */
function normalizeConfig(config) {
  if (!isObject(config)) return null;
  var projectKey = typeof config.projectKey === 'string' ? config.projectKey.trim() : '';
  if (/^sk_/i.test(projectKey) || projectKey.indexOf('pk_') !== 0 || projectKey.length < 8) return null;
  var collectUrl = typeof config.collectUrl === 'string' ? config.collectUrl.trim() : '';
  if (!/^https?:\/\/[^\s]+$/.test(collectUrl)) return null;
  var out = { projectKey: projectKey, collectUrl: collectUrl, sdkName: SDK_NAME, sdkVersion: SDK_VERSION };
  var consent = normalizeConsent(config.consent);
  if (consent) out.consent = consent;
  ['flushIntervalMs', 'batchSize', 'queueLimit', 'sessionTimeoutMs'].forEach(function (key) {
    if (isPositiveInteger(config[key])) out[key] = config[key];
  });
  ['autoCaptureDeepLinks', 'debug', 'childDirected', 'collectAdvertisingId'].forEach(function (key) {
    if (typeof config[key] === 'boolean') out[key] = config[key];
  });
  if (typeof config.installCode === 'string' && INSTALL_CODE_PATTERN.test(config.installCode.trim())) out.installCode = config.installCode.trim();
  if (typeof config.metaAppId === 'string' && META_APP_ID_PATTERN.test(config.metaAppId.trim())) out.metaAppId = config.metaAppId.trim();
  if (isPositiveInteger(config.consentMaxAgeDays) && config.consentMaxAgeDays <= 3650) out.consentMaxAgeDays = config.consentMaxAgeDays;
  if (config.signingKey !== undefined) {
    var key = config.signingKey;
    if (!isObject(key) || typeof key.id !== 'string' || !SIGNING_KEY_ID_PATTERN.test(key.id) || typeof key.secret !== 'string' ||
        key.secret.length < 16 || key.secret.length > 200) {
      return null;
    }
    out.signingKey = { id: key.id, secret: key.secret };
  }
  if (Array.isArray(config.shortLinkHosts)) {
    out.shortLinkHosts = config.shortLinkHosts.filter(function (host) {
      return typeof host === 'string' && /^[a-z0-9.-]{1,253}$/i.test(host);
    });
  }
  if (isObject(config.attribution) && typeof config.attribution.apiUrl === 'string' && typeof config.attribution.projectId === 'string' &&
      /^https?:\/\/[^\s]+$/.test(config.attribution.apiUrl) && config.attribution.projectId.length > 0) {
    out.attribution = { apiUrl: config.attribution.apiUrl, projectId: config.attribution.projectId };
  }
  return out;
}

/**
 * Gelir olayının özelliklerini sözleşmeye göre kurar (`feralin_purchase`; Web, Android ve Swift ile aynı kurallar); geçersiz girdide
 * null döner ve olay üretilmez. iOS çekirdeğinde ayrı gelir yöntemi olmadığı için iOS köprüsü bu özelliklerle olay üretir.
 */
function buildRevenueProperties(input) {
  if (!isObject(input) || typeof input.transactionId !== 'string' || input.transactionId.length < 1 || input.transactionId.length > 128) return null;
  if (!Number.isSafeInteger(input.amountMinor) || input.amountMinor < 0) return null;
  if (typeof input.currency !== 'string' || !CURRENCY_PATTERN.test(input.currency)) return null;
  if (input.productId !== undefined && (typeof input.productId !== 'string' || input.productId.length < 1 || input.productId.length > 128)) return null;
  var quantity = input.quantity === undefined ? 1 : input.quantity;
  if (!Number.isInteger(quantity) || quantity < 0 || quantity > 100000) return null;
  var purchaseType = input.purchaseType === undefined ? 'purchase' : input.purchaseType;
  if (PURCHASE_TYPES.indexOf(purchaseType) < 0) return null;
  // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
  if (purchaseType === 'subscription_cancel' && input.amountMinor !== 0) return null;
  if (input.receipt !== undefined && (!isObject(input.receipt) || RECEIPT_PROVIDERS.indexOf(input.receipt.provider) < 0 ||
      typeof input.receipt.token !== 'string' || input.receipt.token.length < 1 || input.receipt.token.length > 8192)) {
    return null;
  }
  var props = sanitizeProperties(input.properties) || {};
  REVENUE_RESERVED_KEYS.forEach(function (key) { delete props[key]; });
  props.transaction_id = input.transactionId;
  props.amount_minor = input.amountMinor;
  props.currency = input.currency;
  props.quantity = quantity;
  props.purchase_type = purchaseType;
  if (input.productId !== undefined) props.product_id = input.productId;
  if (input.receipt) props.receipt = { provider: input.receipt.provider, token: input.receipt.token };
  return props;
}

/** Gelen bildirim Feralin'in kaldırma ölçümü bildirimi mi? `true` ise uygulama bildirimi göstermemelidir. */
function isUninstallCheck(data) {
  return isObject(data) && data[UNINSTALL_CHECK_KEY] === '1';
}

function stringOrNull(value) {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

function numberOr(value, fallback) {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

var EMPTY_FLUSH = { sent: 0, accepted: 0, rejected: 0, status: 0, batchId: null };

function toFlushResult(value) {
  if (!isObject(value)) return Object.assign({}, EMPTY_FLUSH);
  return {
    sent: numberOr(value.sent, 0),
    accepted: numberOr(value.accepted, 0),
    rejected: numberOr(value.rejected, 0),
    status: numberOr(value.status, 0),
    batchId: stringOrNull(value.batchId),
  };
}

function toDeferredDeepLink(value) {
  if (!isObject(value) || DEFERRED_STATUSES.indexOf(value.status) < 0) return { status: 'failed', path: null, linkCode: null };
  return { status: value.status, path: stringOrNull(value.path), linkCode: stringOrNull(value.linkCode) };
}

function toLinkOpen(url) {
  return function (value) {
    if (!isObject(value) || typeof value.destination !== 'string') return { destination: fallbackPath(url), linkCode: null, hasClickId: false };
    return { destination: value.destination, linkCode: stringOrNull(value.linkCode), hasClickId: value.hasClickId === true };
  };
}

/** Yerel katman yanıt vermezse uygulamanın gideceği yol: adresin kendi yolu ve sorgusu (Feralin parametresi dahil değildir). */
function fallbackPath(url) {
  var match = typeof url === 'string' ? /^[a-z][a-z0-9+.-]*:\/\/[^/?#]*([^#]*)/i.exec(url) : null;
  var path = match && match[1] ? match[1] : '/';
  return path.charAt(0) === '/' ? path : '/' + path;
}

function toFirstOpen(value) {
  if (!isObject(value) || FIRST_OPEN_STATUSES.indexOf(value.status) < 0) return { status: 'skipped', eventId: null };
  return { status: value.status, eventId: stringOrNull(value.eventId) };
}

function toStatus(value) {
  if (!isObject(value)) return { initialized: false, sdk: SDK_NAME, version: SDK_VERSION, queued: 0, consent: null, anonymousId: null, sessionId: null, userId: null };
  return {
    initialized: value.initialized === true,
    sdk: stringOrNull(value.sdk) || SDK_NAME,
    version: stringOrNull(value.version) || SDK_VERSION,
    queued: numberOr(value.queued, 0),
    consent: normalizeConsent(value.consent),
    anonymousId: stringOrNull(value.anonymousId),
    sessionId: stringOrNull(value.sessionId),
    userId: stringOrNull(value.userId),
  };
}

function eventIdOrNull(value) {
  return stringOrNull(value);
}

function asBoolean(value) {
  return value === true || value === 1 || value === 'true';
}

/**
 * Eklenti yüzünü kurar. `exec` Cordova'nın `cordova/exec` işlevidir; testler sahte işlev verir.
 * @param {(success: Function, failure: Function, service: string, action: string, args: unknown[]) => void} exec
 */
function createFeralin(exec) {
  function call(action, args, fallback, map) {
    return new Promise(function (resolve) {
      var done = false;
      function finish(value) {
        if (done) return;
        done = true;
        try {
          resolve(map ? map(value) : value === undefined || value === null ? fallback : value);
        } catch (error) {
          resolve(fallback);
        }
      }
      try {
        exec(finish, function () {
          if (done) return;
          done = true;
          resolve(map ? map(undefined) : fallback);
        }, SERVICE, action, args);
      } catch (error) {
        if (!done) {
          done = true;
          resolve(map ? map(undefined) : fallback);
        }
      }
    });
  }

  return {
    SDK_NAME: SDK_NAME,
    SDK_VERSION: SDK_VERSION,

    /** SDK'yı başlatır; `true`: SDK etkin. Geçersiz yapılandırmada yerel katman çağrılmaz ve `false` döner. */
    initialize: function (config) {
      var normalized = normalizeConfig(config);
      if (!normalized) return Promise.resolve(false);
      return call('initialize', [normalized], false, asBoolean);
    },

    /** İzin kararını bildirir. `analytics` boolean değilse yok sayılır ve `false` döner. */
    setConsent: function (consent) {
      var normalized = normalizeConsent(consent);
      if (!normalized) return Promise.resolve(false);
      return call('setConsent', [normalized], false, function (value) { return value === undefined ? false : true; });
    },

    /** `setConsent({ analytics: false })` ile aynıdır: kuyruk ve saklı anonim kimlik silinir. */
    optOut: function () {
      return call('setConsent', [{ analytics: false }], false, function (value) { return value === undefined ? false : true; });
    },

    /** Olay üretir ve kuyruğa alır; olay kimliği döner. İzin yoksa, ad geçersizse ya da SDK kapalıysa `null`. */
    track: function (name, properties) {
      var valid = validEventName(name);
      if (!valid) return Promise.resolve(null);
      return call('track', [valid, sanitizeProperties(properties)], null, eventIdOrNull);
    },

    /** `screen_view` olayı. */
    screen: function (name, properties) {
      if (typeof name !== 'string' || name.length < 1 || name.length > 256) return Promise.resolve(null);
      return call('screen', [name, sanitizeProperties(properties)], null, eventIdOrNull);
    },

    /** Uygulamanın kendi opak kullanıcı kimliği (1-128 karakter). E-posta ya da telefon vermeyin. */
    identify: function (userId) {
      if (typeof userId !== 'string' || userId.length < 1 || userId.length > 128) return Promise.resolve(false);
      return call('identify', [userId], false, function (value) { return value === undefined ? false : asBoolean(value); });
    },

    /** Çıkış: kullanıcı kimliği ve global özellikler silinir, oturum ve kurulum kimliği yenilenir. */
    reset: function () {
      return call('reset', [], false, function (value) { return value === undefined ? false : true; });
    },

    /** `fr_group` olayı: grup kimliği 1-128 karakter. */
    group: function (groupId, traits) {
      if (typeof groupId !== 'string' || groupId.length < 1 || groupId.length > 128) return Promise.resolve(null);
      return call('group', [groupId, sanitizeProperties(traits)], null, eventIdOrNull);
    },

    /** `fr_user_properties` olayı; geçerli özellik yoksa olay üretilmez. */
    setUserProperties: function (properties) {
      var props = sanitizeProperties(properties);
      if (!props) return Promise.resolve(null);
      return call('setUserProperties', [props], null, eventIdOrNull);
    },

    /** Sonraki olaylara eklenecek özellikleri birleştirir; kabul edilen anahtar sayısı döner. */
    setGlobalProperties: function (properties) {
      var props = sanitizeProperties(properties);
      if (!props) return Promise.resolve(0);
      return call('setGlobalProperties', [props], 0, function (value) { return numberOr(value, 0); });
    },

    clearGlobalProperties: function () {
      return call('clearGlobalProperties', [], false, function (value) { return value === undefined ? false : true; });
    },

    /** `feralin_purchase` istemci beyanı; doğrulama yalnız sunucudadır. Geçersiz girdide `null`. */
    trackRevenue: function (input) {
      var props = buildRevenueProperties(input);
      if (!props) return Promise.resolve(null);
      var wire = {
        transactionId: input.transactionId,
        amountMinor: input.amountMinor,
        currency: input.currency,
        quantity: props.quantity,
        purchaseType: props.purchase_type,
      };
      if (input.productId !== undefined) wire.productId = input.productId;
      if (input.receipt) wire.receipt = { provider: input.receipt.provider, token: input.receipt.token };
      var extra = sanitizeProperties(input.properties);
      if (extra) wire.properties = extra;
      return call('trackRevenue', [wire, props], null, eventIdOrNull);
    },

    /** Kuyruğu göndermeyi dener. `status` 0 ise istek yapılmadı ya da ağ hatası oluştu. */
    flush: function () {
      return call('flush', [], EMPTY_FLUSH, toFlushResult);
    },

    /**
     * İlk açılış olayı (`app_first_open`). Android çekirdeği bu olayı kendisi üretir (`automatic`); iOS köprüsü kurulum başına bir kez
     * gönderir ve iOS 17.4+ cihazda kurulum kaynağını (`install_store`) ekler. Tıklama kimliği yalnız reklam ölçümü izniyle gider.
     */
    trackFirstOpen: function (options) {
      var args = {};
      if (isObject(options)) {
        if (typeof options.clickId === 'string' && options.clickId.length > 0 && options.clickId.length <= 128) args.clickId = options.clickId;
        if (typeof options.source === 'string' && /^[a-z][a-z0-9_]{0,63}$/.test(options.source)) args.source = options.source;
        if (typeof options.advertisingId === 'string') args.advertisingId = options.advertisingId;
      }
      return call('trackFirstOpen', [args], { status: 'skipped', eventId: null }, toFirstOpen);
    },

    /** iOS: `FeralinInstallSource.current()` (iOS 17.4+). Android: `null`; kurulum mağazasını çekirdek ilk açılışa kendisi ekler. */
    getInstallStore: function () {
      return call('getInstallStore', [], null, stringOrNull);
    },

    /** iOS Universal Link açılışı: `deep_link_opened` olayı gönderilir, uygulamanın gideceği yol döner. Android'de App Link otomatik yakalanır. */
    handleUniversalLink: function (url) {
      if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) return Promise.resolve(toLinkOpen(url)(undefined));
      return call('handleUniversalLink', [url], null, toLinkOpen(url));
    },

    /** Fera Fly kısa linkiyle açılış: link çözümlenir, derin yol döner. */
    handleShortLink: function (url) {
      if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) return Promise.resolve(toLinkOpen(url)(undefined));
      return call('handleShortLink', [url], null, toLinkOpen(url));
    },

    /**
     * Ertelenmiş derin bağlantıyı bir kez verir. `callback` verilirse sonuç ona da iletilir. `path` dışarıdan gelen veridir: uygulama kendi
     * yönlendirme tablosuyla eşleştirmeli, doğrudan yetkili bir eylem çalıştırmamalıdır.
     */
    consumeDeferredDeepLink: function (callback) {
      return call('consumeDeferredDeepLink', [], null, toDeferredDeepLink).then(function (link) {
        if (typeof callback === 'function') {
          try {
            callback(link);
          } catch (error) {
            // Uygulama geri çağrısının hatası SDK sonucunu bozmaz.
          }
        }
        return link;
      });
    },

    /** Push belirtecini bildirir (kaldırma ölçümü): Android'de FCM kayıt belirteci, iOS'ta APNs cihaz belirtecinin onaltılı yazımı. */
    setPushToken: function (token) {
      if (typeof token !== 'string' || token.length < 20 || token.length > 4096) return Promise.resolve(null);
      return call('setPushToken', [token], null, eventIdOrNull);
    },

    isUninstallCheck: isUninstallCheck,

    /** Kurulum kimliği; yalnız reklam ölçümü izniyle üretilir, yoksa `null`. */
    installIdentifier: function () {
      return call('installIdentifier', [], null, stringOrNull);
    },

    getStatus: function () {
      return call('getStatus', [], toStatus(undefined), toStatus);
    },
  };
}

var feralin;
try {
  // Cordova modül sistemi `cordova/exec` modülünü verir; Node testlerinde bulunmaz ve yalnız fabrika dışa aktarılır.
  feralin = createFeralin(require('cordova/exec'));
} catch (error) {
  feralin = null;
}

module.exports = feralin || {};
module.exports.createFeralin = createFeralin;
module.exports.buildRevenueProperties = buildRevenueProperties;
module.exports.normalizeConfig = normalizeConfig;
module.exports.sanitizeProperties = sanitizeProperties;
module.exports.isUninstallCheck = isUninstallCheck;
