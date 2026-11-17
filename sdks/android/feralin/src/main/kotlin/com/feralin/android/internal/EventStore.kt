package com.feralin.android.internal

internal data class StoredEvent(val eventId: String, val payload: String)

/** Kalıcı kuyruk ve küçük anahtar-değer deposu. Yalnız durum iş parçacığından çağrılır. */
internal interface EventStore {
    /** Olayı ekler, [limit] aşılırsa en eskileri atar; [markers] aynı işlemde atomik yazılır. */
    fun add(event: StoredEvent, limit: Int, markers: Map<String, String> = emptyMap())
    fun peek(limit: Int): List<StoredEvent>
    fun ack(eventIds: Collection<String>)
    /** Bekleyen olayın gövdesini kimliğini ve sırasını değiştirmeden yeniler; olay yoksa bir şey yapmaz. */
    fun replace(eventId: String, payload: String)
    fun clear()
    fun size(): Int
    fun get(key: String): String?
    fun put(key: String, value: String)
    fun remove(key: String)
}

/** Disk açılamazsa SDK'nın çalışmayı sürdürmesi için (ve testlerde) kullanılan bellek içi kuyruk. */
internal class MemoryEventStore : EventStore {
    private val events = ArrayList<StoredEvent>()
    private val values = HashMap<String, String>()

    override fun add(event: StoredEvent, limit: Int, markers: Map<String, String>) {
        if (events.none { it.eventId == event.eventId }) events.add(event)
        while (events.size > limit) events.removeAt(0)
        values.putAll(markers)
    }

    override fun peek(limit: Int): List<StoredEvent> = events.take(limit)

    override fun ack(eventIds: Collection<String>) {
        val ids = eventIds.toSet()
        events.removeAll { it.eventId in ids }
    }

    override fun replace(eventId: String, payload: String) {
        val index = events.indexOfFirst { it.eventId == eventId }
        if (index >= 0) events[index] = StoredEvent(eventId, payload)
    }

    override fun clear() = events.clear()
    override fun size(): Int = events.size
    override fun get(key: String): String? = values[key]
    override fun put(key: String, value: String) { values[key] = value }
    override fun remove(key: String) { values.remove(key) }
}
