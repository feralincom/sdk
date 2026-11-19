package com.feralin.android.internal

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Atıf olaylarının (ilk açılış, link açılışı) imzası. Sunucu, projenin imza anahtarıyla doğrular; imzasız ya da bozuk imzalı kurulum
 * projenin seçtiği kurala göre işaretlenir ya da reddedilir. İmza olayın kimliğine bağlıdır: başka olaya taşınamaz.
 *
 * Biçim: `v1.<anahtar kimliği>.<unix saniye>.<hex hmac-sha256>`; imzalanan dizgi `v1\n<saniye>\n<event_id>\n<event_name>\n<anonymous_id>`.
 * Anahtar uygulamaya gömülüdür: kararlı bir saldırgan paketten çıkarabilir. İmza sahte kurulum üretmeyi zorlaştırır, imkânsız kılmaz.
 */
internal object EventSigner {
    const val PROPERTY = "fr_sig"
    private const val ALGORITHM = "HmacSHA256"
    private val HEX = "0123456789abcdef".toCharArray()

    fun sign(keyId: String, secret: String, atSeconds: Long, eventId: String, eventName: String, anonymousId: String): String {
        val mac = Mac.getInstance(ALGORITHM)
        mac.init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), ALGORITHM))
        val digest = mac.doFinal("v1\n$atSeconds\n$eventId\n$eventName\n$anonymousId".toByteArray(Charsets.UTF_8))
        val hex = StringBuilder(digest.size * 2)
        for (byte in digest) {
            val value = byte.toInt() and 0xff
            hex.append(HEX[value ushr 4]).append(HEX[value and 0x0f])
        }
        return "v1.$keyId.$atSeconds.$hex"
    }
}
