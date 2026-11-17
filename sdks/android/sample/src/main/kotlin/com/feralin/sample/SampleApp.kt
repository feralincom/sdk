package com.feralin.sample

import android.app.Application
import android.content.Context
import com.feralin.android.Consent
import com.feralin.android.Feralin
import com.feralin.android.FeralinConfig

/**
 * SDK izin kararını saklamaz; kararın sahibi uygulamadır (veya CMP'si). Örnek bunu kendi tercih dosyasında tutar
 * ve her açılışta SDK'ya bildirir. Karar yoksa `consent = null` ile izin bekleniyor durumunda başlar.
 */
class SampleApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Feralin.initialize(
            this,
            FeralinConfig(
                projectKey = BuildConfig.PROJECT_KEY,
                collectUrl = BuildConfig.COLLECT_URL,
                consent = storedConsent(this),
                debug = BuildConfig.DEBUG,
                // Kod verildiyse SDK onu kuyruğa giren ilk olaya ekler; doğrulama ekranı yalnız o olayı kanıt sayar.
                installCode = BuildConfig.INSTALL_CODE.ifEmpty { null },
            ),
        )
        Feralin.captureUncaughtExceptions()
        // API 30+: önceki açılışın ANR ve yerel çökme kaydı; daha eski sürümde false döner, bir şey yapmaz.
        Feralin.captureAnrAndNativeCrashes()
    }

    companion object {
        private const val PREFS = "sample_consent"
        private const val KEY_ANALYTICS = "analytics"
        private const val KEY_ADVERTISING = "advertising"

        fun storedConsent(context: Context): Consent? {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (!prefs.contains(KEY_ANALYTICS)) return null
            val advertising = if (prefs.contains(KEY_ADVERTISING)) prefs.getBoolean(KEY_ADVERTISING, false) else null
            return Consent(analytics = prefs.getBoolean(KEY_ANALYTICS, false), advertising = advertising)
        }

        fun storeConsent(context: Context, consent: Consent) {
            val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putBoolean(KEY_ANALYTICS, consent.analytics)
            val advertising = consent.advertising
            if (advertising == null) editor.remove(KEY_ADVERTISING) else editor.putBoolean(KEY_ADVERTISING, advertising)
            editor.apply()
        }
    }
}
