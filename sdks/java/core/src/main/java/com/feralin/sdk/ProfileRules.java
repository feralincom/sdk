package com.feralin.sdk;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * UTP §8.2 kimlik yöntemleri: {@code group} → {@code fr_group}, {@code setUserProperties} → {@code fr_user_properties}. Kurallar
 * bütün SDK'larda (sdks/node/src/profile.ts) ve toplayıcıda (services/collect/internal/httpapi/profile_filter.go) birebir aynıdır;
 * toplayıcı ayrıca projenin izin listesini uygular (liste boşsa hiçbir kullanıcı özelliği saklanmaz).
 */
final class ProfileRules {
    static final String GROUP_EVENT_NAME = "fr_group";
    static final String USER_PROPERTIES_EVENT_NAME = "fr_user_properties";
    /** Çağrı başına en çok bu kadar özellik. */
    static final int MAX_PROPERTIES = 50;
    /** Dizge değerin en çok karakter (kod noktası) sayısı. */
    static final int MAX_VALUE_LENGTH = 256;
    static final int MAX_GROUP_ID_LENGTH = 128;

    private static final Pattern KEY = Pattern.compile("[a-zA-Z][a-zA-Z0-9_]{0,63}");
    private static final Pattern EMAIL = Pattern.compile("[^\\s@]+@[^\\s@]+\\.[^\\s@]+");
    private static final Pattern CONTROL = Pattern.compile("\\p{Cc}");
    // Küçük harf ya da rakamdan sonra gelen büyük harf yeni sözcük başlatır; alt çizgi ayırıcıdır.
    private static final Pattern WORD_BOUNDARY = Pattern.compile("(?<=[\\p{Ll}\\p{Nd}])(?=\\p{Lu})");
    /** İstemci doğrulama beyan edemez: sunucu alanları düşer. */
    private static final Set<String> RESERVED = new HashSet<>(
            Arrays.asList("verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"));
    // Kişisel veri anahtar kuralı (toplayıcıdaki piiTokens, piiFragments, piiExact ile aynı listeler).
    private static final Set<String> PII_TOKENS = new HashSet<>(Arrays.asList(
            "email", "mail", "phone", "tel", "telephone", "mobile", "msisdn", "gsm",
            "ip", "ipv4", "ipv6", "ssn", "tckn", "passport", "password", "iban",
            "address", "adres", "eposta", "telefon", "soyad", "surname", "firstname",
            "lastname", "fullname", "birthdate", "birthday", "dob"));
    private static final List<String> PII_FRAGMENTS = Arrays.asList(
            "email", "phonenumber", "ipaddress", "firstname", "lastname", "fullname", "surname", "soyad", "eposta", "telefon", "password", "birthdate");
    private static final Set<String> PII_EXACT = new HashSet<>(Arrays.asList("name", "username", "displayname", "isim", "ad"));

    private ProfileRules() {
    }

    /** Anahtar kişisel veriye (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) benziyor mu. */
    static boolean isPiiLikeKey(String key) {
        String snake = WORD_BOUNDARY.matcher(key).replaceAll("_").toLowerCase(Locale.ROOT);
        StringBuilder joined = new StringBuilder();
        for (String token : snake.split("_")) {
            if (token.isEmpty()) {
                continue;
            }
            if (PII_TOKENS.contains(token)) {
                return true;
            }
            joined.append(token);
        }
        String text = joined.toString();
        if (PII_EXACT.contains(text)) {
            return true;
        }
        for (String fragment : PII_FRAGMENTS) {
            if (text.contains(fragment)) {
                return true;
            }
        }
        return false;
    }

    static boolean validKey(Object key) {
        return key instanceof String
                && KEY.matcher((String) key).matches()
                && !RESERVED.contains(key)
                && !isPiiLikeKey((String) key);
    }

    static boolean validValue(Object value) {
        if (value instanceof Boolean
                || value instanceof Integer
                || value instanceof Long
                || value instanceof Short
                || value instanceof Byte
                || value instanceof BigInteger
                || value instanceof BigDecimal) {
            return true;
        }
        if (value instanceof Double || value instanceof Float) {
            double number = ((Number) value).doubleValue();
            return !Double.isNaN(number) && !Double.isInfinite(number);
        }
        if (value instanceof String) {
            String text = (String) value;
            return text.codePointCount(0, text.length()) <= MAX_VALUE_LENGTH
                    && !EMAIL.matcher(text).find()
                    && !CONTROL.matcher(text).find();
        }
        return false;
    }

    /** Özellikleri kimlik sözleşmesine indirger; geçersiz anahtar ve değer düşer, 50 özellikten sonrası alınmaz. */
    static Map<String, Object> sanitize(Map<String, ?> properties) {
        Map<String, Object> out = new LinkedHashMap<>();
        if (properties == null) {
            return out;
        }
        for (Map.Entry<String, ?> entry : properties.entrySet()) {
            if (out.size() >= MAX_PROPERTIES) {
                break;
            }
            if (validKey(entry.getKey()) && validValue(entry.getValue())) {
                out.put(entry.getKey(), entry.getValue());
            }
        }
        return out;
    }

    /** Grup kimliği: 1-128 karakter, yalnız boşluk değil, {@code @} ve kontrol karakteri yok (kişisel veri taşımamalı). */
    static boolean validGroupId(String groupId) {
        return groupId != null
                && !groupId.trim().isEmpty()
                && groupId.codePointCount(0, groupId.length()) <= MAX_GROUP_ID_LENGTH
                && groupId.indexOf('@') < 0
                && !CONTROL.matcher(groupId).find();
    }
}
