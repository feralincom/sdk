package com.feralin.android.internal

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File

/**
 * SQLite kuyruğu: yeni bağımlılık gerektirmez, olay başına dosya yeniden yazmaz ve ilk açılış işaretini olayla
 * aynı işlemde yazar. Dosya `noBackupFilesDir` altındadır: Auto Backup geri yüklemesi yeni kurulumda
 * "ilk açılış yapıldı" işaretini veya başka cihazın anonim kimliğini taşımaz.
 */
internal class SqliteEventStore(context: Context) : EventStore {
    private val helper = object : SQLiteOpenHelper(
        context.applicationContext,
        File(context.applicationContext.noBackupFilesDir, DB_NAME).path,
        null,
        DB_VERSION,
    ) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                "CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, " +
                    "event_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL)",
            )
            db.execSQL("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    }

    private val db: SQLiteDatabase get() = helper.writableDatabase

    override fun add(event: StoredEvent, limit: Int, markers: Map<String, String>) {
        val database = db
        database.beginTransaction()
        try {
            val row = ContentValues(2).apply {
                put("event_id", event.eventId)
                put("payload", event.payload)
            }
            database.insertWithOnConflict("events", null, row, SQLiteDatabase.CONFLICT_IGNORE)
            database.execSQL(
                "DELETE FROM events WHERE seq NOT IN (SELECT seq FROM events ORDER BY seq DESC LIMIT ?)",
                arrayOf<Any>(limit),
            )
            for ((key, value) in markers) putInternal(database, key, value)
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    override fun peek(limit: Int): List<StoredEvent> {
        db.query("events", arrayOf("event_id", "payload"), null, null, null, null, "seq ASC", limit.toString())
            .use { cursor ->
                val out = ArrayList<StoredEvent>(cursor.count)
                while (cursor.moveToNext()) out.add(StoredEvent(cursor.getString(0), cursor.getString(1)))
                return out
            }
    }

    override fun ack(eventIds: Collection<String>) {
        val database = db
        database.beginTransaction()
        try {
            for (id in eventIds) database.delete("events", "event_id = ?", arrayOf(id))
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    override fun replace(eventId: String, payload: String) {
        val row = ContentValues(1).apply { put("payload", payload) }
        db.update("events", row, "event_id = ?", arrayOf(eventId))
    }

    override fun clear() {
        db.delete("events", null, null)
    }

    override fun size(): Int {
        db.rawQuery("SELECT COUNT(*) FROM events", null).use { cursor ->
            return if (cursor.moveToFirst()) cursor.getInt(0) else 0
        }
    }

    override fun get(key: String): String? {
        db.query("kv", arrayOf("v"), "k = ?", arrayOf(key), null, null, null).use { cursor ->
            return if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }

    override fun put(key: String, value: String) = putInternal(db, key, value)

    override fun remove(key: String) {
        db.delete("kv", "k = ?", arrayOf(key))
    }

    /** Testlerde yeniden açılışı (süreç sonu) taklit etmek için. */
    fun close() = helper.close()

    private fun putInternal(database: SQLiteDatabase, key: String, value: String) {
        val row = ContentValues(2).apply {
            put("k", key)
            put("v", value)
        }
        database.insertWithOnConflict("kv", null, row, SQLiteDatabase.CONFLICT_REPLACE)
    }

    private companion object {
        const val DB_NAME = "feralin_sdk.db"
        const val DB_VERSION = 1
    }
}
