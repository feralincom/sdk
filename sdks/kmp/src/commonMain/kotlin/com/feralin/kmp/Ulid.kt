package com.feralin.kmp

private const val CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

/**
 * Monotonik ULID üretimi (26 karakter Crockford base32). Web ve Python SDK'larıyla aynı düzen:
 * 10 karakter zaman (ms) + 16 adet 5 bitlik rastgele basamak (80 bit). İş parçacığı güvenlidir.
 */
class UlidGenerator internal constructor(private val random: (Int) -> ByteArray) {
    constructor() : this(::secureRandomBytes)

    private val lock = createLock()
    private var lastMillis = -1L
    private val lastRandom = IntArray(16)

    /** Aynı milisaniyede ya da saat geri gittiğinde son değeri artırarak sıralamayı korur. */
    fun next(nowMillis: Long = currentTimeMillis()): String = lock.withLock {
        var millis = nowMillis
        if (millis > lastMillis) {
            fillRandom()
        } else {
            millis = lastMillis
            if (!increment()) {
                millis += 1
                fillRandom()
            }
        }
        lastMillis = millis

        val out = CharArray(26)
        var rest = millis
        for (index in 9 downTo 0) {
            out[index] = CROCKFORD[(rest and 31L).toInt()]
            rest = rest shr 5
        }
        for (index in 0 until 16) {
            out[10 + index] = CROCKFORD[lastRandom[index]]
        }
        out.concatToString()
    }

    private fun fillRandom() {
        val bytes = random(16)
        for (index in 0 until 16) {
            lastRandom[index] = bytes[index].toInt() and 31
        }
    }

    /** Rastgele kısmı base32 düzeninde bir artırır; tüm basamaklar taşarsa false döner. */
    private fun increment(): Boolean {
        for (index in 15 downTo 0) {
            if (lastRandom[index] < 31) {
                lastRandom[index] += 1
                return true
            }
            lastRandom[index] = 0
        }
        return false
    }
}

/** 26 karakterlik Crockford base32 ULID biçim denetimi (ilk karakter en fazla '7'). */
fun isUlid(value: String): Boolean =
    value.length == 26 && value[0] <= '7' && value.all { it in CROCKFORD }
