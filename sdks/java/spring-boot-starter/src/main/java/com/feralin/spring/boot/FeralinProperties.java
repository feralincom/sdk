package com.feralin.spring.boot;

import com.feralin.sdk.FeralinClient;
import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;

/** {@code feralin.*} yapılandırması. */
@ConfigurationProperties(prefix = "feralin")
public class FeralinProperties {
    /** Proje public anahtarı (pk_). Kaynak koda değil, ortama veya sır yöneticisine yazın. */
    private String projectKey;

    /** Toplayıcı kök adresi. */
    private String collectUrl;

    /** Arka plan gönderim aralığı; 0 arka plan göndericiyi kapatır. */
    private Duration flushInterval = FeralinClient.DEFAULT_FLUSH_INTERVAL;

    /** Batch boyutu; 1 ile 500 arasına çekilir. */
    private int batchSize = FeralinClient.DEFAULT_BATCH_SIZE;

    /** Kuyruk sınırı; aşılınca en eski olay atılır. */
    private int queueLimit = FeralinClient.DEFAULT_QUEUE_LIMIT;

    /** İstek süre sınırı. */
    private Duration timeout = FeralinClient.DEFAULT_TIMEOUT;

    /** Varsayılan izin; bütün alanlar kapalı başlar. */
    private final ConsentProperties consent = new ConsentProperties();

    public String getProjectKey() {
        return projectKey;
    }

    public void setProjectKey(String projectKey) {
        this.projectKey = projectKey;
    }

    public String getCollectUrl() {
        return collectUrl;
    }

    public void setCollectUrl(String collectUrl) {
        this.collectUrl = collectUrl;
    }

    public Duration getFlushInterval() {
        return flushInterval;
    }

    public void setFlushInterval(Duration flushInterval) {
        this.flushInterval = flushInterval;
    }

    public int getBatchSize() {
        return batchSize;
    }

    public void setBatchSize(int batchSize) {
        this.batchSize = batchSize;
    }

    public int getQueueLimit() {
        return queueLimit;
    }

    public void setQueueLimit(int queueLimit) {
        this.queueLimit = queueLimit;
    }

    public Duration getTimeout() {
        return timeout;
    }

    public void setTimeout(Duration timeout) {
        this.timeout = timeout;
    }

    public ConsentProperties getConsent() {
        return consent;
    }

    // Anahtar log veya hata iletisine taşınmasın.
    @Override
    public String toString() {
        return "FeralinProperties{collectUrl=" + collectUrl + ", projectKey=" + (projectKey == null ? "yok" : "***") + "}";
    }

    /** Varsayılan izin alanları. */
    public static class ConsentProperties {
        /** Analitik ölçüm izni. */
        private boolean analytics;

        /** Reklam ölçümü izni; fr_click yalnız bununla gönderilir. */
        private boolean advertising;

        /** Kişiselleştirme izni. */
        private boolean personalization;

        /** Oturum tekrarı izni. */
        private boolean sessionReplay;

        public boolean isAnalytics() {
            return analytics;
        }

        public void setAnalytics(boolean analytics) {
            this.analytics = analytics;
        }

        public boolean isAdvertising() {
            return advertising;
        }

        public void setAdvertising(boolean advertising) {
            this.advertising = advertising;
        }

        public boolean isPersonalization() {
            return personalization;
        }

        public void setPersonalization(boolean personalization) {
            this.personalization = personalization;
        }

        public boolean isSessionReplay() {
            return sessionReplay;
        }

        public void setSessionReplay(boolean sessionReplay) {
            this.sessionReplay = sessionReplay;
        }

        com.feralin.sdk.Consent toConsent() {
            return new com.feralin.sdk.Consent(analytics, advertising, personalization, sessionReplay);
        }
    }
}
