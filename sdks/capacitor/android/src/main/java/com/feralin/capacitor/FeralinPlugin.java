package com.feralin.capacitor;

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
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

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
 * Capacitor Android köprüsü: davranışın tamamı {@code com.feralin.android.Feralin} çekirdeğindedir (sdks/android). Çağrı reddedilmez;
 * hata güvenli varsayılanla çözülür. Logcat'e yalnız hata türü yazılır, yapılandırma ya da özellik değeri yazılmaz.
 *
 * Çekirdek sarmalayıcı platformu ({@code SdkWrapper}) bugün yalnız {@code react_native} kabul ettiği için olaylar {@code platform=android},
 * {@code sdk=feralin-android} ile gider.
 */
@CapacitorPlugin(name = "Feralin")
public class FeralinPlugin extends Plugin {
    private static final String TAG = "FeralinCapacitor";
    private static final String SHORT_LINK_HOST_DEFAULT = "fera.fly";

    private interface Action {
        void run(PluginCall call) throws Exception;
    }

    private void guarded(PluginCall call, JSObject fallback, Action action) {
        try {
            action.run(call);
        } catch (Throwable t) {
            // Yalnız tür yazılır; mesajda yapılandırma ya da özellik değeri olabilir.
            Log.w(TAG, "köprü hatası: " + t.getClass().getSimpleName());
            call.resolve(fallback);
        }
    }

    @PluginMethod
    public void initialize(PluginCall call) {
        guarded(call, new JSObject().put("ready", false), c -> {
            JSObject config = c.getObject("config");
            FeralinConfig parsed = config == null ? null : configFrom(config);
            if (parsed == null) {
                c.resolve(new JSObject().put("ready", false));
                return;
            }
            boolean ready = Feralin.initialize(getContext().getApplicationContext(), parsed);
            // JS, etkinlik açıldıktan sonra çalışır; açılış niyeti yaşam döngüsü dinleyicisini kaçırmış olur. Aynı niyet iki kez sayılmaz.
            if (ready && parsed.getAutoCaptureDeepLinks() && getActivity() != null) Feralin.handleIntent(getActivity().getIntent());
            c.resolve(new JSObject().put("ready", ready));
        });
    }

    @PluginMethod
    public void setConsent(PluginCall call) {
        guarded(call, new JSObject().put("ok", false), c -> {
            Consent consent = consentFrom(c.getObject("consent"));
            if (consent != null) Feralin.setConsent(consent);
            c.resolve(new JSObject().put("ok", consent != null));
        });
    }

    @PluginMethod
    public void track(PluginCall call) {
        guarded(call, eventId(null), c -> c.resolve(eventId(Feralin.track(c.getString("name", ""), mapFrom(c.getObject("properties"))))));
    }

    @PluginMethod
    public void screen(PluginCall call) {
        guarded(call, eventId(null), c -> c.resolve(eventId(Feralin.screen(c.getString("name", ""), mapFrom(c.getObject("properties"))))));
    }

    @PluginMethod
    public void identify(PluginCall call) {
        guarded(call, new JSObject().put("ok", false), c -> {
            Feralin.identify(c.getString("userId", ""));
            c.resolve(new JSObject().put("ok", true));
        });
    }

    @PluginMethod
    public void reset(PluginCall call) {
        guarded(call, new JSObject().put("ok", false), c -> {
            Feralin.reset();
            c.resolve(new JSObject().put("ok", true));
        });
    }

    @PluginMethod
    public void group(PluginCall call) {
        guarded(call, eventId(null), c -> c.resolve(eventId(Feralin.group(c.getString("groupId", ""), mapFrom(c.getObject("traits"))))));
    }

    @PluginMethod
    public void setUserProperties(PluginCall call) {
        guarded(call, eventId(null), c -> {
            Map<String, Object> props = mapFrom(c.getObject("properties"));
            c.resolve(eventId(props == null ? null : Feralin.setUserProperties(props)));
        });
    }

    @PluginMethod
    public void setGlobalProperties(PluginCall call) {
        guarded(call, new JSObject().put("count", 0), c -> c.resolve(new JSObject().put("count", Feralin.setGlobalProperties(mapFrom(c.getObject("properties"))))));
    }

    @PluginMethod
    public void clearGlobalProperties(PluginCall call) {
        guarded(call, new JSObject().put("ok", false), c -> {
            Feralin.clearGlobalProperties();
            c.resolve(new JSObject().put("ok", true));
        });
    }

    @PluginMethod
    public void trackRevenue(PluginCall call) {
        guarded(call, eventId(null), c -> {
            RevenueInput input = revenueFrom(c.getObject("input"));
            c.resolve(eventId(input == null ? null : Feralin.trackRevenue(input)));
        });
    }

    @PluginMethod
    public void flush(PluginCall call) {
        guarded(call, flushToJson(FlushResultEmpty.VALUE), c -> Feralin.flush(result -> {
            c.resolve(flushToJson(result));
            return Unit.INSTANCE;
        }));
    }

    @PluginMethod
    public void trackFirstOpen(PluginCall call) {
        // Android çekirdeği ilk açılışı (install_store, referrer ve App Link kanıtıyla) kendisi üretir.
        guarded(call, new JSObject().put("status", "skipped"), c -> c.resolve(new JSObject()
                .put("status", Feralin.getStatus().getInitialized() ? "automatic" : "not_initialized")
                .put("eventId", JSONObject.NULL)));
    }

    @PluginMethod
    public void getInstallStore(PluginCall call) {
        // Kurulum mağazası ilk açılış olayına çekirdek tarafından eklenir; ayrı okuma yüzü yoktur.
        call.resolve(new JSObject().put("installStore", JSONObject.NULL));
    }

    @PluginMethod
    public void handleUniversalLink(PluginCall call) {
        // App Link niyetleri etkinlik yaşam döngüsünden ve handleOnNewIntent'ten otomatik yakalanır; ikinci olay üretilmez.
        guarded(call, link("/", null, false), c -> c.resolve(link(pathOf(c.getString("url", "")), null, false)));
    }

    @PluginMethod
    public void handleShortLink(PluginCall call) {
        guarded(call, link("/", null, false), c -> Feralin.handleShortLink(c.getString("url"), open -> {
            c.resolve(linkToJson(open));
            return Unit.INSTANCE;
        }));
    }

    @PluginMethod
    public void consumeDeferredDeepLink(PluginCall call) {
        guarded(call, deferred("failed", null), c -> Feralin.consumeDeferredDeepLink(value -> {
            c.resolve(deferredToJson(value));
            return Unit.INSTANCE;
        }));
    }

    @PluginMethod
    public void setPushToken(PluginCall call) {
        guarded(call, eventId(null), c -> c.resolve(eventId(Feralin.setPushToken(c.getString("token", "")))));
    }

    @PluginMethod
    public void installIdentifier(PluginCall call) {
        guarded(call, new JSObject().put("installId", JSONObject.NULL), c -> Feralin.installIdentifier(id -> {
            c.resolve(new JSObject().put("installId", id == null ? JSONObject.NULL : id));
            return Unit.INSTANCE;
        }));
    }

    @PluginMethod
    public void getStatus(PluginCall call) {
        guarded(call, new JSObject().put("initialized", false), c -> c.resolve(statusToJson(Feralin.getStatus())));
    }

    @Override
    protected void handleOnNewIntent(Intent intent) {
        super.handleOnNewIntent(intent);
        try {
            Feralin.handleIntent(intent);
        } catch (Throwable t) {
            Log.w(TAG, "niyet hatası: " + t.getClass().getSimpleName());
        }
    }

    /** Çekirdek başlatılmadığında da flush sonucu aynı biçimde döner. */
    private static final class FlushResultEmpty {
        static final FlushResult VALUE = new FlushResult(0, 0, 0, 0, null);
    }

    /**
     * FeralinConfig alanları (sırayla, sdks/android/feralin/src/main/kotlin/com/feralin/android/Types.kt):
     * projectKey, collectUrl, consent, flushIntervalMs, batchSize, queueLimit, sessionTimeoutMs, autoCaptureDeepLinks, debug, wrapper,
     * installCode, metaAppId, signingKey, childDirected, consentMaxAgeDays, collectAdvertisingId, shortLinkHosts
     * Kotlin varsayılan parametreleri Java'dan kullanılamadığı için yapıcı tam çağrılır; varsayılanlar çekirdekle aynıdır. Alan listesi
     * değişirse test/capacitor.test.mjs bu yorumu Types.kt ile karşılaştırıp başarısız olur.
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

    private static JSObject eventId(String id) {
        return new JSObject().put("eventId", id == null ? JSONObject.NULL : id);
    }

    private static JSObject link(String destination, String linkCode, boolean hasClickId) {
        return new JSObject().put("destination", destination).put("linkCode", linkCode == null ? JSONObject.NULL : linkCode).put("hasClickId", hasClickId);
    }

    private static JSObject deferred(String status, String path) {
        return new JSObject().put("status", status).put("path", path == null ? JSONObject.NULL : path).put("linkCode", JSONObject.NULL);
    }

    private static JSObject flushToJson(FlushResult result) {
        return new JSObject().put("sent", result.getSent()).put("accepted", result.getAccepted()).put("rejected", result.getRejected())
                .put("status", result.getStatus()).put("batchId", result.getBatchId() == null ? JSONObject.NULL : result.getBatchId());
    }

    private static JSObject linkToJson(ShortLinkOpen open) {
        return link(open.getDestination(), open.getLinkCode(), open.getHasClickId());
    }

    private static JSObject deferredToJson(DeferredDeepLink value) {
        String status;
        switch (value.getStatus()) {
            case DELIVERED: status = "delivered"; break;
            case NONE: status = "none"; break;
            case CONSENT_REQUIRED: status = "consent_required"; break;
            default: status = "not_initialized"; break;
        }
        return deferred(status, value.getPath());
    }

    private static JSObject statusToJson(FeralinStatus status) {
        JSObject out = new JSObject()
                .put("initialized", status.getInitialized())
                .put("sdk", status.getSdk())
                .put("version", status.getVersion())
                .put("queued", status.getQueued())
                .put("anonymousId", status.getAnonymousId() == null ? JSONObject.NULL : status.getAnonymousId())
                .put("sessionId", status.getSessionId() == null ? JSONObject.NULL : status.getSessionId())
                .put("userId", status.getUserId() == null ? JSONObject.NULL : status.getUserId());
        Consent consent = status.getConsent();
        if (consent != null) {
            JSObject c = new JSObject().put("analytics", consent.getAnalytics());
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
}
