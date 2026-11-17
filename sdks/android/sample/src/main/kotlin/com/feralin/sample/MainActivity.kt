package com.feralin.sample

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.feralin.android.Consent
import com.feralin.android.Feralin
import com.feralin.android.FlushResult

/** En yalın kullanım: izin, olay, gönderim ve durum. Bağımlılık eklememek için AndroidX kullanılmaz. */
class MainActivity : Activity() {
    private lateinit var status: TextView
    private var lastFlush: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply { textSize = 16f }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            val padding = (24 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding, padding, padding)
            fitsSystemWindows = true
            addView(status, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            addView(button(R.string.consent_grant) { decide(Consent(analytics = true)) })
            addView(button(R.string.consent_grant_ad) { decide(Consent(analytics = true, advertising = true)) })
            addView(button(R.string.consent_deny) { decide(Consent(analytics = false)) })
            addView(button(R.string.track_event) { Feralin.track("sample_button_clicked", mapOf("screen" to "main")) })
            addView(button(R.string.flush_now) { Feralin.flush(::onFlushed) })
            addView(button(R.string.report_error) { CheckoutFlow.reportHandled() })
            addView(button(R.string.freeze_main) { CheckoutFlow.freezeMainThread() })
        }
        setContentView(ScrollView(this).apply { addView(column) })
    }

    private fun button(label: Int, action: () -> Unit) = Button(this).apply {
        setText(label)
        setOnClickListener {
            action()
            render()
        }
    }

    private fun decide(consent: Consent) {
        SampleApp.storeConsent(this, consent)
        Feralin.setConsent(consent)
    }

    private fun onFlushed(result: FlushResult) {
        Log.i(TAG, "flush status=${result.status} accepted=${result.accepted} rejected=${result.rejected}")
        runOnUiThread {
            lastFlush = getString(R.string.flush_format, result.status, result.accepted, result.rejected)
            render()
        }
    }

    // App Link tek görevli etkinliğe yeniden gelirse niyet güncellenir; SDK onResume'da yakalar.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        val state = Feralin.getStatus()
        val pending = getString(R.string.consent_pending)
        val analytics = state.consent?.analytics?.toString() ?: pending
        val advertising = state.consent?.advertising?.toString() ?: pending
        status.text = getString(
            R.string.status_format,
            analytics,
            advertising,
            state.queued,
            lastFlush ?: getString(R.string.flush_none),
        )
    }

    private companion object {
        const val TAG = "FeralinSample"
    }
}
