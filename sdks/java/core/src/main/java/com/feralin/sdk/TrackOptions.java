package com.feralin.sdk;

import java.time.Instant;

/** Bir olaya özgü isteğe bağlı alanlar. */
public final class TrackOptions {
    private final String userId;
    private final String anonymousId;
    private final String sessionId;
    private final Instant occurredAt;
    private final Context context;

    private TrackOptions(Builder builder) {
        userId = builder.userId;
        anonymousId = builder.anonymousId;
        sessionId = builder.sessionId;
        occurredAt = builder.occurredAt;
        context = builder.context;
    }

    /**
     * Boş seçenek kurucusu.
     *
     * @return yeni kurucu
     */
    public static Builder builder() {
        return new Builder();
    }

    String userId() {
        return userId;
    }

    String anonymousId() {
        return anonymousId;
    }

    String sessionId() {
        return sessionId;
    }

    Instant occurredAt() {
        return occurredAt;
    }

    Context context() {
        return context;
    }

    /** {@link TrackOptions} kurucusu. */
    public static final class Builder {
        private String userId;
        private String anonymousId;
        private String sessionId;
        private Instant occurredAt;
        private Context context;

        private Builder() {
        }

        /**
         * @param value müşteri uygulamasının kullanıcı kimliği; PII olmamalı
         * @return bu kurucu
         */
        public Builder userId(String value) {
            userId = value;
            return this;
        }

        /**
         * @param value anonim kimlik
         * @return bu kurucu
         */
        public Builder anonymousId(String value) {
            anonymousId = value;
            return this;
        }

        /**
         * @param value oturum kimliği
         * @return bu kurucu
         */
        public Builder sessionId(String value) {
            sessionId = value;
            return this;
        }

        /**
         * @param value olayın gerçekleşme anı; verilmezse istemcinin saati kullanılır
         * @return bu kurucu
         */
        public Builder occurredAt(Instant value) {
            occurredAt = value;
            return this;
        }

        /**
         * @param value olay bağlamı
         * @return bu kurucu
         */
        public Builder context(Context value) {
            context = value;
            return this;
        }

        /** @return değişmez seçenekler */
        public TrackOptions build() {
            return new TrackOptions(this);
        }
    }
}
