package com.feralin.android.internal

import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

internal fun interface Cancellable {
    fun cancel()
}

/** Tek iş parçacıklı sıra. Görev hatası uygulamaya sızmaz. */
internal interface Worker {
    fun execute(task: () -> Unit)
    fun schedule(delayMs: Long, task: () -> Unit): Cancellable
}

internal class ExecutorWorker(
    name: String,
    onThreadStart: () -> Unit = {},
    private val log: (String) -> Unit,
) : Worker {
    private val executor = ScheduledThreadPoolExecutor(1) { runnable ->
        Thread({
            try {
                onThreadStart()
            } catch (_: Throwable) {
                // Yalnız ağ istatistiği etiketi; başarısızlığı işlevi etkilemez.
            }
            runnable.run()
        }, name).apply { isDaemon = true }
    }.apply { removeOnCancelPolicy = true }

    private fun guarded(task: () -> Unit) = Runnable {
        try {
            task()
        } catch (t: Throwable) {
            log("görev hatası: ${t.javaClass.simpleName}")
        }
    }

    override fun execute(task: () -> Unit) {
        executor.execute(guarded(task))
    }

    override fun schedule(delayMs: Long, task: () -> Unit): Cancellable {
        val future = executor.schedule(guarded(task), delayMs, TimeUnit.MILLISECONDS)
        return Cancellable { future.cancel(false) }
    }
}
