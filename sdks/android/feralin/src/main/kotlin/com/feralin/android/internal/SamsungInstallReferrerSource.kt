package com.feralin.android.internal

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.Parcel
import java.util.concurrent.atomic.AtomicBoolean

/** Galaxy Store servisine ince soyutlama; testlerde cihaz ve Galaxy Store olmadan yanıtlar sınanır. */
internal interface SamsungReferrerConnection {
    /** [onReferrer] en çok bir kez çağrılır: yönlendirici dizgisiyle ya da kanıt yoksa `null` ile. Bağlanılamazsa `false` döner. */
    fun start(onReferrer: (String?) -> Unit): Boolean
    fun end()
}

/**
 * Galaxy Store'un kurulum yönlendirici servisine bağımlılıksız bağlanır. Protokol Samsung'un yayımladığı kütüphaneden
 * (`store.galaxy.samsung.installreferrer:samsung_galaxystore_install_referrer:4.0.0`, Apache-2.0) okunmuştur:
 * servis eylemi `com.sec.android.app.samsungapps.api.InstallReferrerAgent`, istek paketi `guid` = uygulamanın paket adı,
 * yanıt paketi `install_referrer` (ayrıca tıklama ve kurulum zamanı; okunmaz). Gerçek Samsung cihazında denenmedi.
 */
private class GalaxyStoreConnection(private val context: Context) : SamsungReferrerConnection {
    private var connection: ServiceConnection? = null

    override fun start(onReferrer: (String?) -> Unit): Boolean {
        val intent = Intent(ACTION).setPackage(PACKAGE)
        val created = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                if (service == null) return onReferrer(null)
                try {
                    request(service, onReferrer)
                } catch (_: Exception) {
                    onReferrer(null)
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) = onReferrer(null)
        }
        connection = created
        return context.bindService(intent, created, Context.BIND_AUTO_CREATE)
    }

    private fun request(service: IBinder, onReferrer: (String?) -> Unit) {
        val callback = object : Binder() {
            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                if (code != TRANSACTION_RESULT) return super.onTransact(code, data, reply, flags)
                data.enforceInterface(CALLBACK_DESCRIPTOR)
                val bundle = if (data.readInt() != 0) Bundle.CREATOR.createFromParcel(data) else null
                reply?.writeNoException()
                onReferrer(bundle?.getString(KEY_INSTALL_REFERRER))
                return true
            }
        }
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(API_DESCRIPTOR)
            data.writeInt(1)
            Bundle().apply { putString(KEY_PACKAGE, context.packageName) }.writeToParcel(data, 0)
            data.writeStrongBinder(callback)
            service.transact(TRANSACTION_REQUEST, data, reply, 0)
            reply.readException()
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    override fun end() {
        connection?.let(context::unbindService)
        connection = null
    }

    private companion object {
        const val PACKAGE = "com.sec.android.app.samsungapps"
        const val ACTION = "com.sec.android.app.samsungapps.api.InstallReferrerAgent"
        const val API_DESCRIPTOR = "com.sec.android.app.samsungapps.lib.IInstallReferrerAgentAPI"
        const val CALLBACK_DESCRIPTOR = "com.sec.android.app.samsungapps.lib.IInstallReferrerAgentResultCallback"
        const val TRANSACTION_REQUEST = 1
        const val TRANSACTION_RESULT = 1
        const val KEY_PACKAGE = "guid"
        const val KEY_INSTALL_REFERRER = "install_referrer"
    }
}

/**
 * Samsung Galaxy Store kurulum yönlendiricisi. Galaxy Store, mağaza linkindeki `referrer` değerini kurulumla saklar ve servisinden verir.
 * Değer izin listesinden (`fr_click`, `fr_dl`, `utm_*`) geçer; Galaxy Store'un organik varsayılanı (`utm_medium=organic`) kanıt sayılmaz.
 * Yalnız reklam ölçümü izni açıkken okunur (motor çağırır). Galaxy Store yoksa, servis yanıt vermezse ya da süre dolarsa kanıt yoktur.
 */
internal class SamsungInstallReferrerSource(
    private val connectionFactory: () -> SamsungReferrerConnection,
    private val worker: Worker,
    private val log: (String) -> Unit = {},
    private val timeoutMs: Long = 5_000L,
) : InstallReferrerSource {
    constructor(context: Context, worker: Worker, log: (String) -> Unit) : this({ GalaxyStoreConnection(context.applicationContext) }, worker, log)

    override fun read(callback: (AttributionParams?) -> Unit) {
        val settled = AtomicBoolean(false)
        var connection: SamsungReferrerConnection? = null
        var timeout: Cancellable? = null

        fun finish(raw: String?) {
            if (!settled.compareAndSet(false, true)) return
            timeout?.cancel()
            try {
                connection?.end()
            } catch (_: Exception) {
                // Bağlantı zaten kopmuş olabilir.
            }
            val params = if (raw.isNullOrBlank() || raw.length > MAX_REFERRER_CHARS) null else AttributionParams.parseQuery(raw)
            callback(if (params == null || params.isEmpty || params.isPlayOrganicDefault) null else params.copy(source = AttributionSource.SAMSUNG_INSTALL_REFERRER))
        }

        timeout = worker.schedule(timeoutMs) { finish(null) }
        try {
            val opened = connectionFactory()
            connection = opened
            // Yanıt bağlayıcı iş parçacığından gelir; sonuç işçi iş parçacığına alınır.
            if (!opened.start { raw -> worker.execute { finish(raw) } }) finish(null)
        } catch (e: Exception) {
            log("galaxy store referrer bağlantısı açılamadı: ${e.javaClass.simpleName}")
            finish(null)
        }
    }

    private companion object {
        const val MAX_REFERRER_CHARS = 2_000
    }
}
