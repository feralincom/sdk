package com.feralin.android.internal

import android.content.Context
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse
import com.android.installreferrer.api.InstallReferrerStateListener
import java.util.concurrent.atomic.AtomicBoolean

/** Resmî kütüphaneye ince soyutlama; testlerde Play servisi olmadan yanıt kodları sınanır. */
internal interface ReferrerConnection {
    fun start(onSetupFinished: (Int) -> Unit, onDisconnected: () -> Unit)
    fun referrer(): String?
    fun end()
}

private class PlayReferrerConnection(context: Context) : ReferrerConnection {
    private val client = InstallReferrerClient.newBuilder(context.applicationContext).build()

    override fun start(onSetupFinished: (Int) -> Unit, onDisconnected: () -> Unit) {
        client.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) = onSetupFinished(responseCode)
            override fun onInstallReferrerServiceDisconnected() = onDisconnected()
        })
    }

    override fun referrer(): String? = client.installReferrer?.installReferrer
    override fun end() = client.endConnection()
}

/**
 * Play Install Referrer'ı okur. Belge gereği değer değişmez, bu yüzden motor bunu kurulumda bir kez çağırır.
 * Ham dizgi yalnız izin listesinden geçer; saklanmaz ve loglanmaz. Tıklama/kurulum zaman damgaları sözleşme gereği okunmaz.
 */
internal class PlayInstallReferrerSource(
    private val connectionFactory: () -> ReferrerConnection,
    private val worker: Worker,
    private val log: (String) -> Unit = {},
    private val maxAttempts: Int = 3,
    private val retryDelayMs: Long = 2_000L,
    private val timeoutMs: Long = 8_000L,
) : InstallReferrerSource {
    constructor(context: Context, worker: Worker, log: (String) -> Unit) :
        this({ PlayReferrerConnection(context) }, worker, log)

    override fun read(callback: (AttributionParams?) -> Unit) = attempt(1, callback)

    private fun attempt(number: Int, callback: (AttributionParams?) -> Unit) {
        val settled = AtomicBoolean(false)
        var connection: ReferrerConnection? = null

        fun close() {
            try {
                connection?.end()
            } catch (_: Exception) {
                // Bağlantı zaten kopmuş olabilir.
            }
        }

        fun finish(params: AttributionParams?) {
            if (settled.compareAndSet(false, true)) {
                close()
                callback(params)
            }
        }

        fun retryOrFinish() {
            if (!settled.compareAndSet(false, true)) return
            close()
            if (number < maxAttempts) {
                worker.schedule(retryDelayMs) { attempt(number + 1, callback) }
            } else {
                log("referrer servisi erişilemedi")
                callback(null)
            }
        }

        val timeout = worker.schedule(timeoutMs) { retryOrFinish() }
        try {
            val opened = connectionFactory()
            connection = opened
            opened.start(
                onSetupFinished = { code ->
                    timeout.cancel()
                    // Geri çağrı ana iş parçacığındadır; getInstallReferrer IPC olduğu için orada yapılmaz.
                    worker.execute {
                        when (code) {
                            InstallReferrerResponse.OK -> finish(readParams(opened))
                            InstallReferrerResponse.SERVICE_UNAVAILABLE,
                            InstallReferrerResponse.SERVICE_DISCONNECTED,
                            -> retryOrFinish()
                            else -> {
                                // FEATURE_NOT_SUPPORTED vb.: bu cihazda yeniden denemek işe yaramaz.
                                log("referrer yanıt kodu: $code")
                                finish(null)
                            }
                        }
                    }
                },
                onDisconnected = { worker.execute { retryOrFinish() } },
            )
        } catch (e: Exception) {
            timeout.cancel()
            log("referrer bağlantısı açılamadı: ${e.javaClass.simpleName}")
            finish(null)
        }
    }

    private fun readParams(connection: ReferrerConnection): AttributionParams? = try {
        AttributionParams.parseQuery(connection.referrer())
    } catch (e: Exception) {
        log("referrer okunamadı: ${e.javaClass.simpleName}")
        null
    }
}
