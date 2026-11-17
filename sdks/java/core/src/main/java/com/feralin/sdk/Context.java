package com.feralin.sdk;

import java.util.LinkedHashMap;
import java.util.Map;

/** UTP v1 şemasındaki context nesnesi; yalnız dolu alanlar gönderilir. */
public final class Context {
    private final String pageUrl;
    private final String pageTitle;
    private final String referrer;
    private final String locale;
    private final String timezone;
    private final Integer screenWidth;
    private final Integer screenHeight;
    private final String appVersion;
    private final String appBuild;

    private Context(Builder builder) {
        pageUrl = builder.pageUrl;
        pageTitle = builder.pageTitle;
        referrer = builder.referrer;
        locale = builder.locale;
        timezone = builder.timezone;
        screenWidth = builder.screenWidth;
        screenHeight = builder.screenHeight;
        appVersion = builder.appVersion;
        appBuild = builder.appBuild;
    }

    /**
     * Boş bir context kurucusu.
     *
     * @return yeni kurucu
     */
    public static Builder builder() {
        return new Builder();
    }

    Map<String, Object> toMap() {
        Map<String, Object> out = new LinkedHashMap<>();
        putIfPresent(out, "page_url", pageUrl);
        putIfPresent(out, "page_title", pageTitle);
        putIfPresent(out, "referrer", referrer);
        putIfPresent(out, "locale", locale);
        putIfPresent(out, "timezone", timezone);
        if (screenWidth != null && screenHeight != null) {
            Map<String, Object> screen = new LinkedHashMap<>();
            screen.put("width", screenWidth);
            screen.put("height", screenHeight);
            out.put("screen", screen);
        }
        Map<String, Object> app = new LinkedHashMap<>();
        putIfPresent(app, "version", appVersion);
        putIfPresent(app, "build", appBuild);
        if (!app.isEmpty()) {
            out.put("app", app);
        }
        return out;
    }

    private static void putIfPresent(Map<String, Object> out, String key, String value) {
        if (value != null && !value.isEmpty()) {
            out.put(key, value);
        }
    }

    /** {@link Context} kurucusu. */
    public static final class Builder {
        private String pageUrl;
        private String pageTitle;
        private String referrer;
        private String locale;
        private String timezone;
        private Integer screenWidth;
        private Integer screenHeight;
        private String appVersion;
        private String appBuild;

        private Builder() {
        }

        /**
         * @param value sayfa adresi
         * @return bu kurucu
         */
        public Builder pageUrl(String value) {
            pageUrl = value;
            return this;
        }

        /**
         * @param value sayfa başlığı
         * @return bu kurucu
         */
        public Builder pageTitle(String value) {
            pageTitle = value;
            return this;
        }

        /**
         * @param value yönlendiren adres
         * @return bu kurucu
         */
        public Builder referrer(String value) {
            referrer = value;
            return this;
        }

        /**
         * @param value dil etiketi, ör. tr-TR
         * @return bu kurucu
         */
        public Builder locale(String value) {
            locale = value;
            return this;
        }

        /**
         * @param value saat dilimi, ör. Europe/Istanbul
         * @return bu kurucu
         */
        public Builder timezone(String value) {
            timezone = value;
            return this;
        }

        /**
         * @param width ekran genişliği
         * @param height ekran yüksekliği
         * @return bu kurucu
         */
        public Builder screen(int width, int height) {
            screenWidth = width;
            screenHeight = height;
            return this;
        }

        /**
         * @param version uygulama sürümü veya null
         * @param build uygulama derleme numarası veya null
         * @return bu kurucu
         */
        public Builder app(String version, String build) {
            appVersion = version;
            appBuild = build;
            return this;
        }

        /** @return değişmez context */
        public Context build() {
            return new Context(this);
        }
    }
}
