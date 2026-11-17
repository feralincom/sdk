package com.feralin.sdk;

import java.util.HashMap;
import java.util.Map;

/**
 * Hata fırtınası sınırı: pencere başına en çok {@code maxEvents} olay, aynı parmak izi için en çok {@code maxPerFingerprint};
 * örnekleme {@code sampleRate} (0..1). Sayılar Android SDK'sıyla aynıdır (20 ve 3); sunucu süreci uzun yaşadığından süreç ömrü
 * yerine 60 saniyelik pencerede sayılır.
 */
final class ErrorLimiter {
    static final long WINDOW_MILLIS = 60_000L;

    private final int maxEvents;
    private final int maxPerFingerprint;
    private final double sampleRate;
    private long windowStart = Long.MIN_VALUE;
    private int total;
    private final Map<String, Integer> perFingerprint = new HashMap<>();

    ErrorLimiter(int maxEvents, int maxPerFingerprint, double sampleRate) {
        this.maxEvents = maxEvents;
        this.maxPerFingerprint = maxPerFingerprint;
        this.sampleRate = Math.max(0.0, Math.min(1.0, sampleRate));
    }

    ErrorLimiter(double sampleRate) {
        this(20, 3, sampleRate);
    }

    synchronized boolean allow(String fingerprint, long nowMillis, double random) {
        if (windowStart == Long.MIN_VALUE || nowMillis - windowStart >= WINDOW_MILLIS || nowMillis < windowStart) {
            windowStart = nowMillis;
            total = 0;
            perFingerprint.clear();
        }
        if (total >= maxEvents) {
            return false;
        }
        if (sampleRate < 1.0 && random >= sampleRate) {
            return false;
        }
        int seen = perFingerprint.getOrDefault(fingerprint, 0);
        if (seen >= maxPerFingerprint) {
            return false;
        }
        perFingerprint.put(fingerprint, seen + 1);
        total++;
        return true;
    }
}
