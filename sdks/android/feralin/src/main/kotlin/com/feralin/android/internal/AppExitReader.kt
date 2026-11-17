package com.feralin.android.internal

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.annotation.TargetApi
import java.io.InputStream

/**
 * `ActivityManager.getHistoricalProcessExitReasons` (API 30+) okuyucusu. Yalnız bu paketin kayıtları istenir (`packageName`, `pid = 0`); kayıtlar
 * sistemin halka tamponundandır ve en yeniden eskiye sıralı gelir. İz yalnız ANR kaydında ve sınır içinde metin olarak okunur; yerel çökmede
 * (API 31+) aynı akış tombstone protobuf'unu verir ve yalnız çerçeve ayrıştırması için sınırlı bayt okunur (API 30'da akış null döner).
 */
internal object AppExitReader {
    private const val MAX_RECORDS = 16

    fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

    fun read(context: Context): List<ExitRecord> {
        if (!isSupported()) return emptyList()
        return readApi30(context)
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun readApi30(context: Context): List<ExitRecord> {
        val manager = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        return manager.getHistoricalProcessExitReasons(context.packageName, 0, MAX_RECORDS).map { info ->
            ExitRecord(
                reason = info.reason,
                timestampMs = info.timestamp,
                description = info.description,
                status = info.status,
                trace = if (info.reason == ApplicationExitInfo.REASON_ANR) readTrace(info) else null,
                tombstone = if (info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) readTombstone(info) else null,
            )
        }
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun readTrace(info: ApplicationExitInfo): String? = try {
        info.traceInputStream?.use(::readLimited)
    } catch (_: Exception) {
        // İz okunamazsa ANR yine çerçevesiz raporlanır.
        null
    }

    /** Tombstone protobuf'unun ilk [NativeTombstone.MAX_BYTES] baytı; okunamazsa yerel çökme yine çerçevesiz raporlanır. */
    @TargetApi(Build.VERSION_CODES.S)
    private fun readTombstone(info: ApplicationExitInfo): ByteArray? = try {
        info.traceInputStream?.use { input ->
            val buffer = ByteArray(32 * 1024)
            val out = java.io.ByteArrayOutputStream()
            while (out.size() < NativeTombstone.MAX_BYTES) {
                val read = input.read(buffer, 0, minOf(buffer.size, NativeTombstone.MAX_BYTES - out.size()))
                if (read < 0) break
                out.write(buffer, 0, read)
            }
            out.toByteArray().takeIf { it.isNotEmpty() }
        }
    } catch (_: Exception) {
        null
    }

    private fun readLimited(input: InputStream): String {
        val buffer = CharArray(8 * 1024)
        val out = StringBuilder()
        input.reader(Charsets.UTF_8).use { reader ->
            while (out.length < ProcessExits.MAX_TRACE_CHARS) {
                val read = reader.read(buffer, 0, minOf(buffer.size, ProcessExits.MAX_TRACE_CHARS - out.length))
                if (read < 0) break
                out.append(buffer, 0, read)
            }
        }
        return out.toString()
    }
}
