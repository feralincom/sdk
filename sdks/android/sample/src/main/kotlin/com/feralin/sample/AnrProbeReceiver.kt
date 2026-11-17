package com.feralin.sample

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Yalnız yerel ANR denemesi (`scripts/e2e-exit-info.mjs`): `onReceive` ana iş parçacığında çalışır ve onu kilitler; ön plan yayını 10 saniyede
 * yanıtsız kalınca sistem arka plandaki süreci ANR nedeniyle (iletişim kutusu olmadan) sonlandırır. Bildirimde `android.permission.DUMP` ister:
 * yalnız adb kabuğu ve sistem gönderebilir, başka uygulama tetikleyemez.
 */
class AnrProbeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        CheckoutFlow.freezeMainThread()
    }
}
