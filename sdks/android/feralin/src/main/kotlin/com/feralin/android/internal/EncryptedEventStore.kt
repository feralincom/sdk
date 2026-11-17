package com.feralin.android.internal

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Kuyruktaki olay gövdesini diskte şifreli tutar. İlişkilendirilmiş veri olay kimliğidir: satır başka kimliğe taşınırsa açılmaz. */
internal interface PayloadCipher {
    fun encrypt(plain: String, aad: String): String

    /** Açılamazsa (bozuk, kurcalanmış, anahtar kayıp) `null`; asla fırlatmaz. */
    fun decrypt(stored: String, aad: String): String?
}

/**
 * AES-256-GCM. Biçim: `enc1:` + hex(iv ‖ şifreli metin ‖ etiket). Hex bilinçli: `java.util.Base64` API 26'dan öncesinde yoktur
 * (minSdk 24) ve `android.util.Base64` JVM birim testinde çalışmaz. Gövdeler küçüktür, boyut farkı önemsizdir.
 */
internal class AesGcmPayloadCipher(private val key: SecretKey) : PayloadCipher {
    override fun encrypt(plain: String, aad: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        // IV'yi sağlayıcı üretir: Android Keystore anahtarları çağıranın IV vermesini reddeder.
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        val body = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return PREFIX + toHex(cipher.iv + body)
    }

    override fun decrypt(stored: String, aad: String): String? = try {
        if (!stored.startsWith(PREFIX)) {
            null
        } else {
            val raw = fromHex(stored.substring(PREFIX.length))
            if (raw == null || raw.size <= IV_BYTES + TAG_BYTES) {
                null
            } else {
                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BYTES * 8, raw, 0, IV_BYTES))
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
internal object KeystoreKey {
    private const val PROVIDER = "AndroidKeyStore"
    private const val ALIAS = "com.feralin.sdk.queue.v1"

    /** Anahtar yoksa üretir. Keystore kullanılamazsa fırlatır; çağıran kuyruğu bellekte tutar, düz metne düşmez. */
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

/**
 * Olay gövdelerini şifreleyen sarmalayıcı. Eski sürümden kalan düz metin satırlar ilk okunuşta şifreli yazılır; açılamayan satır
 * (anahtar kaybı, bozulma) kuyruktan atılır: gönderilemeyecek şifreli veri sonsuza dek birikmez. Anahtar-değer alanı (kimlik,
 * işaretler) olay gövdesi değildir ve olduğu gibi kalır.
 */
internal class EncryptedEventStore(private val delegate: EventStore, private val cipher: PayloadCipher) : EventStore {
    override fun add(event: StoredEvent, limit: Int, markers: Map<String, String>) =
        delegate.add(StoredEvent(event.eventId, cipher.encrypt(event.payload, event.eventId)), limit, markers)

    override fun peek(limit: Int): List<StoredEvent> {
        val out = ArrayList<StoredEvent>()
        val broken = ArrayList<String>()
        for (row in delegate.peek(limit)) {
            if (row.payload.startsWith(AesGcmPayloadCipher.PREFIX)) {
                val plain = cipher.decrypt(row.payload, row.eventId)
                if (plain == null) broken.add(row.eventId) else out.add(StoredEvent(row.eventId, plain))
            } else {
                // Eski sürümün düz metin satırı: şifreli yazılır, bellekte düz hâli döner.
                delegate.replace(row.eventId, cipher.encrypt(row.payload, row.eventId))
                out.add(row)
            }
        }
        if (broken.isNotEmpty()) delegate.ack(broken)
        return out
    }

    override fun ack(eventIds: Collection<String>) = delegate.ack(eventIds)

    override fun replace(eventId: String, payload: String) = delegate.replace(eventId, cipher.encrypt(payload, eventId))

    override fun clear() = delegate.clear()

    override fun size(): Int = delegate.size()

    override fun get(key: String): String? = delegate.get(key)

    override fun put(key: String, value: String) = delegate.put(key, value)

    override fun remove(key: String) = delegate.remove(key)
}
