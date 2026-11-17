package com.feralin.flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.TimeZone
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Yalnız platform köprüsü: Play Install Referrer, App Link niyetleri, ağ durumu, yedekleme dışı dizin ve kuyruk şifreleme anahtarı
 * (Keystore). Kuyruk, izin ve gönderim Dart çekirdeğindedir. Hiçbir hata uygulamaya sızmaz; kanal yanıtı `null` olur.
 */
class FeralinFlutterPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val background = Executors.newSingleThreadExecutor()
    private val queueCipher = QueueCipher { QueueKeystoreKey.getOrCreate() }

    private val saveStateListener = object : ActivityPluginBinding.OnSaveInstanceStateListener {
        override fun onSaveInstanceState(bundle: Bundle) = Unit

        // Durum geri yüklemesinde niyet eski açılışa aittir; aynı bağlantı ikinci kez sayılmaz.
        override fun onRestoreInstanceState(bundle: Bundle?) {
            if (bundle != null) activity?.intent?.putExtra(HANDLED_EXTRA, true)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        setNetworkListening(false)
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        background.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addOnNewIntentListener(this)
        binding.addOnSaveStateListener(saveStateListener)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding?.removeOnSaveStateListener(saveStateListener)
        activityBinding = null
        activity = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        consumeLink(intent)?.let { channel?.invokeMethod("onLink", it) }
        return false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getNoBackupDir" -> result.success(context?.noBackupFilesDir?.path)
                "getAppInfo" -> result.success(appInfo())
                "getInitialLink" -> result.success(activity?.intent?.let(::consumeLink))
                "readInstallReferrer" -> readInstallReferrer(1, result)
                "encryptQueue" -> queueCrypto(call, result) { plain, aad -> queueCipher.encrypt(plain, aad) }
                "decryptQueue" -> queueCrypto(call, result) { stored, aad -> queueCipher.decrypt(stored, aad) }
                "setNetworkListening" -> {
                    setNetworkListening(call.arguments == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "kanal hatası: ${t.javaClass.simpleName}")
            result.success(null)
        }
    }

    /**
     * Kuyruk şifreleme çağrısı; Keystore erişimi ana iş parçacığında yapılmaz. Hata (anahtar alınamadı, bozuk satır) `null` döner:
     * Dart tarafı bunu "anahtar yok" sayar ve olayı düz metne yazmadan bellekte tutar.
     */
    private fun queueCrypto(call: MethodCall, result: MethodChannel.Result, work: (String, String) -> String?) {
        val first = call.argument<String>(if (call.method == "encryptQueue") "plain" else "stored")
        val aad = call.argument<String>("aad")
        if (first == null || aad == null) return result.success(null)
        background.execute {
            val value = try {
                work(first, aad)
            } catch (t: Throwable) {
                Log.w(TAG, "kuyruk şifreleme hatası: ${t.javaClass.simpleName}")
                null
            }
            mainHandler.post { result.success(value) }
        }
    }

    /** İşlenmemiş http(s) VIEW niyetinin URL'ini verir; geçmişten açılış ve yinelenen teslim elenir. */
    private fun consumeLink(intent: Intent): String? {
        if (intent.action != Intent.ACTION_VIEW) return null
        if (intent.getBooleanExtra(HANDLED_EXTRA, false)) return null
        intent.putExtra(HANDLED_EXTRA, true)
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        return intent.dataString
    }

    /** Parmak izi kaynağı olmaması için model, işletim sistemi sürümü veya donanım bilgisi eklenmez. */
    private fun appInfo(): Map<String, String?> {
        val app = context ?: return emptyMap()
        var version: String? = null
        var build: String? = null
        try {
            val info = app.packageManager.getPackageInfo(app.packageName, 0)
            version = info.versionName
            build = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode.toString()
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toString()
            }
        } catch (_: PackageManager.NameNotFoundException) {
            // Kendi paketimiz için beklenmez; alan gönderilmez.
        }
        return mapOf("version" to version, "build" to build, "timezone" to TimeZone.getDefault().id)
    }

    /** Sonuç `null`: servis yok veya erişilemedi. Boş harita: servis yanıt verdi ama izin listesinde değer yok. */
    private fun readInstallReferrer(attempt: Int, result: MethodChannel.Result) {
        val app = context ?: return result.success(null)
        val settled = AtomicBoolean(false)
        val client: InstallReferrerClient
        try {
            client = InstallReferrerClient.newBuilder(app).build()
        } catch (t: Throwable) {
            // Kütüphane uygulamadan çıkarılmışsa (NoClassDefFoundError) kaynak "none" olur.
            Log.w(TAG, "referrer kütüphanesi yok: ${t.javaClass.simpleName}")
            return result.success(null)
        }

        fun finish(value: Map<String, String>?) {
            if (!settled.compareAndSet(false, true)) return
            try {
                client.endConnection()
            } catch (_: Exception) {
                // Bağlantı zaten kopmuş olabilir.
            }
            mainHandler.post { result.success(value) }
        }

        fun retryOrFinish() {
            if (!settled.compareAndSet(false, true)) return
            try {
                client.endConnection()
            } catch (_: Exception) {
                // Bağlantı zaten kopmuş olabilir.
            }
            if (attempt < MAX_REFERRER_ATTEMPTS) {
                mainHandler.postDelayed({ readInstallReferrer(attempt + 1, result) }, REFERRER_RETRY_MS)
            } else {
                mainHandler.post { result.success(null) }
            }
        }

        val timeout = Runnable { retryOrFinish() }
        mainHandler.postDelayed(timeout, REFERRER_TIMEOUT_MS)
        client.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) {
                mainHandler.removeCallbacks(timeout)
                when (responseCode) {
                    // getInstallReferrer IPC olduğu için ana iş parçacığında yapılmaz.
                    InstallReferrerResponse.OK -> background.execute {
                        val params = try {
                            ReferrerParams.parse(client.installReferrer?.installReferrer)
                        } catch (e: Exception) {
                            Log.w(TAG, "referrer okunamadı: ${e.javaClass.simpleName}")
                            null
                        }
                        finish(params)
                    }
                    InstallReferrerResponse.SERVICE_UNAVAILABLE,
                    InstallReferrerResponse.SERVICE_DISCONNECTED,
                    -> retryOrFinish()
                    else -> finish(null)
                }
            }

            override fun onInstallReferrerServiceDisconnected() {
                mainHandler.removeCallbacks(timeout)
                retryOrFinish()
            }
        })
    }

    private fun setNetworkListening(enabled: Boolean) {
        val manager = context?.getSystemService(ConnectivityManager::class.java) ?: return
        val current = networkCallback
        if (enabled && current == null) {
            val created = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    mainHandler.post { channel?.invokeMethod("onNetworkAvailable", null) }
                }
            }
            try {
                manager.registerDefaultNetworkCallback(created)
                networkCallback = created
            } catch (e: RuntimeException) {
                // İzin kaldırılmış veya kayıt sınırı dolmuşsa kuyruk ön plan geçişlerinde yine boşalır.
                Log.w(TAG, "ağ dinleyicisi açılamadı: ${e.javaClass.simpleName}")
            }
        } else if (!enabled && current != null) {
            networkCallback = null
            try {
                manager.unregisterNetworkCallback(current)
            } catch (e: RuntimeException) {
                Log.w(TAG, "ağ dinleyicisi kapatılamadı: ${e.javaClass.simpleName}")
            }
        }
    }

    private companion object {
        const val CHANNEL = "com.feralin/flutter"
        const val TAG = "Feralin"
        const val HANDLED_EXTRA = "com.feralin.flutter.LINK_HANDLED"
        const val MAX_REFERRER_ATTEMPTS = 3
        const val REFERRER_RETRY_MS = 2_000L
        const val REFERRER_TIMEOUT_MS = 8_000L
    }
}
