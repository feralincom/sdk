package feralin.e2e;

import com.feralin.sdk.Consent;
import com.feralin.sdk.Feralin;
import com.feralin.sdk.FeralinClient;
import com.feralin.sdk.FlushResult;
import com.feralin.sdk.UtpEvent;
import com.feralin.spring.boot.FeralinConsentResolver;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import org.springframework.aop.scope.ScopedObject;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Starter'ın temiz kurulum tüketicisi: gerçek gömülü Tomcat, gerçek HTTP istekleri, istek başına Feralin bean ve gerçek
 * services/collect. Denetim satırları sdks/android/scripts/outbox_check.go ile PostgreSQL üzerinde doğrulanır.
 */
@SpringBootApplication
public class SpringCleanInstall {
    private static final HttpClient HTTP = HttpClient.newHttpClient();
    private static final String CHECKS = System.getenv("FERALIN_E2E_CHECKS");

    public static void main(String[] args) {
        ConfigurableApplicationContext context = SpringApplication.run(SpringCleanInstall.class, args);
        try {
            scenarios(context);
        } catch (Exception | AssertionError exc) {
            // Tomcat iş parçacıkları JVM'i açık tutar; başarısız senaryo testi askıda bırakmasın.
            exc.printStackTrace();
            System.exit(1);
        }
    }

    private static void scenarios(ConfigurableApplicationContext context) throws Exception {
        String base = "http://127.0.0.1:" + context.getEnvironment().getProperty("local.server.port");
        System.out.println("  Spring Boot " + org.springframework.boot.SpringBootVersion.getVersion() + ", kurulu paket: "
                + FeralinClient.class.getProtectionDomain().getCodeSource().getLocation());

        must(context.getBean(Feralin.class) instanceof ScopedObject, "Feralin istek kapsamlı vekil olmalıydı");
        FeralinClient client = context.getBean(FeralinClient.class);

        // Reklam izinli istek: fr_click gider, outbox'a yazılır.
        Map<String, String> first = get(base + "/order?flush=true&id=ord_sb_1", "analytics,advertising");
        must("202".equals(first.get("status")), "202 bekleniyordu: " + first);
        expect("frclick " + first.get("batch"));
        expect("once " + first.get("event"));
        expect("platform java:" + first.get("event"));
        report("istek-reklam-izni-frclick", first);

        // Aynı bean, sonraki istek: yalnız analitik izni, önceki isteğin izni ve kimliği sızmaz.
        Map<String, String> second = get(base + "/order?flush=true&id=ord_sb_2", "analytics");
        must("202".equals(second.get("status")), "202 bekleniyordu: " + second);
        must("false".equals(second.get("had_user")), "önceki isteğin kimliği sızmamalıydı: " + second);
        expect("nofrclick " + second.get("batch"));
        report("istek-izni-sizmaz", second);

        // İzinsiz istek: SDK olay üretmez.
        Map<String, String> third = get(base + "/order?flush=true&id=ord_sb_3", "");
        must("none".equals(third.get("event")) && "0".equals(third.get("sent")), "izinsiz olay üretilmemeliydi: " + third);
        report("istek-izinsiz-uretmez", third);

        // Bir istekte izin geri çekilince yalnız o isteğin olayı atılır, başka kullanıcının olayı kalır.
        Map<String, String> kept = get(base + "/order?id=ord_sb_kept", "analytics");
        Map<String, String> withdrawn = get(base + "/withdraw?id=ord_sb_withdrawn", "analytics");
        must(client.queued() == 1, "yalnız geri çekilmeyen olay kuyrukta kalmalıydı: " + client.queued());
        FlushResult flushed = client.flush();
        must(flushed.status() == 202 && flushed.accepted() == 1, "202 bekleniyordu: " + flushed);
        expect("once " + kept.get("event"));
        expect("absent " + withdrawn.get("event"));
        report("istek-izin-geri-cekildi", Map.of("kept", kept.get("event"), "withdrawn", withdrawn.get("event")));

        // Uygulama kapanırken kuyruk gönderilir.
        Map<String, String> last = get(base + "/order?id=ord_sb_shutdown", "analytics");
        must(client.queued() == 1, "olay kuyrukta beklemeliydi");
        int exit = SpringApplication.exit(context);
        must(exit == 0, "uygulama temiz kapanmalıydı");
        must(client.queued() == 0, "kapanışta kuyruk boşalmalıydı");
        expect("once " + last.get("event"));
        report("kapanista-gonderim", last);

        System.out.println("spring tüketici: tüm senaryolar geçti");
    }

    @Bean
    FeralinConsentResolver consentResolver() {
        return request -> {
            String header = request.getHeader("X-Test-Consent");
            if (header == null || header.isEmpty()) {
                return Consent.none();
            }
            return header.contains("advertising") ? Consent.analyticsAndAdvertising() : Consent.analyticsOnly();
        };
    }

    @RestController
    static class OrderController {
        private final Feralin feralin;

        OrderController(Feralin feralin) {
            this.feralin = feralin;
        }

        @GetMapping("/order")
        Map<String, String> order(@RequestParam("id") String id, @RequestParam(name = "flush", defaultValue = "false") boolean flush) {
            Map<String, String> out = new HashMap<>();
            // Vekil tekildir; önceki isteğin identify değeri burada görünürse kapsam çalışmıyor demektir.
            out.put("had_user", String.valueOf(feralin.status().get("user_id") != null));
            feralin.identify("user_" + id);
            Optional<UtpEvent> event = feralin.track("order_completed", Map.of("order_id", id, "fr_click", "clk_" + id));
            out.put("event", event.map(UtpEvent::eventId).orElse("none"));
            if (flush) {
                FlushResult result = feralin.flush();
                out.put("status", String.valueOf(result.status()));
                out.put("sent", String.valueOf(result.sent()));
                out.put("batch", String.valueOf(result.batchId()));
            }
            return out;
        }

        @GetMapping("/withdraw")
        Map<String, String> withdraw(@RequestParam("id") String id) {
            String event = feralin.track("order_completed", Map.of("order_id", id)).orElseThrow().eventId();
            feralin.setConsent(Consent.none());
            return Map.of("event", event);
        }
    }

    private static Map<String, String> get(String url, String consent) throws IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder(URI.create(url)).header("X-Test-Consent", consent).GET().build();
        HttpResponse<String> response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());
        must(response.statusCode() == 200, "uygulama isteği başarısız: " + response.statusCode() + " " + response.body());
        return parseFlatJson(response.body());
    }

    // Yanıtlar yalnız düz metin alanlı nesnedir; örneğe JSON kütüphanesi kullanımı dayatılmaz.
    private static Map<String, String> parseFlatJson(String body) {
        Map<String, String> out = new HashMap<>();
        java.util.regex.Matcher matcher = java.util.regex.Pattern.compile("\"([^\"]+)\":\"([^\"]*)\"").matcher(body);
        while (matcher.find()) {
            out.put(matcher.group(1), matcher.group(2));
        }
        return out;
    }

    private static void must(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError("KALDI: " + message);
        }
    }

    private static void expect(String line) throws IOException {
        Files.write(Paths.get(CHECKS), (line + "\n").getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE, StandardOpenOption.APPEND);
    }

    private static void report(String name, Map<String, String> detail) {
        System.out.println("  OK " + name + ": " + detail);
    }
}
