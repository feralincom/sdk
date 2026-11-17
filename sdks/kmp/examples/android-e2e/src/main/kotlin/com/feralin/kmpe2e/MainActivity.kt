package com.feralin.kmpe2e

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.widget.ScrollView
import android.widget.TextView
import com.feralin.kmp.Consent
import com.feralin.kmp.FeralinClient
import com.feralin.kmp.FeralinConfig
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.runBlocking
import org.json.JSONObject

/**
 * KMP SDK Android hedefi (Ktor OkHttp) emülatör senaryosu. Her adım logcat'e `FR_E2E {json}` olarak yazılır ve ekranda gösterilir;
 * betik `wait-offline` / `wait-online` satırlarında emülatör ağını keser ve açar. Ağ durumu yalnız toplayıcı sağlık ucuyla anlaşılır.
 */
class MainActivity : Activity() {
    private lateinit var output: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        output = TextView(this).apply {
            textSize = 12f
            val padding = (16 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding, padding, padding)
            fitsSystemWindows = true
        }
        setContentView(ScrollView(this).apply { addView(output) })
        Thread {
            try {
                runBlocking { scenario() }
            } catch (error: Throwable) {
                report("error", mapOf("message" to "${error::class.java.simpleName}: ${error.message}"))
            }
        }.start()
    }

    private fun report(step: String, data: Map<String, Any?>) {
        val json = JSONObject().put("step", step)
        data.forEach { (key, value) -> json.put(key, value ?: JSONObject.NULL) }
        Log.i(TAG, "FR_E2E $json")
        runOnUiThread { output.append("$step $data\n") }
    }

    private fun reachable(): Boolean = try {
        val connection = URL("${BuildConfig.COLLECT_URL}/v1/health").openConnection() as HttpURLConnection
        connection.connectTimeout = 2_000
        connection.readTimeout = 2_000
        try {
            connection.responseCode == 200
        } finally {
            connection.disconnect()
        }
    } catch (_: Exception) {
        false
    }

    private fun waitReachable(wanted: Boolean): Boolean {
        repeat(60) {
            if (reachable() == wanted) return true
            Thread.sleep(1_000)
        }
        return false
    }

    private suspend fun scenario() {
        // Arka plan göndericisi kapalı (0): gönderim yalnız açık flush ile, sonuç adım adım okunur.
        val client = FeralinClient(FeralinConfig(BuildConfig.PROJECT_KEY, BuildConfig.COLLECT_URL, Consent(), flushIntervalMillis = 0))
        // Açılıştan hemen sonra emülatör ağı hazır olmayabilir; senaryo toplayıcıya erişim görülünce başlar.
        report("initialize", mapOf("sdk" to client.status().sdk, "version" to client.status().version, "network_ready" to waitReachable(true)))

        val denied = client.track("kmp_android_before_consent")
        report("izin-yok", mapOf("event_id" to denied?.eventId, "queued" to client.queued))

        client.setConsent(Consent(analytics = true))
        val screen = client.track("screen_view", mapOf("screen_name" to "kmp_home"))
        val order = client.track("order_completed", mapOf("order_id" to "kmp_android_1", "amount" to 49.99))
        val first = client.flush()
        report(
            "cevrimici-ilk",
            mapOf(
                "screen_event_id" to screen?.eventId,
                "order_event_id" to order?.eventId,
                "status" to first.status,
                "accepted" to first.accepted,
                "batch_id" to first.batchId,
                "error" to first.error?.toString(),
                "queued" to client.queued,
            ),
        )

        report("wait-offline", emptyMap())
        val wentOffline = waitReachable(false)
        val offline = client.track("order_completed", mapOf("order_id" to "kmp_android_2", "amount" to 19.99))
        val offlineFlush = client.flush()
        report(
            "cevrimdisi",
            mapOf(
                "network_off" to wentOffline,
                "event_id" to offline?.eventId,
                "status" to offlineFlush.status,
                "error" to offlineFlush.error?.toString(),
                "queued" to client.queued,
            ),
        )

        report("wait-online", emptyMap())
        val backOnline = waitReachable(true)
        val online = client.flush()
        report(
            "cevrimici",
            mapOf(
                "network_on" to backOnline,
                "event_id" to offline?.eventId,
                "status" to online.status,
                "queued" to client.queued,
            ),
        )
        client.close()
        report("done", emptyMap())
    }

    private companion object {
        const val TAG = "FeralinE2E"
    }
}
