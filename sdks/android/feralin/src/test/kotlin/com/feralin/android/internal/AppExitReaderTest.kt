package com.feralin.android.internal

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowActivityManager

/** `ApplicationExitInfo` okuyucusu Robolectric'in sistem gölgesiyle: API 30 altında yok, üstünde yalnız ANR izi okunur. */
@RunWith(RobolectricTestRunner::class)
class AppExitReaderTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @Test
    @Config(sdk = [24])
    fun api30AltindaDesteklenmezVeBosDoner() {
        assertFalse(AppExitReader.isSupported())
        assertTrue(AppExitReader.read(context).isEmpty())
    }

    @Test
    @Config(sdk = [35])
    fun api35teAnrIziVeYerelCokmeOkunur() {
        assertTrue(AppExitReader.isSupported())
        val manager = context.getSystemService(ActivityManager::class.java)
        val trace = "\"main\" prio=5 tid=1 Sleeping\n  at a.b.c(SourceFile:12)\n"
        shadowOf(manager).addApplicationExitInfo(
            ShadowActivityManager.ApplicationExitInfoBuilder.newBuilder()
                .setProcessName(context.packageName)
                .setReason(ApplicationExitInfo.REASON_ANR)
                .setTimestamp(2_000L)
                .setDescription("Input dispatching timed out")
                .setTraceInputStream(trace.byteInputStream())
                .build(),
        )
        shadowOf(manager).addApplicationExitInfo(
            ShadowActivityManager.ApplicationExitInfoBuilder.newBuilder()
                .setProcessName(context.packageName)
                .setReason(ApplicationExitInfo.REASON_CRASH_NATIVE)
                .setStatus(11)
                .setTimestamp(1_000L)
                .build(),
        )
        val records = AppExitReader.read(context).sortedBy { it.timestampMs }
        assertEquals(listOf(ProcessExits.REASON_CRASH_NATIVE, ProcessExits.REASON_ANR), records.map { it.reason })
        assertNull("yerel çökmenin tombstone'u okunmaz", records[0].trace)
        assertEquals(11, records[0].status)
        assertEquals(trace, records[1].trace)
        assertEquals("Input dispatching timed out", records[1].description)
        // Sabitler resmî değerlerle aynı.
        assertEquals(ApplicationExitInfo.REASON_ANR, ProcessExits.REASON_ANR)
        assertEquals(ApplicationExitInfo.REASON_CRASH_NATIVE, ProcessExits.REASON_CRASH_NATIVE)
    }
}
