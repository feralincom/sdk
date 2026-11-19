package com.feralin.android.internal

import android.content.Context
import android.net.Uri

/**
 * Huawei AppGallery kurulum yönlendiricisi. AppGallery, mağaza linkindeki `referrer` değerini kurulumla birlikte saklar ve içerik
 * sağlayıcısından verir (Huawei AppGallery Connect belgesi: `content://com.huawei.appmarket.commondata/item/5`, sorgu argümanı paket adı).
 * Bağımlılık gerekmez; AppGallery yüklü değilse ya da sürümü eskiyse (10.5.0.300 öncesi `referrer` sütunu yoktur) kanıt yoktur.
 *
 * Sütunlar (belgeye göre): 1 tıklama zamanı, 2 kurulum bitişi, 3 indirme başlangıcı (saniye), 4 ücretli tanıtım izleme kimliği,
 * 5 linkteki `referrer`. Yalnız 5. sütun okunur ve izin listesinden geçer; zaman damgaları ve izleme kimliği okunmaz.
 * Huawei bu sorguyu kullanıcı onayından sonra yapmayı ister: motor yalnız reklam ölçümü izni açıkken çağırır.
 * Gerçek Huawei cihazında denenmedi; sütun sırası belgeden alınmıştır.
 */
internal class HuaweiInstallReferrerSource(private val query: () -> String?) {
    constructor(context: Context) : this({ queryProvider(context) })

    /** Linkteki tıklama kimliği ve UTM; kanıt yoksa null. Okuma hatası kanıt yok sayılır, ilk açılışı durdurmaz. */
    fun read(): AttributionParams? {
        val raw = try {
            query()
        } catch (_: Exception) {
            // AppGallery yok, sağlayıcı görünmüyor ya da erişim reddedildi.
            null
        }
        if (raw.isNullOrBlank() || raw.length > MAX_REFERRER_CHARS) return null
        val params = AttributionParams.parseQuery(raw)
        return if (params.isEmpty) null else params.copy(source = AttributionSource.HUAWEI_INSTALL_REFERRER)
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

/**
 * Mağaza yönlendiricisi zinciri: önce Google Play okunur; Play kanıt vermezse (hizmet yok, organik varsayılan ya da boş) sırayla
 * Galaxy Store'a ve AppGallery'ye sorulur. Play hizmeti olmayan Huawei cihazında Play okuması sonuçsuz kalır ve kanıt AppGallery'den
 * gelir; Galaxy Store'dan kurulan uygulamada Play organik döner ve kanıt Galaxy Store'dan gelir. Hiçbiri kanıt vermezse Play sonucu korunur.
 */
internal class StoreReferrerChain(
    private val play: InstallReferrerSource,
    private val huawei: () -> AttributionParams?,
    private val samsung: InstallReferrerSource? = null,
) : InstallReferrerSource {
    override fun read(callback: (AttributionParams?) -> Unit) {
        play.read { params ->
            if (params != null && !params.isEmpty && !params.isPlayOrganicDefault) {
                callback(params)
            } else if (samsung == null) {
                callback(huawei() ?: params)
            } else {
                samsung.read { fromSamsung -> callback(fromSamsung ?: huawei() ?: params) }
            }
        }
    }
}
