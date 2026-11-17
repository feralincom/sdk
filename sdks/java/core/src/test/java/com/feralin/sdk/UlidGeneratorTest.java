package com.feralin.sdk;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;

class UlidGeneratorTest {
    private static final Pattern ULID = Pattern.compile("[0-7][0-9A-HJKMNP-TV-Z]{25}");
    private static final long FIXED_MS = 1_762_164_000_000L;

    @Test
    void format() {
        UlidGenerator generator = new UlidGenerator();
        for (int i = 0; i < 1000; i++) {
            String value = generator.next();
            assertTrue(ULID.matcher(value).matches(), value);
            assertTrue(UlidGenerator.isUlid(value), value);
        }
        for (String bad : List.of("", "01ARZ3NDEKTSV4RRFFQ69G5FAV1", "01ARZ3NDEKTSV4RRFFQ69G5FA", "01ARZ3NDEKTSV4RRFFQ69G5FAI", "81ARZ3NDEKTSV4RRFFQ69G5FAV")) {
            assertFalse(UlidGenerator.isUlid(bad), bad);
        }
        assertFalse(UlidGenerator.isUlid(null));
    }

    @Test
    void timestampPrefix() {
        String value = new UlidGenerator(() -> FIXED_MS).next();
        long millis = 0;
        for (char c : value.substring(0, 10).toCharArray()) {
            millis = millis * 32 + UlidGenerator.CROCKFORD.indexOf(c);
        }
        assertEquals(FIXED_MS, millis);
    }

    @Test
    void monotonicWithinSameMillisecond() {
        UlidGenerator generator = new UlidGenerator(() -> FIXED_MS);
        String previous = generator.next();
        for (int i = 0; i < 5000; i++) {
            String current = generator.next();
            assertTrue(previous.compareTo(current) < 0);
            assertEquals(previous.substring(0, 10), current.substring(0, 10));
            previous = current;
        }
    }

    @Test
    void monotonicWhenClockGoesBackwards() {
        AtomicLong clock = new AtomicLong(FIXED_MS);
        UlidGenerator generator = new UlidGenerator(clock::get);
        String first = generator.next();
        clock.addAndGet(-10_000);
        assertTrue(generator.next().compareTo(first) > 0);
    }

    @Test
    void randomOverflowAdvancesTime() {
        UlidGenerator generator = new UlidGenerator(() -> FIXED_MS);
        String first = generator.next();
        Arrays.fill(generator.lastRandom, 31);
        String next = generator.next();
        assertTrue(next.compareTo(first) > 0);
        assertNotEquals(first.substring(0, 10), next.substring(0, 10));
    }

    @Test
    void concurrentUnique() throws InterruptedException {
        UlidGenerator generator = new UlidGenerator();
        List<String> results = new ArrayList<>();
        List<Thread> threads = new ArrayList<>();
        for (int t = 0; t < 8; t++) {
            Thread thread = new Thread(() -> {
                List<String> local = new ArrayList<>();
                for (int i = 0; i < 500; i++) {
                    local.add(generator.next());
                }
                synchronized (results) {
                    results.addAll(local);
                }
            });
            threads.add(thread);
            thread.start();
        }
        for (Thread thread : threads) {
            thread.join();
        }
        assertEquals(4000, results.size());
        assertEquals(results.size(), new HashSet<>(results).size());
    }
}
