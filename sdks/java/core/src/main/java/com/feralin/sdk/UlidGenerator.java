package com.feralin.sdk;

import java.security.SecureRandom;
import java.util.function.LongSupplier;

/**
 * Monotonik ULID üretimi (26 karakter Crockford base32), Web SDK ile aynı düzen: 10 karakter zaman (ms) ve 16 adet
 * 5 bitlik rastgele basamak. Aynı milisaniyede veya saat geri gittiğinde son değeri artırarak sıralamayı korur.
 * İş parçacığı güvenlidir.
 */
public final class UlidGenerator {
    static final String CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    private static final int RANDOM_DIGITS = 16;
    private static final int TIME_DIGITS = 10;

    private final LongSupplier nowMillis;
    private final SecureRandom random = new SecureRandom();
    private long lastMillis = -1;
    final int[] lastRandom = new int[RANDOM_DIGITS];

    /** Sistem saatiyle üretici. */
    public UlidGenerator() {
        this(System::currentTimeMillis);
    }

    /** @param nowMillis Unix milisaniye kaynağı */
    public UlidGenerator(LongSupplier nowMillis) {
        this.nowMillis = nowMillis;
    }

    /** @return yeni ULID */
    public synchronized String next() {
        long millis = nowMillis.getAsLong();
        if (millis > lastMillis) {
            fillRandom();
        } else {
            millis = lastMillis;
            if (!increment()) {
                millis += 1;
                fillRandom();
            }
        }
        lastMillis = millis;
        char[] out = new char[TIME_DIGITS + RANDOM_DIGITS];
        long remaining = millis;
        for (int i = TIME_DIGITS - 1; i >= 0; i--) {
            out[i] = CROCKFORD.charAt((int) (remaining & 31));
            remaining >>>= 5;
        }
        for (int i = 0; i < RANDOM_DIGITS; i++) {
            out[TIME_DIGITS + i] = CROCKFORD.charAt(lastRandom[i]);
        }
        return new String(out);
    }

    private void fillRandom() {
        byte[] buffer = new byte[RANDOM_DIGITS];
        random.nextBytes(buffer);
        for (int i = 0; i < RANDOM_DIGITS; i++) {
            lastRandom[i] = buffer[i] & 31;
        }
    }

    // Rastgele kısmı base32 düzeninde bir artırır; bütün basamaklar taşarsa false döner.
    private boolean increment() {
        for (int i = RANDOM_DIGITS - 1; i >= 0; i--) {
            if (lastRandom[i] < 31) {
                lastRandom[i] += 1;
                return true;
            }
            lastRandom[i] = 0;
        }
        return false;
    }

    /**
     * 26 karakterlik Crockford base32 ULID biçim denetimi; ilk karakter en fazla '7'.
     *
     * @param value denetlenecek metin
     * @return biçim uyuyorsa true
     */
    public static boolean isUlid(String value) {
        if (value == null || value.length() != TIME_DIGITS + RANDOM_DIGITS || value.charAt(0) > '7') {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            if (CROCKFORD.indexOf(value.charAt(i)) < 0) {
                return false;
            }
        }
        return true;
    }
}
