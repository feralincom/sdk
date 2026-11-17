package com.feralin.sdk;

import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * {@code trackRevenue} sözleşmesi (F5-E04-T01): olay adı {@code feralin_purchase}; tutar küçük birimde tam sayı (kuruş, cent),
 * para birimi ISO 4217. İstemci beyanıdır: {@code verified} hiçbir zaman gönderilmez, doğrulama sunucu tarafı makbuz
 * doğrulayıcısınındır. Kurallar Web, Node, Python, Go ve .NET SDK'larıyla birebir aynıdır.
 *
 * <pre>{@code
 * client.trackRevenue(Revenue.builder("GPA.1234", 4999, "TRY").productId("pro_monthly").build());
 * }</pre>
 */
public final class Revenue {
    /** Gelir olayının adı. */
    public static final String EVENT_NAME = "feralin_purchase";
    /** Küçük birimde üst sınır (JS güvenli tam sayı); defter ve toplayıcı bunu taşır. */
    public static final long MAX_AMOUNT_MINOR = 9_007_199_254_740_991L;
    /** En büyük adet. */
    public static final int MAX_QUANTITY = 100_000;

    // İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
    private static final List<String> RESERVED_KEYS =
            Arrays.asList("verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt");
    private static final Pattern CURRENCY = Pattern.compile("[A-Z]{3}");

    /** Satın alma türü. */
    public enum PurchaseType {
        /** Tek seferlik satın alma. */
        PURCHASE("purchase"),
        /** Abonelik başlangıcı. */
        SUBSCRIPTION_START("subscription_start"),
        /** Abonelik yenilemesi. */
        SUBSCRIPTION_RENEW("subscription_renew"),
        /** Abonelik iptali; tutar 0 olmalı. */
        SUBSCRIPTION_CANCEL("subscription_cancel");

        private final String wire;

        PurchaseType(String wire) {
            this.wire = wire;
        }

        /**
         * @return tel üzerindeki değer
         */
        public String wire() {
            return wire;
        }
    }

    /** Makbuz sağlayıcısı. */
    public enum ReceiptProvider {
        /** App Store. */
        APPLE("apple"),
        /** Google Play. */
        GOOGLE("google"),
        /** Stripe. */
        STRIPE("stripe");

        private final String wire;

        ReceiptProvider(String wire) {
            this.wire = wire;
        }

        /**
         * @return tel üzerindeki değer
         */
        public String wire() {
            return wire;
        }
    }

    private final Map<String, Object> properties;

    private Revenue(Map<String, Object> properties) {
        this.properties = properties;
    }

    /**
     * Yeni gelir kurucusu.
     *
     * @param transactionId mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz (1-128 karakter); sunucu aynı işlemi
     *     ikinci kez saymaz
     * @param amountMinor küçük birimde satır toplamı (49,99 TL için 4999); adetle çarpılmaz, abonelik iptalinde 0
     * @param currency ISO 4217, üç büyük harf
     * @return kurucu
     */
    public static Builder builder(String transactionId, long amountMinor, String currency) {
        return new Builder(transactionId, amountMinor, currency);
    }

    /**
     * Tel üzerindeki özellikler (salt okunur kopya).
     *
     * @return {@code feralin_purchase} özellikleri
     */
    public Map<String, Object> toProperties() {
        return Collections.unmodifiableMap(new LinkedHashMap<>(properties));
    }

    /** {@link Revenue} kurucusu. */
    public static final class Builder {
        private final String transactionId;
        private final long amountMinor;
        private final String currency;
        private String productId;
        private int quantity = 1;
        private PurchaseType purchaseType = PurchaseType.PURCHASE;
        private ReceiptProvider receiptProvider;
        private String receiptToken;
        private Map<String, ?> extra;

        private Builder(String transactionId, long amountMinor, String currency) {
            this.transactionId = transactionId;
            this.amountMinor = amountMinor;
            this.currency = currency;
        }

        /**
         * @param value ürün kimliği (1-128 karakter)
         * @return bu kurucu
         */
        public Builder productId(String value) {
            productId = value;
            return this;
        }

        /**
         * @param value adet (0-100000, varsayılan 1); bilgi amaçlıdır
         * @return bu kurucu
         */
        public Builder quantity(int value) {
            quantity = value;
            return this;
        }

        /**
         * @param value satın alma türü (varsayılan {@link PurchaseType#PURCHASE})
         * @return bu kurucu
         */
        public Builder purchaseType(PurchaseType value) {
            purchaseType = value;
            return this;
        }

        /**
         * İsteğe bağlı ham makbuz; toplayıcı yalnız sağlayıcı adını ve belirtecin özetini saklar.
         *
         * @param provider sağlayıcı
         * @param token makbuz belirteci (1-8192 karakter)
         * @return bu kurucu
         */
        public Builder receipt(ReceiptProvider provider, String token) {
            receiptProvider = provider;
            receiptToken = token;
            return this;
        }

        /**
         * @param value ek olay özellikleri; doğrulama alanları düşürülür, sözleşme alanlarını ezemez
         * @return bu kurucu
         */
        public Builder properties(Map<String, ?> value) {
            extra = value;
            return this;
        }

        /**
         * Girdiyi doğrular.
         *
         * @return gelir beyanı
         * @throws InvalidEventException girdi sözleşmeye uymuyorsa
         */
        public Revenue build() {
            if (transactionId == null || transactionId.isEmpty() || transactionId.length() > 128) {
                throw new InvalidEventException("transaction_id 1..128 karakterlik metin olmalı");
            }
            if (amountMinor < 0 || amountMinor > MAX_AMOUNT_MINOR) {
                throw new InvalidEventException("amount_minor küçük birimde (kuruş, cent) 0..2^53-1 tam sayı olmalı");
            }
            if (currency == null || !CURRENCY.matcher(currency).matches()) {
                throw new InvalidEventException("currency ISO 4217 üç büyük harf olmalı");
            }
            if (productId != null && (productId.isEmpty() || productId.length() > 128)) {
                throw new InvalidEventException("product_id 1..128 karakterlik metin olmalı");
            }
            if (quantity < 0 || quantity > MAX_QUANTITY) {
                throw new InvalidEventException("quantity 0..100000 tam sayı olmalı");
            }
            if (purchaseType == null) {
                throw new InvalidEventException("purchase_type null olamaz");
            }
            // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
            if (purchaseType == PurchaseType.SUBSCRIPTION_CANCEL && amountMinor != 0) {
                throw new InvalidEventException("subscription_cancel için amount_minor 0 olmalı");
            }
            if ((receiptProvider == null) != (receiptToken == null)) {
                throw new InvalidEventException("receipt için sağlayıcı ve belirteç birlikte verilmeli");
            }
            if (receiptToken != null && (receiptToken.isEmpty() || receiptToken.length() > 8192)) {
                throw new InvalidEventException("receipt.token 1..8192 karakterlik metin olmalı");
            }
            // Sözleşme alanları önce yazılır: 100 özellik sınırını aşan girdi çağıranın ek alanlarıdır.
            Map<String, Object> props = new LinkedHashMap<>();
            props.put("transaction_id", transactionId);
            props.put("amount_minor", amountMinor);
            props.put("currency", currency);
            props.put("quantity", quantity);
            props.put("purchase_type", purchaseType.wire());
            if (productId != null) {
                props.put("product_id", productId);
            }
            if (receiptProvider != null) {
                Map<String, Object> receipt = new LinkedHashMap<>();
                receipt.put("provider", receiptProvider.wire());
                receipt.put("token", receiptToken);
                props.put("receipt", receipt);
            }
            if (extra != null) {
                for (Map.Entry<String, ?> entry : extra.entrySet()) {
                    String key = entry.getKey();
                    if (key != null && !RESERVED_KEYS.contains(key) && !props.containsKey(key)) {
                        props.put(key, entry.getValue());
                    }
                }
            }
            return new Revenue(props);
        }
    }
}
