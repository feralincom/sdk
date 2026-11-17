package com.feralin.android.internal

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.io.File

@RunWith(RobolectricTestRunner::class)
class SqliteEventStoreTest {
    private val app: Application = RuntimeEnvironment.getApplication()

    @Test
    fun kuyrukVeIsaretYenidenAcilistaKalir() {
        val first = SqliteEventStore(app)
        first.add(StoredEvent("a", "{\"event_id\":\"a\"}"), 10, mapOf("first_open_event_id" to "a"))
        first.add(StoredEvent("b", "{\"event_id\":\"b\"}"), 10)
        first.put("anonymous_id", "anon")
        first.close()

        val second = SqliteEventStore(app)
        assertEquals(2, second.size())
        assertEquals(listOf("a", "b"), second.peek(10).map { it.eventId })
        assertEquals("a", second.get("first_open_event_id"))
        assertEquals("anon", second.get("anonymous_id"))
        second.close()
    }

    @Test
    fun replaceGovdeyiDegistirirSirayiKorur() {
        val store = SqliteEventStore(app)
        store.add(StoredEvent("a", "1"), 10)
        store.add(StoredEvent("b", "2"), 10)
        store.replace("a", "1-yeni")
        store.replace("yok", "x")
        assertEquals(listOf(StoredEvent("a", "1-yeni"), StoredEvent("b", "2")), store.peek(10))
        store.close()
    }

    @Test
    fun yedeklemeDisiDizindeTutulur() {
        val store = SqliteEventStore(app)
        store.size()
        assertTrue(File(app.noBackupFilesDir, "feralin_sdk.db").exists())
        assertTrue(!app.getDatabasePath("feralin_sdk.db").exists())
        store.close()
    }

    @Test
    fun sinirEnEskiyiAtarAyniKimlikTekrarEklenmez() {
        val store = SqliteEventStore(app)
        store.add(StoredEvent("a", "1"), 2)
        store.add(StoredEvent("a", "1-yinelenen"), 2)
        assertEquals(1, store.size())
        store.add(StoredEvent("b", "2"), 2)
        store.add(StoredEvent("c", "3"), 2)
        assertEquals(listOf("b", "c"), store.peek(10).map { it.eventId })
        store.close()
    }

    @Test
    fun ackVeTemizlemeIsaretiKorur() {
        val store = SqliteEventStore(app)
        store.add(StoredEvent("a", "1"), 10, mapOf("m" to "1"))
        store.add(StoredEvent("b", "2"), 10)
        store.ack(listOf("a"))
        assertEquals(listOf("b"), store.peek(10).map { it.eventId })
        store.clear()
        assertEquals(0, store.size())
        assertEquals("1", store.get("m"))
        store.remove("m")
        assertNull(store.get("m"))
        store.close()
    }

    @Test
    fun cokluEklemedePeekSinirlidir() {
        val store = SqliteEventStore(app)
        repeat(20) { store.add(StoredEvent("e$it", "$it"), 100) }
        assertEquals(5, store.peek(5).size)
        assertEquals("e0", store.peek(1).single().eventId)
        store.close()
    }
}
