package com.feralin.unity;

import android.content.Context;
import android.database.Cursor;
import android.net.Uri;

/**
 * Huawei AppGallery kurulum yönlendiricisi. AppGallery, mağaza linkindeki `referrer` değerini kurulumla birlikte saklar ve içerik
 * sağlayıcısından verir (Huawei AppGallery Connect belgesi: `content://com.huawei.appmarket.commondata/item/5`, sorgu argümanı paket adı).
 * AppGallery yüklü değilse ya da sürümü eskiyse (10.5.0.300 öncesi `referrer` sütunu yoktur) null döner.
 *
 * Sütunlar (belgeye göre): 1 tıklama zamanı, 2 kurulum bitişi, 3 indirme başlangıcı (saniye), 4 ücretli tanıtım izleme kimliği,
 * 5 linkteki `referrer`. Yalnız 5. sütun okunur; zaman damgaları ve izleme kimliği okunmaz. Dizgi C# çekirdeğinde izin listesinden geçer
 * ve saklanmaz. Huawei bu sorguyu kullanıcı onayından sonra yapmayı ister: çekirdek yalnız reklam ölçümü izni açıkken çağırır.
 * Paket görünürlüğü için Unity Android manifestine `<queries>` eklenmelidir (README).
 * Bu sınıf cihazda sınanmamıştır: Android oyuncu derlemesi bu depoda yoktur; sütun sırası belgeden alınmıştır.
 */
public final class FeralinHuaweiReferrer {
    private static final String AUTHORITY = "com.huawei.appmarket.commondata";
    private static final int REFERRER_COLUMN = 5;
    private static final int MAX_REFERRER_CHARS = 2000;

    private FeralinHuaweiReferrer() {
    }

    public static String read(Context context) {
        if (context == null) return null;
        Cursor cursor = null;
        try {
            cursor = context.getContentResolver().query(Uri.parse("content://" + AUTHORITY + "/item/5"), null, null,
                new String[] {context.getPackageName()}, null);
            if (cursor == null || !cursor.moveToFirst() || cursor.getColumnCount() <= REFERRER_COLUMN || cursor.isNull(REFERRER_COLUMN)) return null;
            String referrer = cursor.getString(REFERRER_COLUMN);
            if (referrer == null || referrer.trim().isEmpty() || referrer.length() > MAX_REFERRER_CHARS) return null;
            return referrer;
        } catch (Exception ignored) {
            // AppGallery yok, sağlayıcı görünmüyor ya da erişim reddedildi: kanıt yoktur.
            return null;
        } finally {
            if (cursor != null) cursor.close();
        }
    }
}
