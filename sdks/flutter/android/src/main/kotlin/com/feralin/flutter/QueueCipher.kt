package com.feralin.flutter

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Dart kuyruğunun olay gövdesini şifreler. Biçim `sdks/android` çekirdeğindeki `AesGcmPayloadCipher` ile birebir aynıdır:
 * AES-256-GCM, `enc1:` + onaltılı(IV ‖ şifreli metin ‖ etiket), ilişkilendirilmiş veri olay kimliği. Onaltılı bilinçli seçildi
 * (`java.util.Base64` API 26 öncesinde yok, minSdk 24). Satır başka kimliğe taşınırsa açılmaz.
 */
internal class QueueCipher(private val keyProvider: () -> SecretKey) {
    /** Anahtar alınamazsa fırlatır; çağıran düz metne düşmez (Dart olayı bellekte tutar). */
    fun encrypt(plain: String, aad: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        // IV'yi sağlayıcı üretir: Android Keystore anahtarları çağıranın IV vermesini reddeder.
        cipher.init(Cipher.ENCRYPT_MODE, keyProvider())
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        val body = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return PREFIX + toHex(cipher.iv + body)
    }

    /** Açılamazsa (bozuk, kurcalanmış, anahtar kayıp) `null`; asla fırlatmaz. */
    fun decrypt(stored: String, aad: String): String? = try {
        if (!stored.startsWith(PREFIX)) {
            null
        } else {
            val raw = fromHex(stored.substring(PREFIX.length))
            if (raw == null || raw.size <= IV_BYTES + TAG_BYTES) {
                null
            } else {
                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(Cipher.DECRYPT_MODE, keyProvider(), GCMParameterSpec(TAG_BYTES * 8, raw, 0, IV_BYTES))
                cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
                String(cipher.doFinal(raw, IV_BYTES, raw.size - IV_BYTES), Charsets.UTF_8)
            }
        }
    } catch (_: GeneralSecurityException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }

    companion object {
        const val PREFIX = "enc1:"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
        private const val TAG_BYTES = 16

        private fun toHex(bytes: ByteArray): String {
            val out = StringBuilder(bytes.size * 2)
            for (b in bytes) {
                out.append(HEX[(b.toInt() shr 4) and 0xF]).append(HEX[b.toInt() and 0xF])
            }
            return out.toString()
        }

        private fun fromHex(text: String): ByteArray? {
            if (text.length % 2 != 0) return null
            val out = ByteArray(text.length / 2)
            for (i in out.indices) {
                val hi = Character.digit(text[i * 2], 16)
                val lo = Character.digit(text[i * 2 + 1], 16)
                if (hi < 0 || lo < 0) return null
                out[i] = ((hi shl 4) or lo).toByte()
            }
            return out
        }

        private val HEX = "0123456789abcdef".toCharArray()
    }
}

/** Aygıt donanımına bağlı, dışarı aktarılamayan anahtar (Android Keystore). Yedekle başka cihaza taşınmaz. */
internal object QueueKeystoreKey {
    private const val PROVIDER = "AndroidKeyStore"

    // Android çekirdeğinin takma adından ayrıdır: aynı uygulamada iki SDK yan yana olsa da anahtarlar birbirine karışmaz.
    private const val ALIAS = "com.feralin.sdk.flutter.queue.v1"

    /** Anahtar yoksa üretir. Keystore kullanılamazsa fırlatır. */
    fun getOrCreate(): SecretKey {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }
}
