package com.feralin.unity;

import android.content.Context;
import android.database.Cursor;
import android.net.Uri;

import org.json.JSONObject;

/**
 * Meta Install Referrer: Facebook, Instagram ve Facebook Lite uygulamalarının ContentProvider'ından Meta reklamının şifreli kampanya
 * verisini okur ve Android SDK ile aynı zarfı döndürür: {"r": install_referrer, "ct": 0|1, "ts": saniye, "p": sağlayıcı}. Birden çok
 * uygulama yanıt verirse en yeni etkileşim seçilir. İçerik şifrelidir, burada açılmaz; sunucu projenin anahtarıyla çözer. Hata ya da yanıt
 * yoksa null. Facebook SDK gerekmez. Paket görünürlüğü için Unity Android manifestine `<queries>` eklenmelidir (README).
 * Bu sınıf cihazda sınanmamıştır: Android oyuncu derlemesi bu depoda yoktur.
 */
public final class FeralinMetaReferrer {
    private static final String[] PROVIDERS = {"facebook", "instagram", "facebook_lite"};
    private static final String[] AUTHORITIES = {
        "com.facebook.katana.provider.InstallReferrerProvider",
        "com.instagram.contentprovider.InstallReferrerProvider",
        "com.facebook.lite.provider.InstallReferrerProvider",
    };
    private static final int MAX_REFERRER_CHARS = 7000;

    private FeralinMetaReferrer() {
    }

    public static String read(Context context, String appId) {
        if (context == null || appId == null || !appId.matches("^[0-9]{5,20}$")) return null;
        JSONObject best = null;
        long bestTs = -1L;
        for (int i = 0; i < AUTHORITIES.length; i++) {
            Cursor cursor = null;
            try {
                cursor = context.getContentResolver().query(Uri.parse("content://" + AUTHORITIES[i] + "/" + appId),
                    new String[] {"install_referrer", "is_ct", "actual_timestamp"}, null, null, null);
                if (cursor == null || !cursor.moveToFirst()) continue;
                int ri = cursor.getColumnIndex("install_referrer");
                if (ri < 0 || cursor.isNull(ri)) continue;
                String referrer = cursor.getString(ri);
                if (referrer == null || referrer.trim().isEmpty() || referrer.length() > MAX_REFERRER_CHARS) continue;
                int ci = cursor.getColumnIndex("is_ct");
                int ti = cursor.getColumnIndex("actual_timestamp");
                long ts = ti >= 0 && !cursor.isNull(ti) ? cursor.getLong(ti) : 0L;
                if (ts > bestTs) {
                    JSONObject json = new JSONObject();
                    json.put("r", referrer);
                    json.put("p", PROVIDERS[i]);
                    if (ci >= 0 && !cursor.isNull(ci)) json.put("ct", cursor.getInt(ci));
                    if (ts > 0) json.put("ts", ts);
                    best = json;
                    bestTs = ts;
                }
            } catch (Exception ignored) {
                // Uygulama yüklü değil ya da sağlayıcı izin vermedi: kanıt yoktur.
            } finally {
                if (cursor != null) cursor.close();
            }
        }
        return best == null ? null : best.toString();
    }
}
