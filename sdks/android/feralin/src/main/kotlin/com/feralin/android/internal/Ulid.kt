package com.feralin.android.internal

import java.security.SecureRandom

/** ULID (Crockford base32, 26 karakter): zaman sıralı event_id. Aynı milisaniyede monotonik artar. */
internal object Ulid {
    private const val ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private val random = SecureRandom()
    private var lastTime = -1L
    private var lastRandom = IntArray(16)

    @Synchronized
    fun next(nowMs: Long = System.currentTimeMillis()): String {
        val rand = if (nowMs == lastTime) {
            lastRandom.copyOf().also(::increment)
        } else {
            IntArray(16) { random.nextInt(32) }
        }
        lastTime = nowMs
        lastRandom = rand
        val out = CharArray(26)
        var t = nowMs
        for (i in 9 downTo 0) {
            out[i] = ENCODING[(t % 32).toInt()]
            t /= 32
        }
        for (i in rand.indices) out[10 + i] = ENCODING[rand[i]]
        return String(out)
    }

    private fun increment(values: IntArray) {
        for (i in values.indices.reversed()) {
            if (values[i] < 31) {
                values[i]++
                return
            }
            values[i] = 0
        }
    }
}
