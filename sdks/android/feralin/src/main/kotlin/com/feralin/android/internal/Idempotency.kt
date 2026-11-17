package com.feralin.android.internal

/** Web SDK ile aynı anahtar: sıralı tüm event_id'lerin FNV-1a 64 özeti + olay sayısı. Sıradan bağımsızdır. */
internal object Idempotency {
    private const val OFFSET = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
    private const val PRIME = 0x100000001b3L

    fun keyFor(eventIds: Collection<String>): String {
        val text = eventIds.sorted().joinToString(",")
        var hash = OFFSET
        for (ch in text) {
            hash = (hash xor ch.code.toLong()) * PRIME
        }
        return java.lang.Long.toHexString(hash).padStart(16, '0') + "-" + eventIds.size
    }
}
