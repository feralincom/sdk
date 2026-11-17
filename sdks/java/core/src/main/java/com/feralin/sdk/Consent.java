package com.feralin.sdk;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

/**
 * Değişmez izin anlık görüntüsü. analytics kapalıysa hiçbir olay üretilmez. Server SDK'da izin müşteri uygulamasından
 * geçirilir; bütün alanlar açıkça gönderilir ve varsayılanların hepsi kapalıdır.
 */
public final class Consent {
    private static final Consent NONE = new Consent(false, false, false, false);

    private final boolean analytics;
    private final boolean advertising;
    private final boolean personalization;
    private final boolean sessionReplay;

    /**
     * Bütün alanlarıyla izin.
     *
     * @param analytics analitik ölçüm izni
     * @param advertising reklam ölçümü izni; fr_click yalnız bununla gönderilir
     * @param personalization kişiselleştirme izni
     * @param sessionReplay oturum tekrarı izni
     */
    public Consent(boolean analytics, boolean advertising, boolean personalization, boolean sessionReplay) {
        this.analytics = analytics;
        this.advertising = advertising;
        this.personalization = personalization;
        this.sessionReplay = sessionReplay;
    }

    /**
     * Hiçbir izin yok.
     *
     * @return bütün alanları kapalı izin
     */
    public static Consent none() {
        return NONE;
    }

    /**
     * Yalnız analitik izni.
     *
     * @return analytics açık, diğerleri kapalı izin
     */
    public static Consent analyticsOnly() {
        return new Consent(true, false, false, false);
    }

    /**
     * Analitik ve reklam ölçümü izni.
     *
     * @return analytics ve advertising açık izin
     */
    public static Consent analyticsAndAdvertising() {
        return new Consent(true, true, false, false);
    }

    /** @return analitik ölçüm izni */
    public boolean analytics() {
        return analytics;
    }

    /** @return reklam ölçümü izni */
    public boolean advertising() {
        return advertising;
    }

    /** @return kişiselleştirme izni */
    public boolean personalization() {
        return personalization;
    }

    /** @return oturum tekrarı izni */
    public boolean sessionReplay() {
        return sessionReplay;
    }

    Map<String, Object> toMap() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("analytics", analytics);
        out.put("advertising", advertising);
        out.put("personalization", personalization);
        out.put("session_replay", sessionReplay);
        return out;
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Consent)) {
            return false;
        }
        Consent that = (Consent) other;
        return analytics == that.analytics
                && advertising == that.advertising
                && personalization == that.personalization
                && sessionReplay == that.sessionReplay;
    }

    @Override
    public int hashCode() {
        return Objects.hash(analytics, advertising, personalization, sessionReplay);
    }

    @Override
    public String toString() {
        return "Consent" + toMap();
    }
}
