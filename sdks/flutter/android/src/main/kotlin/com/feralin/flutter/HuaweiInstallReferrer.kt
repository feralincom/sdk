package com.feralin.flutter

import android.content.Context
import android.net.Uri

/**
 * Huawei AppGallery kurulum yönlendiricisi. AppGallery, mağaza linkindeki `referrer` değerini kurulumla birlikte saklar ve içerik
 * sağlayıcısından verir (Huawei AppGallery Connect belgesi: `content://com.huawei.appmarket.commondata/item/5`, sorgu argümanı paket adı).
 * Bağımlılık gerekmez; AppGallery yüklü değilse ya da sürümü eskiyse (10.5.0.300 öncesi `referrer` sütunu yoktur) kanıt yoktur.
 *
 * Sütunlar (belgeye göre): 1 tıklama zamanı, 2 kurulum bitişi, 3 indirme başlangıcı (saniye), 4 ücretli tanıtım izleme kimliği,
 * 5 linkteki `referrer`. Yalnız 5. sütun okunur ve izin listesinden geçer; zaman damgaları ve izleme kimliği okunmaz, ham dizgi Dart'a
 * geçmez. Huawei bu sorguyu kullanıcı onayından sonra yapmayı ister: Dart çekirdeği yalnız reklam ölçümü izni açıkken çağırır.
 * Davranış Android SDK ile aynıdır (sdks/android `HuaweiInstallReferrerSource`). Gerçek Huawei cihazında denenmedi; sütun sırası
 * belgeden alınmıştır.
 */
internal class HuaweiInstallReferrer(private val query: () -> String?) {
    constructor(context: Context) : this({ queryProvider(context) })

    /** Linkteki izinli parametreler (`fr_click`, `fr_dl`, `utm_*`); kanıt yoksa null. Okuma hatası kanıt yok sayılır. */
    fun read(): Map<String, String>? {
        val raw = try {
            query()
        } catch (_: Exception) {
            // AppGallery yok, sağlayıcı görünmüyor ya da erişim reddedildi.
            null
        }
        if (raw.isNullOrBlank() || raw.length > MAX_REFERRER_CHARS) return null
        val params = ReferrerParams.parse(raw)
        // Tıklama kimliği ya da UTM yoksa kanıt yoktur; `fr_dl` tek başına Feralin linkinden gelmemiştir.
        return if (params.keys.none { it != "fr_dl" }) null else params
    }

    companion object {
        const val AUTHORITY = "com.huawei.appmarket.commondata"
        private const val REFERRER_COLUMN = 5

        // AppGallery linkindeki referrer en çok 500 karakterdir; daha uzunu bizim linkimizden gelmemiştir.
        private const val MAX_REFERRER_CHARS = 2_000

        private fun queryProvider(context: Context): String? {
            val uri = Uri.parse("content://$AUTHORITY/item/5")
            context.contentResolver.query(uri, null, null, arrayOf(context.packageName), null)?.use { cursor ->
                if (!cursor.moveToFirst() || cursor.columnCount <= REFERRER_COLUMN || cursor.isNull(REFERRER_COLUMN)) return null
                return cursor.getString(REFERRER_COLUMN)
            }
            return null
        }
    }
}
