package com.feralin.kmp

import io.ktor.client.engine.HttpClientEngineConfig
import io.ktor.client.engine.HttpClientEngineFactory
import io.ktor.client.engine.cio.CIO
import java.security.SecureRandom
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal actual val platformName: String = "java"

internal actual fun platformEngineFactory(): HttpClientEngineFactory<HttpClientEngineConfig> = CIO

internal actual fun currentTimeMillis(): Long = System.currentTimeMillis()

private val secureRandom = SecureRandom()

internal actual fun secureRandomBytes(size: Int): ByteArray = ByteArray(size).also(secureRandom::nextBytes)

internal actual fun createLock(): PlatformLock = object : PlatformLock {
    private val lock = ReentrantLock()

    override fun <T> withLock(body: () -> T): T = lock.withLock(body)
}
