package com.feralin.sdk;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Pattern;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

/** Gelir ({@code feralin_purchase}), kimlik ({@code fr_group}, {@code fr_user_properties}) ve hata ({@code fr_error}) sözleşmeleri. */
class ContractEventsTest {
    private static final String TEST_KEY = "pk_live_0123456789abcdef0123456789abcdef";

    /** Testte ileri sarılabilen saat. */
    private static final class MutableClock extends Clock {
        long millis = 1_700_000_000_000L;

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return Instant.ofEpochMilli(millis);
        }
    }

    private final List<String> bodies = new ArrayList<>();
    private final List<FeralinClient> clients = new ArrayList<>();
    private final MutableClock clock = new MutableClock();

    @AfterEach
    void stop() {
        for (FeralinClient client : clients) {
            client.shutdown(Duration.ofSeconds(1));
        }
    }

    private FeralinClient client(Consent consent) {
        FeralinClient client = FeralinClient.builder(TEST_KEY, "http://collector.test")
                .consent(consent)
                .flushInterval(Duration.ZERO)
                .clock(clock)
                .appVersion("1.4.2")
                .transport((url, body, headers, timeout) -> {
                    bodies.add(new String(body, StandardCharsets.UTF_8));
                    return new Transport.Response(202, "{\"accepted\":1,\"rejected\":0}".getBytes(StandardCharsets.UTF_8), null);
                })
                .build();
        clients.add(client);
        return client;
    }

    private FeralinClient client() {
        return client(Consent.analyticsOnly());
    }

    private static UtpEvent event(Optional<UtpEvent> tracked) {
        assertTrue(tracked.isPresent(), "olay üretilmeliydi");
        return tracked.get();
    }

    // --- Gelir -------------------------------------------------------------------------------------------------

    @Test
    void revenueContractNeverSendsVerified() {
        FeralinClient client = client();
        Map<String, Object> extra = new LinkedHashMap<>();
        extra.put("verified", true);
        extra.put("receipt_provider", "apple");
        extra.put("amount_minor", 1);
        extra.put("plan", "pro");
        Revenue revenue = Revenue.builder("GPA.1234-5678", 4999, "TRY")
                .productId("pro_monthly")
                .quantity(2)
                .purchaseType(Revenue.PurchaseType.SUBSCRIPTION_START)
                .receipt(Revenue.ReceiptProvider.GOOGLE, "tok_1")
                .properties(extra)
                .build();
        UtpEvent sent = event(client.trackRevenue(revenue, TrackOptions.builder().userId("u1").build()));
        assertEquals("feralin_purchase", sent.eventName());
        assertEquals("feralin_purchase", Revenue.EVENT_NAME);
        Map<String, Object> props = sent.properties();
        assertEquals(Arrays.asList("transaction_id", "amount_minor", "currency", "quantity", "purchase_type", "product_id", "receipt", "plan"),
                new ArrayList<>(props.keySet()));
        assertEquals(4999L, props.get("amount_minor"));
        assertEquals("TRY", props.get("currency"));
        assertEquals(2, props.get("quantity"));
        assertEquals("subscription_start", props.get("purchase_type"));
        Map<String, Object> receipt = new LinkedHashMap<>();
        receipt.put("provider", "google");
        receipt.put("token", "tok_1");
        assertEquals(receipt, props.get("receipt"));
        client.flush();
        assertFalse(bodies.get(0).contains("verified"));

        UtpEvent plain = event(client.trackRevenue(Revenue.builder("t2", 0, "USD").purchaseType(Revenue.PurchaseType.SUBSCRIPTION_CANCEL).build()));
        assertEquals(1, plain.properties().get("quantity"));
        assertEquals("purchase", event(client.trackRevenue(Revenue.builder("t3", 100, "EUR").build())).properties().get("purchase_type"));
    }

    @Test
    void invalidRevenueIsRejected() {
        List<Runnable> invalid = Arrays.asList(
                () -> Revenue.builder("", 1, "TRY").build(),
                () -> Revenue.builder(null, 1, "TRY").build(),
                () -> Revenue.builder("x".repeat(129), 1, "TRY").build(),
                () -> Revenue.builder("t", -1, "TRY").build(),
                () -> Revenue.builder("t", Revenue.MAX_AMOUNT_MINOR + 1, "TRY").build(),
                () -> Revenue.builder("t", 1, "try").build(),
                () -> Revenue.builder("t", 1, "TRYY").build(),
                () -> Revenue.builder("t", 1, "TRY").productId("").build(),
                () -> Revenue.builder("t", 1, "TRY").quantity(-1).build(),
                () -> Revenue.builder("t", 1, "TRY").quantity(100_001).build(),
                () -> Revenue.builder("t", 1, "TRY").purchaseType(null).build(),
                () -> Revenue.builder("t", 1, "TRY").purchaseType(Revenue.PurchaseType.SUBSCRIPTION_CANCEL).build(),
                () -> Revenue.builder("t", 1, "TRY").receipt(Revenue.ReceiptProvider.APPLE, "").build(),
                () -> Revenue.builder("t", 1, "TRY").receipt(Revenue.ReceiptProvider.APPLE, "t".repeat(8193)).build(),
                () -> Revenue.builder("t", 1, "TRY").receipt(null, "tok").build());
        for (Runnable attempt : invalid) {
            assertThrows(InvalidEventException.class, attempt::run);
        }
        assertThrows(InvalidEventException.class, () -> client().trackRevenue(null));
        Revenue.builder("t", Revenue.MAX_AMOUNT_MINOR, "TRY").quantity(100_000).build();
    }

    // --- Kimlik ------------------------------------------------------------------------------------------------

    @Test
    void groupAndUserPropertiesFollowProfileContract() {
        FeralinClient client = client();
        Map<String, Object> traits = new LinkedHashMap<>();
        traits.put("plan", "team");
        traits.put("email", "x@y.co");
        traits.put("group_id", "baska");
        traits.put("seats", 12);
        UtpEvent group = event(client.group("acme-team", traits, TrackOptions.builder().userId("u1").build()));
        assertEquals("fr_group", group.eventName());
        Map<String, Object> expected = new LinkedHashMap<>();
        expected.put("plan", "team");
        expected.put("seats", 12);
        expected.put("group_id", "acme-team");
        assertEquals(expected, group.properties());
        for (String bad : Arrays.asList("", "   ", "a@b", "g".repeat(129), "x\ny")) {
            assertFalse(client.group(bad, null).isPresent(), bad);
        }
        assertTrue(client.group("g".repeat(128), null).isPresent());

        Map<String, Object> props = new LinkedHashMap<>();
        props.put("plan", "pro");
        props.put("userEmail", "a");
        props.put("phoneNumber", "1");
        props.put("firstName", "Ali");
        props.put("verified", true);
        props.put("bio", "a@b.co");
        props.put("score", Double.NaN);
        props.put("long", "x".repeat(257));
        props.put("nested", Map.of("a", 1));
        props.put("beta", true);
        UtpEvent user = event(client.setUserProperties(props));
        assertEquals("fr_user_properties", user.eventName());
        Map<String, Object> clean = new LinkedHashMap<>();
        clean.put("plan", "pro");
        clean.put("beta", true);
        assertEquals(clean, user.properties());
        assertFalse(client.setUserProperties(Map.of("email", "x")).isPresent());

        Map<String, Object> many = new LinkedHashMap<>();
        for (int i = 0; i < 60; i++) {
            many.put("k" + i, i);
        }
        assertEquals(ProfileRules.MAX_PROPERTIES, event(client.setUserProperties(many)).properties().size());
    }

    @Test
    void piiKeyRuleMatchesOtherSdks() {
        for (String key : Arrays.asList("email", "userEmail", "email_address", "phone", "phoneNumber", "mobile", "ip", "userIP", "ipv4",
                "ip_address", "firstName", "last_name", "fullName", "name", "userName", "displayName", "address", "tckn", "birthDate", "dob")) {
            assertTrue(ProfileRules.isPiiLikeKey(key), key);
        }
        for (String key : Arrays.asList("plan", "tier", "zip_code", "company_size", "nameSpace", "shipping_method", "tipping")) {
            assertFalse(ProfileRules.isPiiLikeKey(key), key);
        }
    }

    // --- Hata --------------------------------------------------------------------------------------------------

    private static Throwable failingCall(String message) {
        try {
            throw new IllegalStateException(message);
        } catch (IllegalStateException exc) {
            return exc;
        }
    }

    @Test
    void errorEventFollowsContractWithoutRawStackOrPii() {
        FeralinClient client = client();
        Throwable error = failingCall("Sipariş 1234567 başarısız: ali@example.com https://shop.test/o?token=abc 9f8e7d6c5b4a39281706f5e4d3c2b1a0");
        UtpEvent sent = event(client.captureError(error, TrackOptions.builder().userId("u1").build()));
        assertEquals("fr_error", sent.eventName());
        Map<String, Object> props = sent.properties();
        assertEquals("IllegalStateException", props.get("error_type"));
        assertEquals("Sipariş [num] başarısız: [email] [url] [token]", props.get("message"));
        assertTrue(Pattern.matches("[0-9a-f]{32}", (String) props.get("fingerprint")));
        assertEquals("com.feralin.sdk.ContractEventsTest.failingCall", props.get("top_frame"));
        assertTrue((Integer) props.get("frame_count") > 0);
        assertEquals("1.4.2", props.get("app_version"));
        assertEquals(true, props.get("handled"));
        assertEquals(false, props.get("fatal"));
        assertEquals("handled", props.get("origin"));
        Set<String> allowed = new HashSet<>(Arrays.asList(
                "error_type", "message", "fingerprint", "top_frame", "frame_count", "app_version", "handled", "fatal", "origin", "frames"));
        assertTrue(allowed.containsAll(props.keySet()), props.keySet().toString());
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> frames = (List<Map<String, Object>>) props.get("frames");
        assertTrue(!frames.isEmpty() && frames.size() <= 5);
        for (Map<String, Object> frame : frames) {
            assertTrue(Pattern.matches("[A-Za-z0-9._~-]{1,128}", (String) frame.get("file")));
            assertTrue((Integer) frame.get("line") >= 1);
            assertEquals(0, frame.get("column"));
        }
        assertEquals("com.feralin.sdk.ContractEventsTest", frames.get(0).get("file"));
        assertEquals("failingCall", frames.get(0).get("function"));
        client.flush();
        String body = bodies.get(0);
        for (String leak : Arrays.asList("ali@example.com", "shop.test", "token=abc", ".java", "\tat ")) {
            assertFalse(body.contains(leak), leak);
        }
    }

    @Test
    void fingerprintIsStableAndIgnoresMessage() {
        String first = ErrorEvent.properties(failingCall("kullanıcı 1"), ErrorEvent.ORIGIN_HANDLED, false, null).get("fingerprint").toString();
        String second = ErrorEvent.properties(failingCall("kullanıcı 2"), ErrorEvent.ORIGIN_HANDLED, false, null).get("fingerprint").toString();
        assertEquals(first, second);
        String other = ErrorEvent.properties(new IllegalArgumentException("x"), ErrorEvent.ORIGIN_HANDLED, false, null).get("fingerprint").toString();
        assertNotEquals(first, other);
        // Çerçevesiz hata: parmak izi rakamları normalize edilmiş mesajdan.
        Throwable bare = new RuntimeException("kod 42");
        bare.setStackTrace(new StackTraceElement[0]);
        Throwable bare2 = new RuntimeException("kod 43");
        bare2.setStackTrace(new StackTraceElement[0]);
        assertEquals(ErrorEvent.properties(bare, "manual", false, null).get("fingerprint"), ErrorEvent.properties(bare2, "manual", false, null).get("fingerprint"));
        assertFalse(ErrorEvent.properties(bare, "manual", false, null).containsKey("frames"));
    }

    @Test
    void errorLimiterPerFingerprintAndWindow() {
        FeralinClient client = client();
        Throwable error = failingCall("aynı");
        int accepted = 0;
        for (int i = 0; i < 5; i++) {
            accepted += client.captureError(error).isPresent() ? 1 : 0;
        }
        assertEquals(3, accepted, "aynı parmak izi için en çok 3");
        clock.millis += ErrorLimiter.WINDOW_MILLIS;
        assertTrue(client.captureError(error).isPresent(), "yeni pencerede yeniden izin");

        ErrorLimiter limiter = new ErrorLimiter(1.0);
        int allowed = 0;
        for (int i = 0; i < 30; i++) {
            allowed += limiter.allow("fp" + i, 1000, 0.0) ? 1 : 0;
        }
        assertEquals(20, allowed);
        assertTrue(limiter.allow("fp_yeni", 61_000, 0.0));
        assertFalse(new ErrorLimiter(0.5).allow("fp", 0, 0.9), "örnekleme dışı");
    }

    @Test
    void captureErrorNeverThrowsAndRespectsConsent() {
        FeralinClient denied = client(Consent.none());
        assertFalse(denied.captureError(failingCall("x")).isPresent());
        FeralinClient client = client();
        assertFalse(client.captureError(null).isPresent());
        Feralin scoped = client.scoped(Consent.analyticsOnly());
        scoped.identify("u_scoped");
        assertEquals("u_scoped", event(scoped.captureError(new IllegalArgumentException("y"))).userId());
        assertEquals("fr_group", event(scoped.group("acme", null)).eventName());
        client.shutdown(Duration.ZERO);
        assertFalse(client.captureError(failingCall("kapalı")).isPresent());
    }

    @Test
    void scrubMatchesCollector() {
        assertEquals("[email] yazdı", ErrorEvent.scrub("ali.veli@example.com yazdı"));
        assertEquals("bkz [url]", ErrorEvent.scrub("bkz   https://x.test/a?b=c\n"));
        assertEquals("kimlik [id]", ErrorEvent.scrub("kimlik 123e4567-e89b-12d3-a456-426614174000"));
        assertEquals("sürüm 1.4.2 tel [num]", ErrorEvent.scrub("sürüm 1.4.2 tel +90 (555) 123-4567"));
        assertEquals("UnsupportedOperationExceptionHandler", ErrorEvent.scrub("UnsupportedOperationExceptionHandler"));
        assertEquals(200, ErrorEvent.scrub("ğ".repeat(500)).length());
    }
}
