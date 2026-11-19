package com.feralin.cordova;

import android.content.Intent;
import android.util.Log;

import com.feralin.android.Consent;
import com.feralin.android.DeferredDeepLink;
import com.feralin.android.Feralin;
import com.feralin.android.FeralinConfig;
import com.feralin.android.FeralinStatus;
import com.feralin.android.FlushResult;
import com.feralin.android.PurchaseType;
import com.feralin.android.Receipt;
import com.feralin.android.RevenueInput;
import com.feralin.android.ShortLinkOpen;
import com.feralin.android.SigningKey;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import kotlin.Unit;

/**
 * Cordova köprüsü: davranışın tamamı {@code com.feralin.android.Feralin} çekirdeğindedir (sdks/android). Hata JS'e reddedilmiş sonuç
 * olarak geçmez; her eylem güvenli varsayılanla sonuçlanır. Logcat'e yalnız hata türü yazılır, yapılandırma ya da özellik değeri yazılmaz.
 *
 * Çekirdek sarmalayıcı platformu ({@code SdkWrapper}) bugün yalnız {@code react_native} kabul ettiği için olaylar {@code platform=android},
 * {@code sdk=feralin-android} ile gider; ayrı Cordova platform değeri toplayıcı şemasına eklenince sarmalayıcı burada verilir.
 */
public class FeralinPlugin extends CordovaPlugin {
    private static final String TAG = "FeralinCordova";
    private static final String SHORT_LINK_HOST_DEFAULT = "fera.fly";

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callback) {
        try {
            switch (action) {
                case "initialize":
                    initialize(args.optJSONObject(0), callback);
                    return true;
                case "setConsent": {
                    Consent consent = consentFrom(args.optJSONObject(0));
                    if (consent != null) Feralin.setConsent(consent);
                    sendBoolean(callback, consent != null);
                    return true;
                }
                case "track":
                    sendString(callback, Feralin.track(args.getString(0), mapFrom(args.optJSONObject(1))));
                    return true;
                case "screen":
                    sendString(callback, Feralin.screen(args.getString(0), mapFrom(args.optJSONObject(1))));
                    return true;
                case "identify":
                    Feralin.identify(args.getString(0));
                    sendBoolean(callback, true);
                    return true;
                case "reset":
                    Feralin.reset();
                    sendBoolean(callback, true);
                    return true;
                case "group":
                    sendString(callback, Feralin.group(args.getString(0), mapFrom(args.optJSONObject(1))));
                    return true;
                case "setUserProperties": {
                    Map<String, Object> props = mapFrom(args.optJSONObject(0));
                    sendString(callback, props == null ? null : Feralin.setUserProperties(props));
                    return true;
                }
                case "setGlobalProperties":
                    callback.sendPluginResult(new PluginResult(PluginResult.Status.OK, Feralin.setGlobalProperties(mapFrom(args.optJSONObject(0)))));
                    return true;
                case "clearGlobalProperties":
                    Feralin.clearGlobalProperties();
                    sendBoolean(callback, true);
                    return true;
                case "trackRevenue": {
                    RevenueInput input = revenueFrom(args.optJSONObject(0));
                    sendString(callback, input == null ? null : Feralin.trackRevenue(input));
                    return true;
                }
                case "flush":
                    Feralin.flush(result -> {
                        callback.success(flushToJson(result));
                        return Unit.INSTANCE;
                    });
                    return true;
                case "trackFirstOpen":
                    // Android çekirdeği ilk açılışı (install_store, referrer ve App Link kanıtıyla) kendisi üretir.
                    callback.success(new JSONObject().put("status", Feralin.getStatus().getInitialized() ? "automatic" : "not_initialized"));
                    return true;
                case "getInstallStore":
                    // Kurulum mağazası ilk açılış olayına çekirdek tarafından eklenir; ayrı okuma yüzü yoktur.
                    sendString(callback, null);
                    return true;
                case "handleUniversalLink":
                    // App Link niyetleri etkinlik yaşam döngüsünden ve onNewIntent'ten otomatik yakalanır; ikinci olay üretilmez.
                    callback.success(new JSONObject().put("destination", pathOf(args.getString(0))).put("linkCode", JSONObject.NULL).put("hasClickId", false));
                    return true;
                case "handleShortLink":
                    Feralin.handleShortLink(args.getString(0), open -> {
                        callback.success(linkToJson(open));
                        return Unit.INSTANCE;
                    });
                    return true;
                case "consumeDeferredDeepLink":
                    Feralin.consumeDeferredDeepLink(link -> {
                        callback.success(deferredToJson(link));
                        return Unit.INSTANCE;
                    });
                    return true;
                case "setPushToken":
                    sendString(callback, Feralin.setPushToken(args.getString(0)));
                    return true;
                case "installIdentifier":
                    Feralin.installIdentifier(id -> {
                        sendString(callback, id);
                        return Unit.INSTANCE;
                    });
                    return true;
                case "getStatus":
                    callback.success(statusToJson(Feralin.getStatus()));
                    return true;
                default:
                    return false;
            }
        } catch (Throwable t) {
            // Yalnız tür yazılır; mesajda yapılandırma ya da özellik değeri olabilir.
            Log.w(TAG, "köprü hatası: " + t.getClass().getSimpleName());
            callback.error("bridge_error");
            return true;
        }
    }

    @Override
    public void onNewIntent(Intent intent) {
        try {
            Feralin.handleIntent(intent);
        } catch (Throwable t) {
            Log.w(TAG, "niyet hatası: " + t.getClass().getSimpleName());
        }
    }

    private void initialize(JSONObject config, CallbackContext callback) throws JSONException {
        FeralinConfig parsed = config == null ? null : configFrom(config);
        if (parsed == null) {
            sendBoolean(callback, false);
            return;
        }
        boolean ready = Feralin.initialize(cordova.getActivity().getApplicationContext(), parsed);
        // JS, etkinlik açıldıktan sonra çalışır; açılış niyeti yaşam döngüsü dinleyicisini kaçırmış olur. Aynı niyet iki kez sayılmaz.
        if (ready && parsed.getAutoCaptureDeepLinks()) Feralin.handleIntent(cordova.getActivity().getIntent());
        sendBoolean(callback, ready);
    }

    /**
     * FeralinConfig alanları (sırayla, sdks/android/feralin/src/main/kotlin/com/feralin/android/Types.kt):
     * projectKey, collectUrl, consent, flushIntervalMs, batchSize, queueLimit, sessionTimeoutMs, autoCaptureDeepLinks, debug, wrapper,
     * installCode, metaAppId, signingKey, childDirected, consentMaxAgeDays, collectAdvertisingId, shortLinkHosts
     * Kotlin varsayılan parametreleri Java'dan kullanılamadığı için yapıcı tam çağrılır; varsayılanlar çekirdekle aynıdır. Alan listesi
     * değişirse test/feralin.test.mjs bu yorumu Types.kt ile karşılaştırıp başarısız olur.
     */
    static FeralinConfig configFrom(JSONObject map) throws JSONException {
        String projectKey = map.optString("projectKey", "");
        String collectUrl = map.optString("collectUrl", "");
        if (projectKey.isEmpty() || collectUrl.isEmpty()) return null;
        SigningKey signingKey = null;
        JSONObject key = map.optJSONObject("signingKey");
        if (key != null) {
            if (!key.has("id") || !key.has("secret")) return null;
            signingKey = new SigningKey(key.getString("id"), key.getString("secret"));
        }
        List<String> hosts = Collections.singletonList(SHORT_LINK_HOST_DEFAULT);
        JSONArray hostArray = map.optJSONArray("shortLinkHosts");
        if (hostArray != null) {
            hosts = new ArrayList<>();
            for (int i = 0; i < hostArray.length(); i++) hosts.add(hostArray.getString(i));
        }
        Integer consentMaxAgeDays = map.has("consentMaxAgeDays") ? map.getInt("consentMaxAgeDays") : null;
        return new FeralinConfig(
                projectKey,
                collectUrl,
                consentFrom(map.optJSONObject("consent")),
                map.optLong("flushIntervalMs", 15_000L),
                map.optInt("batchSize", 50),
                map.optInt("queueLimit", 1_000),
                map.optLong("sessionTimeoutMs", 30L * 60L * 1_000L),
                map.optBoolean("autoCaptureDeepLinks", true),
                map.optBoolean("debug", false),
                null,
                optStringOrNull(map, "installCode"),
                optStringOrNull(map, "metaAppId"),
                signingKey,
                map.optBoolean("childDirected", false),
                consentMaxAgeDays,
                map.optBoolean("collectAdvertisingId", false),
                hosts);
    }

    /** {@code analytics} yoksa izin bilinmiyor sayılır; öteki alanlar verilmediyse {@code null} kalır. */
    static Consent consentFrom(JSONObject map) {
        if (map == null || !(map.opt("analytics") instanceof Boolean)) return null;
        return new Consent(map.optBoolean("analytics"), optBoolean(map, "advertising"), optBoolean(map, "personalization"), optBoolean(map, "session_replay"));
    }

    static RevenueInput revenueFrom(JSONObject map) throws JSONException {
        if (map == null) return null;
        PurchaseType type;
        switch (map.optString("purchaseType", "purchase")) {
            case "purchase": type = PurchaseType.PURCHASE; break;
            case "subscription_start": type = PurchaseType.SUBSCRIPTION_START; break;
            case "subscription_renew": type = PurchaseType.SUBSCRIPTION_RENEW; break;
            case "subscription_cancel": type = PurchaseType.SUBSCRIPTION_CANCEL; break;
            default: return null;
        }
        Receipt receipt = null;
        JSONObject raw = map.optJSONObject("receipt");
        if (raw != null) {
            Receipt.Provider provider;
            switch (raw.optString("provider")) {
                case "apple": provider = Receipt.Provider.APPLE; break;
                case "google": provider = Receipt.Provider.GOOGLE; break;
                case "stripe": provider = Receipt.Provider.STRIPE; break;
                default: return null;
            }
            receipt = new Receipt(provider, raw.getString("token"));
        }
        return new RevenueInput(
                map.getString("transactionId"),
                map.getLong("amountMinor"),
                map.getString("currency"),
                optStringOrNull(map, "productId"),
                map.optInt("quantity", 1),
                type,
                receipt,
                mapFrom(map.optJSONObject("properties")));
    }

    /** JSON nesnesini çekirdeğin beklediği haritaya çevirir; tam sayılar Integer/Long, kesirli sayılar Double kalır. */
    static Map<String, Object> mapFrom(JSONObject json) {
        if (json == null) return null;
        Map<String, Object> out = new LinkedHashMap<>();
        Iterator<String> keys = json.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            out.put(key, valueFrom(json.opt(key)));
        }
        return out;
    }

    private static Object valueFrom(Object value) {
        if (value == null || value == JSONObject.NULL) return null;
        if (value instanceof JSONObject) return mapFrom((JSONObject) value);
        if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value;
            List<Object> list = new ArrayList<>(array.length());
            for (int i = 0; i < array.length(); i++) list.add(valueFrom(array.opt(i)));
            return list;
        }
        if (value instanceof Double) {
            double number = (Double) value;
            if (number % 1.0 == 0.0 && Math.abs(number) <= 9_007_199_254_740_991.0) return (long) number;
        }
        return value;
    }

    private static JSONObject flushToJson(FlushResult result) {
        JSONObject out = new JSONObject();
        try {
            out.put("sent", result.getSent()).put("accepted", result.getAccepted()).put("rejected", result.getRejected())
                    .put("status", result.getStatus()).put("batchId", result.getBatchId() == null ? JSONObject.NULL : result.getBatchId());
        } catch (JSONException ignored) {
            // Sabit anahtarlarla put hata vermez.
        }
        return out;
    }

    private static JSONObject linkToJson(ShortLinkOpen open) {
        JSONObject out = new JSONObject();
        try {
            out.put("destination", open.getDestination()).put("linkCode", open.getLinkCode() == null ? JSONObject.NULL : open.getLinkCode())
                    .put("hasClickId", open.getHasClickId());
        } catch (JSONException ignored) {
            // Sabit anahtarlarla put hata vermez.
        }
        return out;
    }

    private static JSONObject deferredToJson(DeferredDeepLink link) {
        String status;
        switch (link.getStatus()) {
            case DELIVERED: status = "delivered"; break;
            case NONE: status = "none"; break;
            case CONSENT_REQUIRED: status = "consent_required"; break;
            default: status = "not_initialized"; break;
        }
        JSONObject out = new JSONObject();
        try {
            out.put("status", status).put("path", link.getPath() == null ? JSONObject.NULL : link.getPath()).put("linkCode", JSONObject.NULL);
        } catch (JSONException ignored) {
            // Sabit anahtarlarla put hata vermez.
        }
        return out;
    }

    private static JSONObject statusToJson(FeralinStatus status) throws JSONException {
        JSONObject out = new JSONObject()
                .put("initialized", status.getInitialized())
                .put("sdk", status.getSdk())
                .put("version", status.getVersion())
                .put("queued", status.getQueued())
                .put("anonymousId", status.getAnonymousId() == null ? JSONObject.NULL : status.getAnonymousId())
                .put("sessionId", status.getSessionId() == null ? JSONObject.NULL : status.getSessionId())
                .put("userId", status.getUserId() == null ? JSONObject.NULL : status.getUserId());
        Consent consent = status.getConsent();
        if (consent != null) {
            JSONObject c = new JSONObject().put("analytics", consent.getAnalytics());
            if (consent.getAdvertising() != null) c.put("advertising", consent.getAdvertising());
            if (consent.getPersonalization() != null) c.put("personalization", consent.getPersonalization());
            if (consent.getSessionReplay() != null) c.put("session_replay", consent.getSessionReplay());
            out.put("consent", c);
        }
        return out;
    }

    private static String pathOf(String url) {
        try {
            String path = new java.net.URI(url).getRawPath();
            return path == null || path.isEmpty() ? "/" : path;
        } catch (Exception e) {
            return "/";
        }
    }

    private static Boolean optBoolean(JSONObject map, String key) {
        Object value = map.opt(key);
        return value instanceof Boolean ? (Boolean) value : null;
    }

    private static String optStringOrNull(JSONObject map, String key) {
        Object value = map.opt(key);
        if (!(value instanceof String)) return null;
        String trimmed = ((String) value).trim();
        return trimmed.isEmpty() ? null : trimmed;
    }

    private static void sendString(CallbackContext callback, String value) {
        callback.sendPluginResult(new PluginResult(PluginResult.Status.OK, value));
    }

    private static void sendBoolean(CallbackContext callback, boolean value) {
        callback.sendPluginResult(new PluginResult(PluginResult.Status.OK, value));
    }
}
