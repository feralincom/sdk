package com.feralin.sdk;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Kuyruğa eklenmiş UTP v1 olayı; alan adları tel biçimiyle birebirdir. tenant_id, project_id ve verified alanları
 * istemciden asla gönderilmez, sunucu çözer.
 */
public final class UtpEvent {
    private final Map<String, Object> wire;

    UtpEvent(Map<String, Object> wire) {
        this.wire = Collections.unmodifiableMap(new LinkedHashMap<>(wire));
    }

    /** @return ULID olay kimliği */
    public String eventId() {
        return (String) wire.get("event_id");
    }

    /** @return olay adı */
    public String eventName() {
        return (String) wire.get("event_name");
    }

    /** @return UTC RFC3339 milisaniyeli gerçekleşme anı */
    public String occurredAt() {
        return (String) wire.get("occurred_at");
    }

    /** @return gönderilecek user_id veya null */
    public String userId() {
        return (String) wire.get("user_id");
    }

    /** @return gönderilecek özellikler; yoksa boş */
    @SuppressWarnings("unchecked")
    public Map<String, Object> properties() {
        Object properties = wire.get("properties");
        return properties == null ? Collections.emptyMap() : Collections.unmodifiableMap((Map<String, Object>) properties);
    }

    /** @return telde giden biçimiyle olayın bütün alanları */
    public Map<String, Object> toMap() {
        return wire;
    }

    @Override
    public String toString() {
        // Özellik değerleri log satırına taşınmasın.
        return "UtpEvent{event_id=" + eventId() + ", event_name=" + eventName() + "}";
    }
}
