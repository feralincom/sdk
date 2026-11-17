package com.feralin.sdk;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.feralin.sdk.FakeCollector.Scripted;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.regex.Pattern;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class FeralinClientTest {
    private static final String TEST_KEY = "pk_live_0123456789abcdef0123456789abcdef";
    private static final Pattern OCCURRED_AT = Pattern.compile("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z");

    private FakeCollector collector;
    private final List<FeralinClient> clients = new ArrayList<>();

    @BeforeEach
    void start() throws IOException {
        collector = new FakeCollector();
    }

    @AfterEach
    void stop() {
        for (FeralinClient client : clients) {
            client.shutdown(Duration.ofSeconds(1));
        }
        collector.close();
    }

    private FeralinClient.Builder builder() {
        // Arka plan kapalı; testler flush ve shutdown ile kontrol eder.
        return FeralinClient.builder(TEST_KEY, collector.url()).consent(Consent.analyticsOnly()).flushInterval(Duration.ZERO);
    }

    private FeralinClient keep(FeralinClient client) {
        clients.add(client);
        return client;
    }

    private FeralinClient client() {
        return keep(builder().build());
    }

    private static UtpEvent event(java.util.Optional<UtpEvent> tracked) {
        assertTrue(tracked.isPresent(), "olay üretilmeliydi");
        return tracked.get();
    }

    @SuppressWarnings("unchecked")
    private static void assertWireEvent(Map<String, Object> wire) throws IOException {
        for (String key : List.of("event_id", "event_name", "occurred_at", "platform", "schema_version", "consent")) {
            assertTrue(wire.containsKey(key), "zorunlu alan eksik: " + key);
        }
        for (String forbidden : List.of("tenant_id", "project_id", "verified", "source_ip", "ip")) {
            assertFalse(wire.containsKey(forbidden), "istemciden gönderilmemesi gereken alan var: " + forbidden);
        }
        assertTrue(UlidGenerator.isUlid((String) wire.get("event_id")));
        assertEquals("java", wire.get("platform"));
        assertEquals(1L, wire.get("schema_version"));
        assertEquals(Map.of("name", "feralin-java", "version", FeralinClient.SDK_VERSION), wire.get("sdk"));
        assertTrue(OCCURRED_AT.matcher((String) wire.get("occurred_at")).matches());
        assertEquals(true, ((Map<String, Object>) wire.get("consent")).get("analytics"));

        Path schema = findSchema();
        if (schema != null) {
            Map<String, Object> parsed = (Map<String, Object>) Json.parse(new String(Files.readAllBytes(schema), StandardCharsets.UTF_8));
            Map<String, Object> properties = (Map<String, Object>) parsed.get("properties");
            for (String key : wire.keySet()) {
                assertTrue(properties.containsKey(key), "şemada olmayan alan gönderildi: " + key);
            }
            for (Object key : (List<Object>) parsed.get("required")) {
                assertTrue(wire.containsKey(key), "şemanın zorunlu alanı eksik: " + key);
            }
            assertTrue(((List<Object>) ((Map<String, Object>) properties.get("platform")).get("enum")).contains("java"));
        }
    }

    private static Path findSchema() {
        Path directory = Paths.get("").toAbsolutePath();
        while (directory != null) {
            Path candidate = directory.resolve("packages/schemas/utp/v1/event.schema.json");
            if (Files.exists(candidate)) {
                return candidate;
            }
            directory = directory.getParent();
        }
        return null;
    }

    // ------------------------------------------------------------------ yapılandırma

    @Test
    void rejectsSecretAndNonPublicKeysWithoutEchoingThem() {
        ConfigurationException secret = assertThrows(ConfigurationException.class, () -> FeralinClient.builder("sk_live_abcdefgh", collector.url()).build());
        assertTrue(secret.getMessage().contains("gizli anahtar"));
        assertFalse(secret.getMessage().contains("abcdefgh"));
        ConfigurationException other = assertThrows(ConfigurationException.class, () -> FeralinClient.builder("dev_key_change_me_0001", collector.url()).build());
        assertTrue(other.getMessage().contains("pk_"));
        assertFalse(other.getMessage().contains("change_me"));
        assertThrows(ConfigurationException.class, () -> FeralinClient.builder("", collector.url()).build());
        assertThrows(ConfigurationException.class, () -> FeralinClient.builder(null, collector.url()).build());
        assertThrows(ConfigurationException.class, () -> FeralinClient.builder("pk_live_a\r\nb", collector.url()).build());
    }

    @Test
    void rejectsBadCollectUrl() {
        for (String bad : new String[] {"collect.example.test", "ftp://collect.example.test", "", null, "http://", "http://bad host"}) {
            assertThrows(ConfigurationException.class, () -> FeralinClient.builder(TEST_KEY, bad).build(), String.valueOf(bad));
        }
    }

    @Test
    void rejectsNonPositiveTimeout() {
        assertThrows(ConfigurationException.class, () -> builder().timeout(Duration.ZERO).build());
        assertThrows(ConfigurationException.class, () -> builder().timeout(null).build());
    }

    @Test
    void endpointBuiltFromRootAndKeyNotInStatus() {
        FeralinClient client = keep(FeralinClient.builder(TEST_KEY, "https://collect.example.test/").flushInterval(Duration.ZERO).build());
        assertEquals("https://collect.example.test/v1/batch", client.status().get("endpoint"));
        assertFalse(client.status().toString().contains("pk_"));
        assertFalse(client.toString().contains("pk_"));
    }

    @Test
    void versionMatchesBuildFile() {
        assertEquals(System.getProperty("feralin.expectedVersion"), FeralinClient.SDK_VERSION);
    }

    // ------------------------------------------------------------------ track ve flush

    @Test
    void trackFlushAccepted() throws IOException {
        FeralinClient client = client();
        client.identify("user_42");
        Map<String, Object> properties = new LinkedHashMap<>();
        properties.put("order_id", "ord_1");
        properties.put("amount", 12.5);
        properties.put("items", 2);
        UtpEvent event = event(client.track(
                "order_completed",
                properties,
                TrackOptions.builder()
                        .anonymousId("anon_1")
                        .sessionId("ses_1")
                        .context(Context.builder().locale("tr-TR").timezone("Europe/Istanbul").app("1.2.3", null).build())
                        .build()));
        assertEquals("user_42", event.userId());
        assertEquals(1, client.queued());

        FlushResult result = client.flush();
        assertTrue(result.isOk(), String.valueOf(result.error()));
        assertEquals(202, result.status());
        assertEquals(1, result.sent());
        assertEquals(1, result.accepted());
        assertEquals(0, result.rejected());
        assertEquals("01TESTBATCH0000000000000000", result.batchId());
        assertEquals(0, client.queued());
        assertEquals(1, collector.count());

        FakeCollector.Recorded request = collector.request(0);
        assertEquals(TEST_KEY, request.header("X-Feralin-Project-Key"));
        assertEquals(IdempotencyKeys.of(List.of(event.eventId())), request.header("Idempotency-Key"));
        assertEquals("application/json", request.header("Content-Type"));
        assertEquals("feralin-java/" + FeralinClient.SDK_VERSION, request.header("User-Agent"));
        assertTrue(OCCURRED_AT.matcher((String) request.body.get("sent_at")).matches());
        assertEquals(1, request.events().size());
        Map<String, Object> wire = request.events().get(0);
        assertWireEvent(wire);
        assertEquals("user_42", wire.get("user_id"));
        assertEquals("anon_1", wire.get("anonymous_id"));
        assertEquals("ses_1", wire.get("session_id"));
        assertEquals(Map.of("order_id", "ord_1", "amount", 12.5, "items", 2L), wire.get("properties"));
        assertEquals(Map.of("locale", "tr-TR", "timezone", "Europe/Istanbul", "app", Map.of("version", "1.2.3")), wire.get("context"));
        assertEquals(event.eventId(), wire.get("event_id"));
    }

    @Test
    void optionalFieldsOmitted() throws IOException {
        FeralinClient client = client();
        UtpEvent event = event(client.track("signup"));
        for (String key : List.of("user_id", "anonymous_id", "session_id", "properties", "context")) {
            assertFalse(event.toMap().containsKey(key), key);
        }
        client.flush();
        assertWireEvent(collector.request(0).events().get(0));
    }

    @Test
    void perEventUserWinsOverIdentifyAndNullClears() {
        FeralinClient client = client();
        client.identify("user_default");
        assertEquals("user_event", event(client.track("e", null, TrackOptions.builder().userId("user_event").build())).userId());
        assertEquals("user_default", event(client.track("e")).userId());
        client.identify(null);
        assertNull(event(client.track("e")).userId());
    }

    @Test
    void temporaryFailureKeepsQueueAndIdempotencyKey() {
        FeralinClient client = client();
        collector.script(
                new Scripted(503, "{\"type\":\"urn:feralin:collect:problem:outbox\",\"title\":\"Outbox yazılamadı\"}", "Retry-After", "5"),
                new Scripted(429, "{\"title\":\"Çok fazla istek\"}", "Retry-After", "1"));
        UtpEvent event = event(client.track("signup"));

        FlushResult result = client.flush();
        assertInstanceOf(TemporaryException.class, result.error());
        assertEquals(503, result.status());
        assertEquals(1, result.retained());
        assertEquals(1, client.queued());
        assertEquals(5.0, client.status().get("backoff"));

        result = client.flush();
        assertInstanceOf(TemporaryException.class, result.error());
        assertEquals(429, result.status());
        assertEquals(1, client.queued());
        assertEquals(10.0, client.status().get("backoff"));

        result = client.flush();
        assertTrue(result.isOk(), String.valueOf(result.error()));
        assertEquals(202, result.status());
        assertEquals(0, client.queued());
        assertEquals(0.0, client.status().get("backoff"));

        assertEquals(3, collector.count());
        String expected = IdempotencyKeys.of(List.of(event.eventId()));
        for (int i = 0; i < 3; i++) {
            assertEquals(expected, collector.request(i).header("Idempotency-Key"), "istek " + i);
        }
    }

    @Test
    void backoffDoublesAndStopsAtThirtySeconds() {
        FeralinClient client = client();
        client.track("e");
        double[] expected = {1, 2, 4, 8, 16, 30, 30};
        for (double value : expected) {
            collector.script(new Scripted(500, "{}"));
            assertInstanceOf(TemporaryException.class, client.flush().error());
            assertEquals(value, client.status().get("backoff"));
        }
    }

    @Test
    void idempotencyKeyMatchesOtherSdks() {
        assertEquals("8f95d6b736d56c98-2", IdempotencyKeys.of(List.of("01JC0000000000000000000002", "01JC0000000000000000000001")));
    }

    @Test
    void frClickRequiresAdvertisingConsent() {
        FeralinClient client = client();
        Map<String, Object> properties = Map.of("fr_click", "clk", "order_id", "o1");
        assertEquals(Map.of("order_id", "o1"), event(client.track("order_completed", properties)).properties());
        assertFalse(event(client.track("order_completed", Map.of("fr_click", "clk"))).toMap().containsKey("properties"), "boş kalan properties gönderilmez");
        client.setConsent(Consent.analyticsAndAdvertising());
        assertEquals("clk", event(client.track("order_completed", Map.of("fr_click", "clk"))).properties().get("fr_click"));
    }

    @Test
    void pinnedBatchKeepsContentAcrossRetries() {
        FeralinClient client = client();
        collector.script(new Scripted(503, "{}"));
        UtpEvent first = event(client.track("first_event"));
        assertInstanceOf(TemporaryException.class, client.flush().error());
        UtpEvent second = event(client.track("second_event"));
        assertTrue(client.flush().isOk());
        assertEquals(3, collector.count());
        String key = IdempotencyKeys.of(List.of(first.eventId()));
        assertEquals(key, collector.request(0).header("Idempotency-Key"));
        assertEquals(key, collector.request(1).header("Idempotency-Key"));
        assertEquals(IdempotencyKeys.of(List.of(second.eventId())), collector.request(2).header("Idempotency-Key"));
    }

    @Test
    void networkErrorKeepsQueue() {
        FeralinClient client = client();
        collector.close();
        client.track("ping");
        FlushResult result = client.flush();
        assertInstanceOf(TemporaryException.class, result.error());
        assertEquals(0, result.status());
        assertEquals(1, client.queued());
        assertEquals(1.0, client.status().get("backoff"));
        client.setConsent(Consent.none());
    }

    @Test
    void customTransportFailureDoesNotEscapeFlush() {
        FeralinClient client = keep(builder().transport((url, body, headers, timeout) -> {
            throw new IllegalStateException("gizli " + headers.get("X-Feralin-Project-Key"));
        }).build());
        client.track("ping");
        FlushResult result = client.flush();
        assertInstanceOf(TemporaryException.class, result.error());
        assertEquals(1, client.queued());
        assertFalse(result.error().getMessage().contains(TEST_KEY), "anahtar hata iletisine sızmamalı");
        client.setConsent(Consent.none());
    }

    @Test
    void permanentRejectionDropsEvents() {
        FeralinClient client = client();
        collector.script(new Scripted(400, "{\"type\":\"urn:feralin:collect:problem:schema\",\"title\":\"Şema ihlali\",\"detail\":\"events[0]\"}"));
        client.track("client_valid_but_server_rejects");
        FlushResult result = client.flush();
        assertInstanceOf(RejectedException.class, result.error());
        assertTrue(result.error().getMessage().contains("Şema ihlali"));
        assertEquals("Şema ihlali events[0]", result.error().detail());
        assertEquals(400, result.status());
        assertEquals(1, result.rejected());
        assertEquals(0, client.queued());
        assertTrue(client.flush().isOk());
        assertEquals(1, collector.count(), "atılan olay yeniden gönderilmemeli");
    }

    @Test
    void unauthorizedDropsEventsAndDoesNotThrow() {
        for (int status : new int[] {401, 403}) {
            FeralinClient client = client();
            collector.script(new Scripted(status, "not json"));
            client.track("e");
            FlushResult result = client.flush();
            assertInstanceOf(RejectedException.class, result.error());
            assertEquals(status, result.status());
            assertEquals(0, client.queued());
            assertEquals("problem+json yok", result.error().detail());
        }
    }

    @Test
    void consentGate() {
        FeralinClient client = keep(builder().consent(Consent.none()).build());
        assertTrue(client.track("page_view").isEmpty());
        assertEquals(0, client.queued());

        client.setConsent(Consent.analyticsOnly());
        UtpEvent event = event(client.track("page_view"));
        assertEquals(Map.of("analytics", true, "advertising", false, "personalization", false, "session_replay", false), event.toMap().get("consent"));
        assertEquals(1, client.queued());

        client.setConsent(Consent.none());
        assertEquals(0, client.queued(), "izin geri çekilince kuyruk temizlenmeli");
        assertTrue(client.flush().isOk());
        assertEquals(0, collector.count(), "izin yokken sunucuya istek gitmemeli");
    }

    @Test
    void consentDefaultsToNone() {
        FeralinClient client = keep(FeralinClient.builder(TEST_KEY, collector.url()).flushInterval(Duration.ZERO).build());
        assertTrue(client.track("page_view").isEmpty());
        assertThrows(InvalidEventException.class, () -> client.setConsent(null));
    }

    @Test
    void withdrawalWhileRequestInFlightDoesNotPin() throws Exception {
        CountDownLatch inFlight = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        FeralinClient client = keep(builder().transport((url, body, headers, timeout) -> {
            inFlight.countDown();
            try {
                release.await();
            } catch (InterruptedException exc) {
                Thread.currentThread().interrupt();
            }
            throw new TemporaryException("yanıt yok", 0);
        }).build());
        client.track("e");
        Thread sender = new Thread(client::flush);
        sender.start();
        inFlight.await();
        client.setConsent(Consent.none());
        release.countDown();
        sender.join();
        client.setConsent(Consent.analyticsOnly());
        assertEquals(0, client.queued());
        assertTrue(client.flush().isOk(), "izni geri çekilmiş olay yeniden denenmemeli");
    }

    @Test
    void validation() {
        FeralinClient client = client();
        List<String> badNames = new ArrayList<>(List.of("", "orderCompleted", "1_event", "a".repeat(101), "has-dash", "ends\n"));
        badNames.add(null);
        for (String name : badNames) {
            assertThrows(InvalidEventException.class, () -> client.track(name), String.valueOf(name));
        }
        assertThrows(InvalidEventException.class, () -> client.track("ok", Map.of("1bad", 1)));
        assertThrows(InvalidEventException.class, () -> client.track("ok", Map.of("bad-key", 1)));
        assertThrows(InvalidEventException.class, () -> client.track("ok", Map.of("a" + "b".repeat(64), 1)));
        Map<String, Object> tooMany = new HashMap<>();
        for (int i = 0; i < 101; i++) {
            tooMany.put("k" + i, i);
        }
        assertThrows(InvalidEventException.class, () -> client.track("ok", tooMany));
        assertThrows(InvalidEventException.class, () -> client.track("ok", null, TrackOptions.builder().userId("u".repeat(129)).build()));
        assertThrows(InvalidEventException.class, () -> client.track("ok", Map.of("obj", new Object())));
        assertThrows(InvalidEventException.class, () -> client.track("ok", Map.of("nan", Double.NaN)));
        assertThrows(InvalidEventException.class, () -> client.identify("u".repeat(129)));
        // Geçersiz ad veya anahtar yanlışlıkla kişisel veri taşıyabilir; istisna iletisi log'a gider, ham değer yazılmaz.
        assertFalse(assertThrows(InvalidEventException.class, () -> client.track("eposta@ornek.test")).getMessage().contains("eposta@ornek.test"));
        assertFalse(assertThrows(InvalidEventException.class, () -> client.track("ok", Map.of("eposta@ornek.test", 1))).getMessage().contains("eposta@ornek.test"));
        assertEquals(0, client.queued(), "geçersiz olaylar kuyruğa girmemeli");

        tooMany.remove("k100");
        assertTrue(client.track("ok", tooMany).isPresent());
        assertTrue(client.track("fr_system_event_9", Map.of("Camel_Key9", "x")).isPresent());
        assertEquals(2, client.queued());
    }

    @Test
    void propertiesAreCopiedAtTrackTime() {
        FeralinClient client = client();
        Map<String, Object> properties = new HashMap<>();
        properties.put("a", 1);
        client.track("e", properties);
        properties.put("a", 2);
        client.flush();
        assertEquals(Map.of("a", 1L), collector.request(0).events().get(0).get("properties"));
    }

    @Test
    void queueLimitDropsOldest() {
        FeralinClient client = keep(builder().queueLimit(3).batchSize(10).build());
        List<String> ids = new ArrayList<>();
        for (int i = 0; i < 5; i++) {
            ids.add(event(client.track("e")).eventId());
        }
        assertEquals(3, client.queued());
        assertEquals(2L, client.status().get("dropped"));
        assertTrue(client.flush().isOk());
        List<Object> got = new ArrayList<>();
        collector.request(0).events().forEach(wire -> got.add(wire.get("event_id")));
        assertEquals(ids.subList(2, 5), got);
    }

    @Test
    void batchSplitting() {
        FeralinClient client = keep(builder().batchSize(2).queueLimit(100).build());
        for (int i = 0; i < 5; i++) {
            client.track("e");
        }
        FlushResult result = client.flush();
        assertTrue(result.isOk(), String.valueOf(result.error()));
        assertEquals(5, result.sent());
        assertEquals(5, result.accepted());
        assertEquals(0, client.queued());
        assertEquals(3, collector.count());
        FakeCollector.Recorded first = collector.request(0);
        assertEquals(2, first.events().size());
        List<String> ids = new ArrayList<>();
        first.events().forEach(wire -> ids.add((String) wire.get("event_id")));
        assertEquals(IdempotencyKeys.of(ids), first.header("Idempotency-Key"));
        assertEquals(1, collector.request(2).events().size());
    }

    @Test
    void batchSizeClampedToProtocolLimit() {
        FeralinClient client = keep(builder().batchSize(10_000).queueLimit(600).build());
        for (int i = 0; i < 501; i++) {
            client.track("e");
        }
        assertTrue(client.flush().isOk());
        assertEquals(500, collector.request(0).events().size());
        assertEquals(1, collector.request(1).events().size());
    }

    @Test
    void backgroundFlush() throws InterruptedException {
        FeralinClient client = keep(builder().flushInterval(Duration.ofMillis(20)).build());
        client.track("bg");
        assertTrue(collector.await(3), "arka plan gönderici 3 sn içinde istek yapmadı");
        long deadline = System.nanoTime() + Duration.ofSeconds(2).toNanos();
        while (client.queued() > 0 && System.nanoTime() < deadline) {
            Thread.sleep(5);
        }
        assertEquals(0, client.queued());
    }

    @Test
    void fullBatchWakesBackgroundFlusher() throws InterruptedException {
        FeralinClient client = keep(builder().flushInterval(Duration.ofHours(1)).batchSize(2).build());
        client.track("e");
        client.track("e");
        assertTrue(collector.await(3), "dolu batch göndericiyi uyandırmalıydı");
    }

    @Test
    void backgroundFlushRespectsBackoff() throws InterruptedException {
        collector.script(new Scripted(503, "{\"title\":\"down\"}"));
        FeralinClient client = keep(builder().flushInterval(Duration.ofMillis(10)).build());
        client.track("bg");
        assertTrue(collector.await(3));
        Thread.sleep(150);
        assertEquals(1, collector.count(), "geri çekilme sırasında yeniden deneme olmamalı");
        assertEquals(1, client.queued());
    }

    @Test
    void closeFlushesAndBlocksTrack() {
        FeralinClient client = keep(builder().flushInterval(Duration.ofHours(1)).build());
        for (int i = 0; i < 3; i++) {
            client.track("e");
        }
        FlushResult result = client.shutdown(FeralinClient.CLOSE_TIMEOUT);
        assertTrue(result.isOk(), String.valueOf(result.error()));
        assertEquals(1, collector.count());
        assertEquals(3, collector.request(0).events().size());
        assertEquals(0, client.queued());
        assertEquals(true, client.status().get("closed"));
        assertThrows(ClientClosedException.class, () -> client.track("late"));
        assertThrows(ClientClosedException.class, client::flush);
        assertTrue(client.shutdown(FeralinClient.CLOSE_TIMEOUT).isOk(), "ikinci kapanış hatasız olmalı");
    }

    @Test
    void closeReportsUndelivered() {
        collector.script(new Scripted(503, "{\"title\":\"down\"}"));
        FeralinClient client = client();
        client.track("e");
        FlushResult result = client.shutdown(Duration.ofSeconds(1));
        assertInstanceOf(TemporaryException.class, result.error());
        assertEquals(1, result.retained());
    }

    @Test
    void tryWithResourcesFlushes() {
        try (FeralinClient client = builder().build()) {
            client.track("ctx");
        }
        assertEquals(1, collector.count());
    }

    @Test
    void concurrentTrack() throws InterruptedException {
        FeralinClient client = keep(builder().queueLimit(5000).batchSize(FeralinClient.MAX_BATCH_SIZE).build());
        List<Thread> threads = new ArrayList<>();
        for (int t = 0; t < 8; t++) {
            Thread thread = new Thread(() -> {
                for (int i = 0; i < 100; i++) {
                    client.track("c");
                }
            });
            threads.add(thread);
            thread.start();
        }
        for (Thread thread : threads) {
            thread.join();
        }
        assertEquals(800, client.queued());
        FlushResult result = client.flush();
        assertTrue(result.isOk(), String.valueOf(result.error()));
        assertEquals(800, result.accepted());
        assertEquals(0, client.queued());
        assertEquals(2, collector.count());
        Set<Object> seen = new HashSet<>();
        for (FakeCollector.Recorded request : collector.requests()) {
            for (Map<String, Object> wire : request.events()) {
                assertTrue(seen.add(wire.get("event_id")));
            }
        }
    }

    @Test
    void occurredAtUsesInjectedClockAndUtc() {
        Instant fixed = OffsetDateTime.of(2026, 11, 3, 10, 0, 0, 123_456_000, ZoneOffset.ofHours(3)).toInstant();
        FeralinClient client = keep(builder().clock(Clock.fixed(fixed, ZoneOffset.UTC)).build());
        assertEquals("2026-11-03T07:00:00.123Z", event(client.track("clock")).occurredAt());
        Instant explicit = Instant.parse("2026-01-02T03:04:05Z");
        assertEquals("2026-01-02T03:04:05.000Z", event(client.track("clock", null, TrackOptions.builder().occurredAt(explicit).build())).occurredAt());
    }

    @Test
    void wireFormatIndependentOfDefaultLocale() {
        Locale original = Locale.getDefault();
        try {
            for (Locale locale : List.of(Locale.forLanguageTag("tr-TR"), Locale.forLanguageTag("ar-SA-u-nu-arab"))) {
                Locale.setDefault(locale);
                FeralinClient client = keep(builder().clock(Clock.fixed(Instant.parse("2026-11-03T07:00:00Z"), ZoneOffset.UTC)).build());
                assertEquals("2026-11-03T07:00:00.000Z", event(client.track("clock")).occurredAt());
                assertEquals("8f95d6b736d56c98-2", IdempotencyKeys.of(List.of("01JC0000000000000000000002", "01JC0000000000000000000001")));
                collector.script(new Scripted(503, "{}", "RETRY-AFTER", "7"));
                client.flush();
                assertEquals(7.0, client.status().get("backoff"), "başlık adı Türkçe yerelde de eşleşmeli");
                client.setConsent(Consent.none());
            }
        } finally {
            Locale.setDefault(original);
        }
    }

    // ------------------------------------------------------------------ taşıma

    @Test
    void oversizedResponseBodyIsCappedAndTolerated() {
        FeralinClient client = client();
        collector.script(new Scripted(202, "x".repeat(HttpClientTransport.MAX_RESPONSE_BODY * 3)));
        client.track("e");
        FlushResult result = client.flush();
        assertTrue(result.isOk(), String.valueOf(result.error()));
        assertEquals(1, result.accepted(), "çözülemeyen ack gönderilen sayıyı kabul sayar");
        assertNull(result.batchId());
    }

    @Test
    void stalledResponseBodyHitsTimeout() throws IOException {
        CountDownLatch release = new CountDownLatch(1);
        com.sun.net.httpserver.HttpServer server = com.sun.net.httpserver.HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
        server.setExecutor(java.util.concurrent.Executors.newCachedThreadPool(runnable -> {
            Thread thread = new Thread(runnable);
            thread.setDaemon(true);
            return thread;
        }));
        server.createContext("/v1/batch", exchange -> {
            exchange.getRequestBody().readAllBytes();
            exchange.sendResponseHeaders(202, 1000);
            exchange.getResponseBody().write('{');
            exchange.getResponseBody().flush();
            try {
                release.await();
            } catch (InterruptedException exc) {
                Thread.currentThread().interrupt();
            }
            exchange.close();
        });
        server.start();
        try {
            FeralinClient client = keep(FeralinClient.builder(TEST_KEY, "http://" + server.getAddress().getAddress().getHostAddress() + ":" + server.getAddress().getPort())
                    .consent(Consent.analyticsOnly())
                    .flushInterval(Duration.ZERO)
                    .timeout(Duration.ofMillis(300))
                    .build());
            client.track("e");
            FlushResult result = assertTimeoutPreemptively(Duration.ofSeconds(5), client::flush, "takılan gövde göndericiyi kilitlememeli");
            assertInstanceOf(TemporaryException.class, result.error());
            assertEquals(1, client.queued());
            client.setConsent(Consent.none());
        } finally {
            release.countDown();
            server.stop(0);
        }
    }

    // ------------------------------------------------------------------ istek başına görünüm

    @Test
    void scopedViewOwnsConsentAndIdentity() {
        FeralinClient root = keep(builder().consent(Consent.none()).build());
        root.identify("root_user");
        Feralin first = root.scoped(Consent.analyticsAndAdvertising());
        Feralin second = root.scoped(null);

        first.identify("user_a");
        UtpEvent tracked = event(first.track("order_completed", Map.of("fr_click", "clk")));
        assertEquals("user_a", tracked.userId());
        assertEquals("clk", tracked.properties().get("fr_click"));

        assertTrue(second.track("order_completed").isEmpty(), "izinsiz görünüm olay üretmez");
        second.setConsent(Consent.analyticsOnly());
        UtpEvent other = event(second.track("order_completed", Map.of("fr_click", "clk")));
        assertNull(other.userId(), "başka görünümün ve kapsayıcının kimliği devralınmaz");
        assertTrue(other.properties().isEmpty());

        assertTrue(root.track("root_event").isEmpty(), "görünümün izni kapsayıcıya sızmaz");
        assertEquals(2, root.queued());
        assertEquals(2, first.queued());
        assertEquals("user_a", first.status().get("user_id"));
        assertEquals("root_user", root.status().get("user_id"));
    }

    @Test
    void scopedWithdrawalDropsOnlyOwnEvents() {
        FeralinClient root = keep(builder().consent(Consent.none()).build());
        Feralin kept = root.scoped(Consent.analyticsOnly());
        Feralin withdrawn = root.scoped(Consent.analyticsOnly());
        UtpEvent keptEvent = event(kept.track("kept"));
        withdrawn.track("withdrawn");
        withdrawn.setConsent(Consent.none());
        assertEquals(1, root.queued());
        assertTrue(withdrawn.track("late").isEmpty());
        assertTrue(kept.flush().isOk());
        assertEquals(1, collector.count());
        assertEquals(keptEvent.eventId(), collector.request(0).events().get(0).get("event_id"));
    }

    @Test
    void scopedBatchStaysPinnedWhenRootHasNoConsent() {
        FeralinClient root = client();
        root.setConsent(Consent.none());
        Feralin view = root.scoped(Consent.analyticsOnly());
        collector.script(new Scripted(503, "{}"));
        UtpEvent first = event(view.track("first"));
        assertInstanceOf(TemporaryException.class, view.flush().error());
        UtpEvent second = event(view.track("second"));
        assertTrue(view.flush().isOk());
        String key = IdempotencyKeys.of(List.of(first.eventId()));
        assertEquals(key, collector.request(0).header("Idempotency-Key"));
        assertEquals(key, collector.request(1).header("Idempotency-Key"));
        assertEquals(IdempotencyKeys.of(List.of(second.eventId())), collector.request(2).header("Idempotency-Key"));
    }

    @Test
    void scopedWithdrawalRemovesEventFromPinnedBatch() {
        FeralinClient root = keep(builder().consent(Consent.none()).build());
        Feralin kept = root.scoped(Consent.analyticsOnly());
        Feralin withdrawn = root.scoped(Consent.analyticsOnly());
        UtpEvent keptEvent = event(kept.track("kept"));
        UtpEvent withdrawnEvent = event(withdrawn.track("withdrawn"));
        collector.script(new Scripted(503, "{}"));
        assertInstanceOf(TemporaryException.class, kept.flush().error());

        withdrawn.setConsent(Consent.none());
        assertTrue(kept.flush().isOk());

        assertEquals(2, collector.count());
        List<Map<String, Object>> retried = collector.request(1).events();
        assertEquals(1, retried.size(), "izni geri çekilen olay yeniden gönderilmemeli: " + withdrawnEvent.eventId());
        assertEquals(keptEvent.eventId(), retried.get(0).get("event_id"));
    }

    @Test
    void rootWithdrawalAlsoPurgesScopedEvents() {
        FeralinClient root = client();
        root.scoped(Consent.analyticsOnly()).track("view_event");
        root.setConsent(Consent.none());
        assertEquals(0, root.queued());
    }

    @Test
    void scopedViewFailsAfterClose() {
        FeralinClient root = client();
        Feralin view = root.scoped(Consent.analyticsOnly());
        root.shutdown(Duration.ofSeconds(1));
        assertThrows(ClientClosedException.class, () -> view.track("late"));
        assertThrows(ClientClosedException.class, view::flush);
    }

    @Test
    void longLivedScopedViewDoesNotGrowWithoutBound() {
        FeralinClient root = keep(builder().consent(Consent.none()).queueLimit(5).batchSize(5).build());
        Feralin view = root.scoped(Consent.analyticsOnly());
        for (int i = 0; i < 50; i++) {
            view.track("e");
        }
        assertEquals(5, root.queued());
        view.setConsent(Consent.none());
        assertEquals(0, root.queued(), "kuyruktaki bütün olaylar son queueLimit kimlikle kapsanır");
    }
}
