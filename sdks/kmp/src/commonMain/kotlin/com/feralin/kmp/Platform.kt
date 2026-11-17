package com.feralin.kmp

import io.ktor.client.engine.HttpClientEngineConfig
import io.ktor.client.engine.HttpClientEngineFactory

/** Tel üzerindeki `platform` değeri; UTP v1 şemasındaki listeden. */
internal expect val platformName: String

/** Hedefin Ktor motoru. */
internal expect fun platformEngineFactory(): HttpClientEngineFactory<HttpClientEngineConfig>

/** Unix zamanı (ms). */
internal expect fun currentTimeMillis(): Long

/** İşletim sisteminin kriptografik rastgele kaynağı; event_id tekilliği buna dayanır. */
internal expect fun secureRandomBytes(size: Int): ByteArray

/** Askıya almayan kısa kritik bölge kilidi: `track` eşzamanlıdır, askıya alan `Mutex` kullanamaz. */
internal interface PlatformLock {
    fun <T> withLock(body: () -> T): T
}

internal expect fun createLock(): PlatformLock
