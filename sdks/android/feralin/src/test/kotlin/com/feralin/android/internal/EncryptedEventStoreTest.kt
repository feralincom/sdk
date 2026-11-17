package com.feralin.android.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Kuyruk gövdesi diskte düz metin kalmaz. Keystore yolu cihaz gerektirir; burada aynı şifre, bellek içi anahtarla sınanır. */
class EncryptedEventStoreTest {
    private fun newKey(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    private val payload = "{\"event_id\":\"a\",\"properties\":{\"token\":\"gizli-deger-123\"}}"

    @Test
    fun diskteDuzMetinYokTurSonrasindaAcilir() {
        val disk = MemoryEventStore()
        val store = EncryptedEventStore(disk, AesGcmPayloadCipher(newKey()))
        store.add(StoredEvent("a", payload), 10)

        val raw = disk.peek(10).single().payload
        assertTrue(raw.startsWith("enc1:"))
        assertFalse(raw.contains("gizli-deger-123"))
        assertFalse(raw.contains("event_id"))
        assertEquals(payload, store.peek(10).single().payload)
    }

    @Test
    fun ayniGovdeHerSeferFarkliSifrelenir() {
        val cipher = AesGcmPayloadCipher(newKey())
        assertNotEquals(cipher.encrypt(payload, "a"), cipher.encrypt(payload, "a"))
    }

    @Test
    fun kurcalanmisSatirAtilirDigerleriKalir() {
        val disk = MemoryEventStore()
        val store = EncryptedEventStore(disk, AesGcmPayloadCipher(newKey()))
        store.add(StoredEvent("a", payload), 10)
        store.add(StoredEvent("b", "{\"event_id\":\"b\"}"), 10)
        val bozuk = disk.peek(10).first().payload.dropLast(2) + "00"
        disk.replace("a", bozuk)

        assertEquals(listOf("b"), store.peek(10).map { it.eventId })
        assertEquals(1, store.size())
    }

    @Test
    fun satirBaskaKimligeTasinirsaAcilmaz() {
        val disk = MemoryEventStore()
        val store = EncryptedEventStore(disk, AesGcmPayloadCipher(newKey()))
        store.add(StoredEvent("a", payload), 10)
        store.add(StoredEvent("b", "{\"event_id\":\"b\"}"), 10)
        val a = disk.peek(10).first { it.eventId == "a" }.payload
        disk.replace("b", a)

        assertEquals(listOf("a"), store.peek(10).map { it.eventId })
    }

    @Test
    fun yanlisAnahtarlaAcilmazVeKuyrukBirikmez() {
        val disk = MemoryEventStore()
        EncryptedEventStore(disk, AesGcmPayloadCipher(newKey())).add(StoredEvent("a", payload), 10)
        val baskaAnahtar = EncryptedEventStore(disk, AesGcmPayloadCipher(newKey()))

        assertTrue(baskaAnahtar.peek(10).isEmpty())
        assertEquals(0, disk.size())
    }

    @Test
    fun eskiSurumunDuzMetinSatiriIlkOkumadaSifrelenir() {
        val disk = MemoryEventStore()
        disk.add(StoredEvent("eski", payload), 10)
        val store = EncryptedEventStore(disk, AesGcmPayloadCipher(newKey()))

        assertEquals(payload, store.peek(10).single().payload)
        val raw = disk.peek(10).single().payload
        assertTrue(raw.startsWith("enc1:"))
        assertFalse(raw.contains("gizli-deger-123"))
        // İkinci okuma şifreli satırı açar.
        assertEquals(payload, store.peek(10).single().payload)
    }

    @Test
    fun replaceSifreliYazarAckVeKvDegismez() {
        val disk = MemoryEventStore()
        val store = EncryptedEventStore(disk, AesGcmPayloadCipher(newKey()))
        store.add(StoredEvent("a", payload), 10, mapOf("first_open_event_id" to "a"))
        store.replace("a", "{\"event_id\":\"a\",\"yeni\":\"deger-xyz\"}")

        assertFalse(disk.peek(10).single().payload.contains("deger-xyz"))
        assertTrue(store.peek(10).single().payload.contains("deger-xyz"))
        assertEquals("a", store.get("first_open_event_id"))
        store.put("anonymous_id", "anon")
        assertEquals("anon", store.get("anonymous_id"))
        store.remove("anonymous_id")
        assertNull(store.get("anonymous_id"))
        store.ack(listOf("a"))
        assertEquals(0, store.size())
    }

    @Test
    fun bozukHexVeKisaGovdeFirlatmazNullDoner() {
        val cipher = AesGcmPayloadCipher(newKey())
        assertNull(cipher.decrypt("enc1:zz", "a"))
        assertNull(cipher.decrypt("enc1:abc", "a"))
        assertNull(cipher.decrypt("enc1:", "a"))
        assertNull(cipher.decrypt("{\"duz\":1}", "a"))
    }
}
