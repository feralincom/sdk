package feralin.e2e;

import com.feralin.sdk.Consent;
import com.feralin.sdk.FeralinClient;
import com.feralin.sdk.FlushResult;
import com.feralin.sdk.HttpClientTransport;
import com.feralin.sdk.IdempotencyKeys;
import com.feralin.sdk.RejectedException;
import com.feralin.sdk.TemporaryException;
import com.feralin.sdk.Transport;
import com.feralin.sdk.TrackOptions;
import com.feralin.sdk.UtpEvent;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Temiz kurulumdan çalışan tüketici: paket yerel Maven deposundan boş projeye kurulur ve gerçek services/collect ile
 * konuşur. Denetim satırları sdks/android/scripts/outbox_check.go ile PostgreSQL üzerinde doğrulanır.
 */
public final class CleanInstall {
    private static final String COLLECT_URL = require("FERALIN_E2E_COLLECT_URL");
    private static final String PROJECT_KEY = require("FERALIN_E2E_PROJECT_KEY");
    private static final String CHECKS = require("FERALIN_E2E_CHECKS");

    private CleanInstall() {
    }

    public static void main(String[] args) throws Exception {
        System.out.println("  kurulu paket: " + FeralinClient.class.getProtectionDomain().getCodeSource().getLocation());

        accepted();
        advertisingConsentMissing();
        noConsent();
        rawRequestWithoutConsent();
        wrongKey();
        lostResponse();

        System.out.println("java tüketici: tüm senaryolar geçti");
    }

    // 202 + outbox satırı + fr_click reklam izniyle
    private static void accepted() throws IOException {
        try (FeralinClient client = make(PROJECT_KEY, Consent.analyticsAndAdvertising(), null)) {
            UtpEvent event = client.track(
                    "order_completed",
                    Map.of("order_id", "ord_java_1", "fr_click", "clk_java_1", "amount", 12.5),
                    TrackOptions.builder().userId("user_java_1").build()).orElseThrow();
            FlushResult result = client.flush();
            must(result.status() == 202 && result.accepted() == 1, "202 bekleniyordu: " + result);
            expect("frclick " + result.batchId());
            expect("once " + event.eventId());
            expect("platform java:" + event.eventId());
            report("202-outbox-frclick", "status=" + result.status() + " batch_id=" + result.batchId());
        }
    }

    // Reklam izni yok: fr_click çıkarılır
    private static void advertisingConsentMissing() throws IOException {
        try (FeralinClient client = make(PROJECT_KEY, Consent.analyticsOnly(), null)) {
            UtpEvent event = client.track("order_completed", Map.of("order_id", "ord_java_2", "fr_click", "clk_java_2")).orElseThrow();
            must(!event.properties().containsKey("fr_click"), "fr_click çıkarılmalıydı");
            FlushResult result = client.flush();
            must(result.status() == 202, "202 bekleniyordu: " + result);
            expect("nofrclick " + result.batchId());
            report("frclick-izinsiz-cikarildi", "status=" + result.status());
        }
    }

    // İzinsiz: SDK olay üretmez
    private static void noConsent() {
        try (FeralinClient client = make(PROJECT_KEY, null, null)) {
            must(client.track("order_completed").isEmpty() && client.flush().sent() == 0, "izinsiz olay üretilmemeliydi");
            report("izinsiz-sdk-uretmez", "sent=0");
        }
    }

    // İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
    private static void rawRequestWithoutConsent() throws Exception {
        String eventId = String.format(Locale.ROOT, "01JCJV%020d", System.currentTimeMillis() * 1_000_000L + System.nanoTime() % 1_000_000L).substring(0, 26);
        String body = "{\"events\":[{\"event_id\":\"" + eventId + "\",\"event_name\":\"denied_event\",\"occurred_at\":\"" + Instant.now()
                + "\",\"platform\":\"java\",\"schema_version\":1,\"consent\":{\"analytics\":false}}]}";
        HttpRequest request = HttpRequest.newBuilder(URI.create(COLLECT_URL + "/v1/batch"))
                .timeout(Duration.ofSeconds(10))
                .header("Content-Type", "application/json")
                .header("X-Feralin-Project-Key", PROJECT_KEY)
                .header("Idempotency-Key", IdempotencyKeys.of(List.of(eventId)))
                .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8))
                .build();
        HttpResponse<String> response = HttpClient.newHttpClient().send(request, HttpResponse.BodyHandlers.ofString());
        String denied = response.body();
        must(response.statusCode() == 202 && denied.contains("\"accepted\":0") && denied.contains("\"consent_denied\":1"), "toplayıcı izinsiz olayı reddetmeliydi: " + denied);
        expect("absent " + eventId);
        report("izinsiz-toplayici-red", denied.trim());
    }

    // Yanlış anahtar: 401, olay atılır, uygulama düşmez
    private static void wrongKey() throws IOException {
        try (FeralinClient client = make("pk_test_wrong_key_000", Consent.analyticsOnly(), null)) {
            UtpEvent event = client.track("order_completed", Map.of("order_id", "ord_java_wrong")).orElseThrow();
            FlushResult result = client.flush();
            must(result.error() instanceof RejectedException && result.status() == 401 && result.rejected() == 1 && client.queued() == 0, "401 bekleniyordu: " + result);
            expect("absent " + event.eventId());
            report("yanlis-anahtar-401", "status=" + result.status());
        }
    }

    // Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
    private static void lostResponse() throws IOException {
        List<String> keys = new ArrayList<>();
        Transport real = new HttpClientTransport();
        Transport lossy = (url, body, headers, timeout) -> {
            keys.add(headers.get("Idempotency-Key"));
            Transport.Response response = real.send(url, body, headers, timeout);
            if (keys.size() == 1) {
                throw new TemporaryException("yanıt yolda kayboldu", 0);
            }
            return response;
        };
        try (FeralinClient client = make(PROJECT_KEY, Consent.analyticsOnly(), lossy)) {
            UtpEvent event = client.track("order_completed", Map.of("order_id", "ord_java_retry")).orElseThrow();
            FlushResult lost = client.flush();
            must(lost.error() instanceof TemporaryException && client.queued() == 1, "yanıt kaybı kuyrukta tutulmalıydı: " + lost);
            UtpEvent following = client.track("order_shipped", Map.of("order_id", "ord_java_retry")).orElseThrow();
            FlushResult result = client.flush();
            must(result.isOk() && result.status() == 202 && client.queued() == 0, "tekrar 202 vermeliydi: " + result);
            must(keys.size() == 3 && keys.get(0).equals(keys.get(1)), "aynı anahtar bekleniyordu: " + keys);
            expect("once " + event.eventId());
            expect("once " + following.eventId());
            report("idempotency-tekrar", "key=" + keys.get(0));
        }
    }

    private static FeralinClient make(String key, Consent consent, Transport transport) {
        return FeralinClient.builder(key, COLLECT_URL).consent(consent).flushInterval(Duration.ZERO).transport(transport).build();
    }

    private static String require(String name) {
        String value = System.getenv(name);
        if (value == null || value.isEmpty()) {
            throw new IllegalStateException(name + " zorunlu");
        }
        return value;
    }

    private static void must(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError("KALDI: " + message);
        }
    }

    private static void expect(String line) throws IOException {
        Files.write(Paths.get(CHECKS), (line + "\n").getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE, StandardOpenOption.APPEND);
    }

    private static void report(String name, String detail) {
        System.out.println("  OK " + name + ": " + detail);
    }
}
