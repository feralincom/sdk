package com.feralin.sdk;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * {@code fr_error} sözleşmesi (X4): hata sınıfı adı, temizlenmiş kısa mesaj, normalize edilmiş çerçevelerin özeti olan parmak izi ve
 * en üst çerçeve. Ham yığın izi, kaynak dosya yolu ve kullanıcı verisi GİTMEZ. Sembolleştirme için uygulama çerçevelerinin konumu
 * ayrıca gider ({@code frames}: en çok 5; derlenmiş sınıf adı, yöntem adı ve satır). Kurallar Android SDK'sının
 * {@code internal/ErrorEvent.kt} dosyasıyla birebir aynıdır; toplayıcı mesajı ayrıca temizler.
 */
final class ErrorEvent {
    static final String NAME = "fr_error";
    static final String ORIGIN_UNCAUGHT = "uncaught_exception";
    static final String ORIGIN_HANDLED = "handled";
    static final String ORIGIN_MANUAL = "manual";
    static final int MAX_MESSAGE = 200;
    static final int MAX_TYPE = 64;
    static final int MAX_FRAME = 160;
    private static final int FINGERPRINT_FRAMES = 5;
    private static final int MAX_LOCATIONS = 5;
    private static final int MAX_FUNCTION = 60;
    private static final int MAX_APP_VERSION = 32;
    // Toplayıcının `frames[].file` kuralı; `$` bu kümede yoktur ve Java tanımlayıcısında `~` olamaz: `$` → `~` geri döndürülebilir.
    private static final Pattern LOCATION_FILE = Pattern.compile("[A-Za-z0-9._~-]{1,128}");

    // Çerçeve sistemi: bunlar parmak izine girmez (uygulama çerçevesi varsa); hepsi sistemse tüm çerçeveler kullanılır.
    private static final List<String> FRAMEWORK_PREFIXES = Arrays.asList(
            "java.", "javax.", "jdk.", "sun.", "com.sun.", "kotlin.", "kotlinx.", "org.springframework.", "org.apache.catalina.",
            "org.apache.tomcat.", "org.eclipse.jetty.", "io.undertow.", "io.netty.", "reactor.");
    private static final Pattern SYNTHETIC_SUFFIX = Pattern.compile("[$][$]ExternalSyntheticLambda\\d*|[$]\\d+|[$][$]Lambda.*");

    private static final Pattern URL = Pattern.compile("(?i)\\b[a-z][a-z0-9+.-]*://[^\\s\"'<>]+");
    private static final Pattern EMAIL = Pattern.compile("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}");
    private static final Pattern UUID = Pattern.compile("(?i)\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b");
    private static final Pattern TOKEN = Pattern.compile("\\b[A-Za-z0-9_\\-+/=]{24,}\\b");
    private static final Pattern NUMBER = Pattern.compile("\\+?\\d[\\d\\s\\-().]{5,}\\d");
    private static final Pattern WHITESPACE = Pattern.compile("\\s+");
    private static final Pattern DIGITS = Pattern.compile("\\d+");

    private ErrorEvent() {
    }

    /** Mesajdan URL, e-posta, UUID, uzun belirteç ve uzun sayıları çıkarır; 200 karaktere kırpar. Sıra toplayıcıyla aynıdır. */
    static String scrub(String message) {
        String text = URL.matcher(message).replaceAll("[url]");
        text = EMAIL.matcher(text).replaceAll("[email]");
        text = UUID.matcher(text).replaceAll("[id]");
        // Uzun belirteç: 24+ karakter ve en az bir rakam; rakamsız uzun sınıf adları bozulmaz.
        text = replace(TOKEN, text, match -> match.chars().anyMatch(Character::isDigit) ? "[token]" : match);
        // Telefon, kart, kimlik numarası benzeri: ayraçlar dahil en az 7 rakam; kısa sürüm dizgeleri (1.4.2) bozulmaz.
        text = replace(NUMBER, text, match -> match.chars().filter(Character::isDigit).count() >= 7 ? "[num]" : match);
        text = WHITESPACE.matcher(text.trim()).replaceAll(" ");
        return take(text, MAX_MESSAGE);
    }

    /** Çerçeve: {@code sınıf.yöntem}; satır ve dosya yok, derleyicinin ürettiği lambda ekleri atılır. */
    static String frame(StackTraceElement element) {
        return SYNTHETIC_SUFFIX.matcher(element.getClassName()).replaceAll("") + "." + element.getMethodName();
    }

    /** Uygulama çerçeveleri; hiç yoksa (hata tamamen kütüphane içinde) bütün çerçeveler. */
    static List<String> frames(List<StackTraceElement> elements) {
        List<String> app = new ArrayList<>();
        List<String> all = new ArrayList<>();
        for (StackTraceElement element : elements) {
            String label = frame(element);
            all.add(label);
            if (!isFramework(element.getClassName())) {
                app.add(label);
            }
        }
        return app.isEmpty() ? all : app;
    }

    private static boolean isFramework(String className) {
        for (String prefix : FRAMEWORK_PREFIXES) {
            if (className.startsWith(prefix)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Sembolleştirme konumları: uygulama çerçevelerinin ilk beşi; derlenmiş sınıf adı olduğu gibi ({@code $} → {@code ~}), yöntem
     * adı ve satır. Satırı bilinmeyen ya da toplayıcı kuralına sığmayan çerçeve listeye girmez.
     */
    static List<Map<String, Object>> locations(List<StackTraceElement> elements) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (StackTraceElement element : elements) {
            if (out.size() >= MAX_LOCATIONS) {
                break;
            }
            if (isFramework(element.getClassName()) || element.getLineNumber() < 1) {
                continue;
            }
            String file = element.getClassName().replace('$', '~');
            if (!LOCATION_FILE.matcher(file).matches()) {
                continue;
            }
            Map<String, Object> location = new LinkedHashMap<>();
            location.put("file", file);
            location.put("line", Math.min(element.getLineNumber(), 10_000_000));
            location.put("column", 0);
            String method = element.getMethodName();
            if (!method.isEmpty() && method.length() <= MAX_FUNCTION) {
                location.put("function", method);
            }
            out.add(location);
        }
        return out;
    }

    /** Parmak izi: tür ve ilk beş çerçevenin SHA-256 özetinin ilk 16 baytı (32 onaltılık karakter). */
    static String fingerprint(String type, List<String> frames, String message) {
        String basis = frames.isEmpty()
                ? DIGITS.matcher(message).replaceAll("#")
                : String.join("|", frames.subList(0, Math.min(frames.size(), FINGERPRINT_FRAMES)));
        byte[] digest;
        try {
            digest = MessageDigest.getInstance("SHA-256").digest((type + "|" + basis).getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException exc) {
            // SHA-256 her Java platformunda zorunludur.
            throw new IllegalStateException(exc);
        }
        StringBuilder hex = new StringBuilder(32);
        for (int i = 0; i < 16; i++) {
            hex.append(String.format("%02x", digest[i] & 0xff));
        }
        return hex.toString();
    }

    /** Hata gövdesi; sözleşme alanlarının tamamı. {@code appVersion} 1-32 karakterse eklenir. */
    static Map<String, Object> properties(Throwable error, String origin, boolean fatal, String appVersion) {
        Class<?> type = error.getClass();
        String name = type.getSimpleName();
        if (name.isEmpty()) {
            name = type.getName().substring(type.getName().lastIndexOf('.') + 1);
        }
        name = take(name, MAX_TYPE);
        if (name.isEmpty()) {
            name = "Error";
        }
        String message = error.getMessage() == null ? "" : scrub(error.getMessage());
        List<StackTraceElement> elements = Arrays.asList(error.getStackTrace());
        List<String> frames = frames(elements);

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("error_type", name);
        if (!message.isEmpty()) {
            out.put("message", message);
        }
        out.put("fingerprint", fingerprint(name, frames, message));
        if (!frames.isEmpty()) {
            out.put("top_frame", take(frames.get(0), MAX_FRAME));
        }
        out.put("frame_count", Math.min(frames.size(), 1000));
        if (appVersion != null && !appVersion.isEmpty() && appVersion.length() <= MAX_APP_VERSION) {
            out.put("app_version", appVersion);
        }
        out.put("handled", ORIGIN_HANDLED.equals(origin) || ORIGIN_MANUAL.equals(origin));
        out.put("fatal", fatal);
        out.put("origin", origin);
        List<Map<String, Object>> locations = locations(elements);
        if (!locations.isEmpty()) {
            out.put("frames", locations);
        }
        return out;
    }

    private static String take(String text, int limit) {
        if (text.codePointCount(0, text.length()) <= limit) {
            return text;
        }
        return text.substring(0, text.offsetByCodePoints(0, limit));
    }

    private interface Replacer {
        String apply(String match);
    }

    private static String replace(Pattern pattern, String text, Replacer replacer) {
        Matcher matcher = pattern.matcher(text);
        StringBuffer out = new StringBuffer();
        while (matcher.find()) {
            matcher.appendReplacement(out, Matcher.quoteReplacement(replacer.apply(matcher.group())));
        }
        matcher.appendTail(out);
        return out.toString();
    }
}
