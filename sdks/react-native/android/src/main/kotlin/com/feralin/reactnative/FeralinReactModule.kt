package com.feralin.reactnative

import android.app.Activity
import android.content.Intent
import android.util.Log
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.feralin.android.Feralin

/**
 * JS yüzeyi; davranışın tamamı `com.feralin.android.Feralin` çekirdeğindedir. Promise reddedilmez, hata uygulamaya geçmez.
 * Modül yeni mimaride birlikte çalışma katmanıyla yüklenir.
 */
internal class FeralinReactModule(private val context: ReactApplicationContext) :
    ReactContextBaseJavaModule(context),
    ActivityEventListener {

    override fun getName(): String = NAME

    init {
        context.addActivityEventListener(this)
    }

    @ReactMethod
    fun initialize(config: ReadableMap, promise: Promise) = guarded(promise, false) {
        val parsed = BridgeMapping.configFrom(config.toHashMap())
        if (parsed == null) {
            false
        } else {
            val ready = Feralin.initialize(context.applicationContext, parsed)
            // JS, etkinlik açıldıktan sonra çalıştığı için ilk App Link niyeti yaşam döngüsü dinleyicisini kaçırmış olur.
            if (ready && parsed.autoCaptureDeepLinks) Feralin.handleIntent(context.currentActivity?.intent)
            ready
        }
    }

    @ReactMethod
    fun setConsent(consent: ReadableMap) = quiet {
        BridgeMapping.consentFrom(consent.toHashMap())?.let(Feralin::setConsent)
    }

    @ReactMethod
    fun optOut() = quiet { Feralin.optOut() }

    @ReactMethod
    fun track(name: String, properties: ReadableMap?, promise: Promise) = guarded(promise, null) {
        Feralin.track(name, BridgeMapping.propertiesFrom(properties?.toHashMap()))
    }

    @ReactMethod
    fun screen(name: String, properties: ReadableMap?, promise: Promise) = guarded(promise, null) {
        Feralin.screen(name, BridgeMapping.propertiesFrom(properties?.toHashMap()))
    }

    @ReactMethod
    fun identify(userId: String) = quiet { Feralin.identify(userId) }

    @ReactMethod
    fun reset() = quiet { Feralin.reset() }

    @ReactMethod
    fun flush(promise: Promise) {
        try {
            Feralin.flush { result -> promise.resolve(Arguments.makeNativeMap(BridgeMapping.flushToMap(result))) }
        } catch (t: Throwable) {
            Log.w(NAME, "flush hatası: ${t.javaClass.simpleName}")
            promise.resolve(Arguments.createMap())
        }
    }

    @ReactMethod
    fun consumeDeferredDeepLink(promise: Promise) {
        try {
            Feralin.consumeDeferredDeepLink { link -> promise.resolve(Arguments.makeNativeMap(BridgeMapping.deferredDeepLinkToMap(link))) }
        } catch (t: Throwable) {
            Log.w(NAME, "derin bağlantı hatası: ${t.javaClass.simpleName}")
            promise.resolve(null)
        }
    }

    @ReactMethod
    fun handleShortLink(url: String, promise: Promise) {
        try {
            Feralin.handleShortLink(url) { open -> promise.resolve(Arguments.makeNativeMap(BridgeMapping.shortLinkOpenToMap(open))) }
        } catch (t: Throwable) {
            Log.w(NAME, "kısa link hatası: ${t.javaClass.simpleName}")
            promise.resolve(null)
        }
    }

    @ReactMethod
    fun getStatus(promise: Promise) = guarded(promise, null) {
        Arguments.makeNativeMap(BridgeMapping.statusToMap(Feralin.getStatus()))
    }

    override fun onNewIntent(intent: Intent) = quiet { Feralin.handleIntent(intent) }

    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) = Unit

    override fun invalidate() {
        context.removeActivityEventListener(this)
        super.invalidate()
    }

    private inline fun guarded(promise: Promise, fallback: Any?, block: () -> Any?) {
        val value = try {
            block()
        } catch (t: Throwable) {
            // Yalnız tür yazılır; mesajda yapılandırma değeri olabilir.
            Log.w(NAME, "köprü hatası: ${t.javaClass.simpleName}")
            fallback
        }
        promise.resolve(value)
    }

    private inline fun quiet(block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            Log.w(NAME, "köprü hatası: ${t.javaClass.simpleName}")
        }
    }

    companion object {
        const val NAME = "FeralinReactNative"
    }
}
