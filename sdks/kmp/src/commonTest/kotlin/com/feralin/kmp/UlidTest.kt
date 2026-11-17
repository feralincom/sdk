package com.feralin.kmp

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class UlidTest {
    private val fixedMillis = 1_793_703_600_000L
    private val alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    @Test
    fun formatIsValid() {
        val generator = UlidGenerator()
        repeat(1000) { assertTrue(isUlid(generator.next())) }
        for (bad in listOf("", "01ARZ3NDEKTSV4RRFFQ69G5FAV1", "01ARZ3NDEKTSV4RRFFQ69G5FA", "01ARZ3NDEKTSV4RRFFQ69G5FAI", "81ARZ3NDEKTSV4RRFFQ69G5FAV")) {
            assertFalse(isUlid(bad), bad)
        }
    }

    @Test
    fun timestampPrefixRoundTrips() {
        val value = UlidGenerator().next(fixedMillis)
        var millis = 0L
        for (char in value.take(10)) millis = millis * 32 + alphabet.indexOf(char)
        assertEquals(fixedMillis, millis)
    }

    @Test
    fun monotonicWithinSameMillisecond() {
        val generator = UlidGenerator()
        var previous = generator.next(fixedMillis)
        repeat(5000) {
            val current = generator.next(fixedMillis)
            assertTrue(previous < current)
            assertEquals(previous.take(10), current.take(10))
            previous = current
        }
    }

    @Test
    fun monotonicWhenClockGoesBackwards() {
        val generator = UlidGenerator()
        val first = generator.next(fixedMillis)
        assertTrue(generator.next(fixedMillis - 10_000) > first)
    }

    @Test
    fun randomOverflowAdvancesTime() {
        // Tüm basamaklar 31: bir sonraki artış taşar.
        val generator = UlidGenerator { size -> ByteArray(size) { 31 } }
        val first = generator.next(fixedMillis)
        val next = generator.next(fixedMillis)
        assertTrue(next > first)
        assertNotEquals(first.take(10), next.take(10))
    }
}
