package com.feralin.flutter

import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QueueCipherTest {
    private fun newKey(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    private val plain = """{"event_id":"01J0","name":"screen_view"}"""

    @Test
    fun gidisDonus() {
        val key = newKey()
        val cipher = QueueCipher { key }
        val sealed = cipher.encrypt(plain, "01J0")
        assertTrue(sealed.startsWith("enc1:"))
        assertEquals(plain, cipher.decrypt(sealed, "01J0"))
    }

    @Test
    fun ayniGovdeFarkliSifreliMetinUretir() {
        val key = newKey()
        val cipher = QueueCipher { key }
        assertNotEquals(cipher.encrypt(plain, "a"), cipher.encrypt(plain, "a"))
    }

    @Test
    fun baskaKimligeTasinanSatirAcilmaz() {
        val key = newKey()
        val cipher = QueueCipher { key }
        assertNull(cipher.decrypt(cipher.encrypt(plain, "01J0"), "01J1"))
    }

    @Test
    fun bozukVeKurcalanmisGirdiNullDoner() {
        val key = newKey()
        val cipher = QueueCipher { key }
        val sealed = cipher.encrypt(plain, "01J0")
        assertNull(cipher.decrypt(sealed.dropLast(2) + "00", "01J0"))
        assertNull(cipher.decrypt("enc1:zz", "01J0"))
        assertNull(cipher.decrypt("enc1:abc", "01J0"))
        assertNull(cipher.decrypt("duz metin", "01J0"))
    }

    @Test
    fun yanlisAnahtarAcamaz() {
        val sealed = QueueCipher { newKey() }.encrypt(plain, "01J0")
        assertNull(QueueCipher { newKey() }.decrypt(sealed, "01J0"))
    }

    // Android çekirdeğinin (sdks/android AesGcmPayloadCipher) ve Python `cryptography` AESGCM çıktısı: biçim uyumunun kanıtı.
    @Test
    fun disarida_uretilmis_enc1_satiri_acilir() {
        val key = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
        val sealed = "enc1:000102030405060708090a0b3c20b36da08bb644e425b5b193d94927b3f4ab169e1a32191a5dc7f67e1b65d76f4fd895cab630e5f9fcc1aa2315b7988dad8f757275001a"
        assertEquals(plain, QueueCipher { key }.decrypt(sealed, "01J0"))
        assertNull(QueueCipher { key }.decrypt(sealed, "01J9"))
    }
}
