package com.feralin.android.internal

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle

/**
 * Süreç ön plan/arka plan geçişi ve App Link yakalama; androidx.lifecycle bağımlılığı gerektirmez.
 * Yapılandırma değişiminde (döndürme) durma sayılmaz; böylece yalancı arka plan geçişi ve oturum üretilmez.
 */
internal class AppLifecycleTracker(
    private val onForeground: () -> Unit,
    private val onBackground: () -> Unit,
    private val onIntent: (Intent) -> Unit,
    private val captureLinks: Boolean,
) : Application.ActivityLifecycleCallbacks {
    private val started = HashSet<Int>()
    private var foreground = false

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        // Durum geri yüklemesinde niyet eski açılışa aittir; aynı bağlantı ikinci kez sayılmaz.
        if (savedInstanceState != null) IntentLinks.markHandled(activity.intent)
    }

    override fun onActivityStarted(activity: Activity) {
        started.add(System.identityHashCode(activity))
        if (!foreground) {
            foreground = true
            onForeground()
        }
    }

    override fun onActivityResumed(activity: Activity) {
        if (captureLinks) activity.intent?.let(onIntent)
    }

    override fun onActivityStopped(activity: Activity) {
        started.remove(System.identityHashCode(activity))
        if (started.isEmpty() && foreground && !activity.isChangingConfigurations) {
            foreground = false
            onBackground()
        }
    }

    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}

internal object IntentLinks {
    private const val HANDLED_EXTRA = "com.feralin.android.LINK_HANDLED"

    fun markHandled(intent: Intent?) {
        intent?.putExtra(HANDLED_EXTRA, true)
    }

    /** İşlenmemiş VIEW niyetinin URL'ini verir ve niyeti işaretler; geçmişten açılış ve yinelenen teslim elenir. */
    fun consume(intent: Intent): String? {
        if (intent.action != Intent.ACTION_VIEW) return null
        if (intent.getBooleanExtra(HANDLED_EXTRA, false)) return null
        markHandled(intent)
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        return intent.dataString
    }
}
