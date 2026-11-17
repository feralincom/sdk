package com.feralin.sdk;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/** İstemci tarafı UTP v1 doğrulaması; packages/schemas/utp/v1/event.schema.json ile birebir. */
final class Events {
    static final int MAX_EVENT_NAME_LENGTH = 100;
    static final int MAX_PROPERTIES = 100;
    static final int MAX_IDENTIFIER_LENGTH = 128;
    static final String ATTRIBUTION_CLICK_PROPERTY = "fr_click";

    private static final Pattern EVENT_NAME = Pattern.compile("[a-z][a-z0-9_]*");
    private static final Pattern PROPERTY_KEY = Pattern.compile("[a-zA-Z][a-zA-Z0-9_]{0,63}");
    // Locale.ROOT: Arapça gibi yerel ayarlarda rakamlar ASCII dışına çıkmasın.
    private static final DateTimeFormatter TIME_FORMAT =
            DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT).withZone(ZoneOffset.UTC);

    private Events() {
    }

    static String validateEventName(String name) {
        if (name == null || name.isEmpty() || name.length() > MAX_EVENT_NAME_LENGTH || !EVENT_NAME.matcher(name).matches()) {
            throw new InvalidEventException("event_name snake_case olmalı (^[a-z][a-z0-9_]*$, en fazla 100 karakter)");
        }
        return name;
    }

    static Map<String, Object> validateProperties(Map<String, ?> properties) {
        if (properties == null || properties.isEmpty()) {
            return null;
        }
        if (properties.size() > MAX_PROPERTIES) {
            throw new InvalidEventException("properties en fazla 100 anahtar içerebilir (" + properties.size() + " verildi)");
        }
        Map<String, Object> copy = new LinkedHashMap<>();
        for (Map.Entry<?, ?> entry : properties.entrySet()) {
            Object key = entry.getKey();
            if (!(key instanceof String) || !PROPERTY_KEY.matcher((String) key).matches()) {
                throw new InvalidEventException("properties anahtarı ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ desenine uymalı");
            }
            copy.put((String) key, entry.getValue());
        }
        return copy;
    }

    static String validateIdentifier(String value, String fieldName) {
        if (value == null || value.isEmpty()) {
            return null;
        }
        if (value.length() > MAX_IDENTIFIER_LENGTH) {
            throw new InvalidEventException(fieldName + " en fazla 128 karakterlik metin olmalı");
        }
        return value;
    }

    /** UTC RFC3339, milisaniye hassasiyeti (ör. 2026-11-03T10:00:00.123Z). */
    static String formatTime(Instant moment) {
        return TIME_FORMAT.format(moment);
    }
}
