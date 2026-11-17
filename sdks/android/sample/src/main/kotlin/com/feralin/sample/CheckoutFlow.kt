package com.feralin.sample

import com.feralin.android.Feralin

/**
 * Hata ve ANR denemeleri için ayrı sınıf: R8 bu sınıfı ve yöntemlerini karartır (Activity gibi bildirimde adı geçmez), böylece panelde
 * karartılmış çerçevenin yüklenen mapping.txt ile özgün ada çözüldüğü görülür. Yalnız örnek uygulamadadır.
 */
object CheckoutFlow {
    /** Yakalanan hata: `fr_error` (`origin: handled`), çerçeve konumlarıyla. */
    fun reportHandled() {
        try {
            validateTotal(-1)
        } catch (error: IllegalArgumentException) {
            Feralin.captureError(error)
        }
    }

    private fun validateTotal(total: Int) {
        require(total >= 0) { "toplam negatif olamaz" }
    }

    /**
     * Ana iş parçacığını 30 saniye kilitler: dokunma olayı 5 saniye yanıtsız kalınca sistem ANR kaydeder. Uygulama kapatılınca sonraki açılışta
     * SDK kaydı `fr_error` (`origin: anr`) olarak gönderir.
     */
    fun freezeMainThread() {
        holdLock(System.currentTimeMillis() + 30_000L)
    }

    private fun holdLock(until: Long) {
        while (System.currentTimeMillis() < until) {
            Thread.sleep(200L)
        }
    }
}
