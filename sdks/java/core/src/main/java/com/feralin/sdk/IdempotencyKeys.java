package com.feralin.sdk;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/** Web, Node, .NET, Python, Android ve Flutter SDK'larıyla aynı batch anahtarı. */
public final class IdempotencyKeys {
    private static final long FNV_OFFSET = 0xCBF29CE484222325L;
    private static final long FNV_PRIME = 0x100000001B3L;

    private IdempotencyKeys() {
    }

    /**
     * Sıralı bütün event_id değerlerinin FNV-1a 64 özeti ve olay sayısı.
     *
     * @param eventIds batch içindeki olay kimlikleri
     * @return Idempotency-Key başlık değeri
     */
    public static String of(Collection<String> eventIds) {
        List<String> ordered = new ArrayList<>(eventIds);
        Collections.sort(ordered);
        long value = FNV_OFFSET;
        for (byte part : String.join(",", ordered).getBytes(StandardCharsets.UTF_8)) {
            value = (value ^ (part & 0xFFL)) * FNV_PRIME;
        }
        return String.format(Locale.ROOT, "%016x-%d", value, ordered.size());
    }
}
