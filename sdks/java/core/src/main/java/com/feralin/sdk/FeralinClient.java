package com.feralin.sdk;

import java.io.ByteArrayOutputStream;
import java.lang.System.Logger;
import java.lang.System.Logger.Level;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.Semaphore;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import java.util.regex.Pattern;

/**
 * UTP v1 toplayıcısına ({@code POST /v1/batch}) olay gönderen, iş parçacığı güvenli istemci.
 *
 * <p>İlkeler: analytics izni yoksa olay üretilmez. At-least-once: 202 onaydır; 4xx (429 hariç) olayları atar; 5xx, 429
 * ve ağ hatası kuyrukta tutar, üstel geri çekilmeyle (1 sn ile 30 sn arası) aynı batch aynı Idempotency-Key ile yeniden
 * denenir. Yalnız proje public anahtarı (pk_) kabul edilir. tenant_id ve verified asla gönderilmez.
 *
 * <pre>{@code
 * try (FeralinClient client = FeralinClient.builder("pk_live_abc", "https://collect.example.com")
 *         .consent(Consent.analyticsOnly())
 *         .build()) {
 *     client.track("order_completed", Map.of("order_id", "ord_1"));
 * }
 * }</pre>
 */
public final class FeralinClient implements Feralin, AutoCloseable {
    /** Olaylarda gönderilen SDK adı. */
    public static final String SDK_NAME = "feralin-java";
    /** SDK sürümü. */
    public static final String SDK_VERSION = "0.1.0";
    /** UTP v1 platform değeri. */
    public static final String PLATFORM = "java";
    /** UTP şema sürümü. */
    public static final int SCHEMA_VERSION = 1;
    /** Toplayıcının kabul ettiği en büyük batch. */
    public static final int MAX_BATCH_SIZE = 500;
    /** Varsayılan batch boyutu. */
    public static final int DEFAULT_BATCH_SIZE = 100;
    /** Varsayılan kuyruk sınırı. */
    public static final int DEFAULT_QUEUE_LIMIT = 1000;
    /** Varsayılan arka plan gönderim aralığı. */
    public static final Duration DEFAULT_FLUSH_INTERVAL = Duration.ofSeconds(2);
    /** Varsayılan istek süre sınırı. */
    public static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(10);
    /** {@link #close()} için gönderim süre sınırı. */
    public static final Duration CLOSE_TIMEOUT = Duration.ofSeconds(5);

    private static final double MIN_BACKOFF_SECONDS = 1.0;
    private static final double MAX_BACKOFF_SECONDS = 30.0;
    private static final int MAX_PROBLEM_SUMMARY = 200;
    // Başlık değerine satır sonu giremesin; HttpRequest aksi hâlde gönderim anında fırlatır.
    private static final Pattern PRINTABLE_KEY = Pattern.compile("[\\x21-\\x7E]+");
    private static final Logger LOG = System.getLogger("feralin");

    private final String projectKey;
    private final String endpoint;
    private final Duration timeout;
    private final int batchSize;
    private final int queueLimit;
    private final long flushIntervalNanos;
    private final Transport transport;
    private final Clock clock;
    private final UlidGenerator ulid;
    private final String appVersion;
    private final ErrorLimiter errorLimiter;

    private final Object lock = new Object(); // kuyruk, izin, kimlik, geri çekilme
    private final Object sendLock = new Object(); // aynı anda tek gönderici (sabit Idempotency-Key)
    private final List<QueuedEvent> queue = new ArrayList<>();
    // Sonucu bilinmeyen batch aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda kaybolduysa
    // araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
    private List<QueuedEvent> pinned;
    private List<QueuedEvent> inFlight;
    private boolean inFlightWithdrawn;
    private long purgeGeneration;
    private Consent consent;
    private String userId;
    private boolean closed;
    private long dropped;
    private double backoffSeconds;
    private long backoffUntilNanos;

    private final Semaphore wake = new Semaphore(0);
    private volatile boolean stop;
    private Thread flusher;

    private FeralinClient(Builder builder) {
        String key = builder.projectKey == null ? "" : builder.projectKey.trim();
        if (key.startsWith("sk_")) {
            throw new ConfigurationException("gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin");
        }
        if (!key.startsWith("pk_") || key.length() < 8 || !PRINTABLE_KEY.matcher(key).matches()) {
            throw new ConfigurationException("proje anahtarı pk_ ile başlamalı ve boşluk içermemeli");
        }
        if (builder.timeout == null || builder.timeout.isZero() || builder.timeout.isNegative()) {
            throw new ConfigurationException("timeout pozitif olmalı");
        }
        projectKey = key;
        endpoint = endpointFor(builder.collectUrl);
        timeout = builder.timeout;
        batchSize = Math.max(1, Math.min(builder.batchSize, MAX_BATCH_SIZE));
        queueLimit = Math.max(1, builder.queueLimit);
        flushIntervalNanos = builder.flushInterval == null || builder.flushInterval.isNegative() ? 0 : builder.flushInterval.toNanos();
        transport = builder.transport != null ? builder.transport : new HttpClientTransport();
        clock = builder.clock != null ? builder.clock : Clock.systemUTC();
        ulid = new UlidGenerator(clock::millis);
        consent = builder.consent != null ? builder.consent : Consent.none();
        appVersion = builder.appVersion;
        errorLimiter = new ErrorLimiter(builder.errorSampleRate);
    }

    private static String endpointFor(String collectUrl) {
        String text = collectUrl == null ? "" : collectUrl.trim();
        URI uri;
        try {
            uri = new URI(text);
        } catch (java.net.URISyntaxException exc) {
            throw new ConfigurationException("collectUrl geçerli bir adres olmalı");
        }
        String scheme = uri.getScheme();
        if (!("http".equals(scheme) || "https".equals(scheme)) || uri.getHost() == null) {
            throw new ConfigurationException("collectUrl http veya https şemalı mutlak adres olmalı");
        }
        while (text.endsWith("/")) {
            text = text.substring(0, text.length() - 1);
        }
        return text + "/v1/batch";
    }

    /**
     * Yeni istemci kurucusu.
     *
     * @param projectKey proje public anahtarı (pk_)
     * @param collectUrl toplayıcı kök adresi
     * @return kurucu
     */
    public static Builder builder(String projectKey, String collectUrl) {
        return new Builder(projectKey, collectUrl);
    }

    // ------------------------------------------------------------------ genel API

    @Override
    public void setConsent(Consent value) {
        requireConsent(value);
        synchronized (lock) {
            consent = value;
            if (!value.analytics()) {
                queue.clear();
                pinned = null;
                inFlightWithdrawn = true;
                purgeGeneration++;
            }
        }
    }

    @Override
    public void identify(String value) {
        String validated = Events.validateIdentifier(value, "user_id");
        synchronized (lock) {
            userId = validated;
        }
    }

    @Override
    public Optional<UtpEvent> track(String eventName, Map<String, ?> properties, TrackOptions options) {
        Consent currentConsent;
        String defaultUser;
        synchronized (lock) {
            currentConsent = consent;
            defaultUser = userId;
        }
        return enqueue(eventName, properties, options, currentConsent, defaultUser, id -> { });
    }

    @Override
    public Optional<UtpEvent> captureError(Throwable error, TrackOptions options) {
        return capture(error, options, this);
    }

    // Görünümler istemcinin sınırını paylaşır: aynı hata fırtınası istek başına çoğalmaz.
    private Optional<UtpEvent> capture(Throwable error, TrackOptions options, Feralin surface) {
        if (error == null) {
            return Optional.empty();
        }
        try {
            Map<String, Object> props = ErrorEvent.properties(error, ErrorEvent.ORIGIN_HANDLED, false, appVersion);
            if (!errorLimiter.allow((String) props.get("fingerprint"), clock.millis(), ThreadLocalRandom.current().nextDouble())) {
                LOG.log(Level.DEBUG, "feralin: fr_error: hata sınırı ya da örnekleme, olay üretilmedi");
                return Optional.empty();
            }
            return surface.track(ErrorEvent.NAME, props, options);
        } catch (RuntimeException exc) {
            // Hata bildirimi uygulamanın hata yolunda çağrılır; kendisi yeni hata fırlatmaz.
            LOG.log(Level.WARNING, "feralin: fr_error üretilemedi: " + exc.getClass().getName());
            return Optional.empty();
        }
    }

    /**
     * Paylaşılan kuyruğu kullanan, izni ve kimliği kendine ait görünüm. Sunucuda her istek ayrı kullanıcıya aittir; bu
     * yüzden görünümün izni ve kimliği uygulama geneli istemciye veya başka görünüme sızmaz, kapsayıcının kimliğini de
     * devralmaz. Kuyruk, gönderici ve {@link FeralinClient} ömrü ortaktır.
     *
     * @param value bu görünümün başlangıç izni; null hiçbir izin yok demektir
     * @return yeni görünüm
     */
    public Feralin scoped(Consent value) {
        return new Scoped(value != null ? value : Consent.none());
    }

    @Override
    public FlushResult flush() {
        synchronized (lock) {
            if (closed) {
                throw new ClientClosedException("istemci kapatıldı");
            }
        }
        return flushBatches(null);
    }

    /** Arka plan göndericiyi durdurur ve kalan olayları {@link #CLOSE_TIMEOUT} içinde göndermeyi dener. */
    @Override
    public void close() {
        shutdown(CLOSE_TIMEOUT);
    }

    /**
     * Arka plan göndericiyi durdurur ve kalan olayları süre içinde göndermeyi dener. Birden çok çağrı güvenlidir;
     * sonraki çağrılar boş sonuç döner.
     *
     * @param closeTimeout kalan olaylar için süre sınırı
     * @return son gönderimin özeti
     */
    public FlushResult shutdown(Duration closeTimeout) {
        Thread thread;
        synchronized (lock) {
            if (closed) {
                return FlushResult.EMPTY;
            }
            closed = true;
            thread = flusher;
        }
        Duration budget = closeTimeout == null || closeTimeout.isNegative() ? Duration.ZERO : closeTimeout;
        if (thread != null) {
            stop = true;
            wake.release();
            try {
                Duration wait = budget.compareTo(timeout.plusSeconds(1)) > 0 ? budget : timeout.plusSeconds(1);
                thread.join(wait.toMillis());
            } catch (InterruptedException exc) {
                Thread.currentThread().interrupt();
            }
        }
        return flushBatches(System.nanoTime() + budget.toNanos());
    }

    @Override
    public int queued() {
        synchronized (lock) {
            return queue.size();
        }
    }

    @Override
    public Map<String, Object> status() {
        Consent currentConsent;
        String currentUser;
        synchronized (lock) {
            currentConsent = consent;
            currentUser = userId;
        }
        return statusFor(currentConsent, currentUser);
    }

    // ------------------------------------------------------------------ iç işleyiş

    private Map<String, Object> statusFor(Consent viewConsent, String viewUser) {
        Map<String, Object> out = new LinkedHashMap<>();
        synchronized (lock) {
            out.put("sdk", SDK_NAME);
            out.put("version", SDK_VERSION);
            out.put("queued", queue.size());
            out.put("dropped", dropped);
            out.put("consent", viewConsent.toMap());
            out.put("user_id", viewUser);
            out.put("closed", closed);
            out.put("backoff", backoffSeconds);
            out.put("endpoint", endpoint);
        }
        return out;
    }

    private void startFlusher() {
        if (flushIntervalNanos > 0) {
            Thread thread = new Thread(this::runFlusher, "feralin-flush");
            thread.setDaemon(true);
            synchronized (lock) {
                flusher = thread;
            }
            thread.start();
        }
    }

    // Arka plan gönderici: aralık dolunca veya kuyruk batch boyutuna ulaşınca gönderir, geri çekilmeye uyar.
    private void runFlusher() {
        while (true) {
            try {
                wake.tryAcquire(flushIntervalNanos, TimeUnit.NANOSECONDS);
            } catch (InterruptedException exc) {
                Thread.currentThread().interrupt();
                return;
            }
            wake.drainPermits();
            if (stop) {
                return;
            }
            boolean waiting;
            synchronized (lock) {
                waiting = backoffUntilNanos != 0 && System.nanoTime() - backoffUntilNanos < 0;
            }
            if (waiting) {
                continue;
            }
            try {
                flushBatches(null);
            } catch (RuntimeException exc) {
                // Arka plan iş parçacığı ölmesin.
                LOG.log(Level.ERROR, "feralin: arka plan gönderim hatası: " + exc.getClass().getName());
            }
        }
    }

    private Optional<UtpEvent> enqueue(
            String eventName, Map<String, ?> properties, TrackOptions options, Consent eventConsent, String defaultUser, Consumer<String> onQueued) {
        long generation;
        synchronized (lock) {
            if (closed) {
                throw new ClientClosedException("istemci kapatıldı");
            }
            generation = purgeGeneration;
        }
        if (!eventConsent.analytics()) {
            LOG.log(Level.DEBUG, "feralin: izin yok, olay üretilmedi");
            return Optional.empty();
        }

        String name = Events.validateEventName(eventName);
        Map<String, Object> props = Events.validateProperties(properties);
        // fr_click yalnız açık reklam ölçümü izniyle gönderilir.
        if (props != null && !eventConsent.advertising()) {
            props.remove(Events.ATTRIBUTION_CLICK_PROPERTY);
        }
        TrackOptions opts = options != null ? options : TrackOptions.builder().build();
        String uid = Events.validateIdentifier(opts.userId(), "user_id");
        if (uid == null) {
            uid = defaultUser;
        }
        String aid = Events.validateIdentifier(opts.anonymousId(), "anonymous_id");
        String sid = Events.validateIdentifier(opts.sessionId(), "session_id");
        Instant occurredAt = opts.occurredAt() != null ? opts.occurredAt() : clock.instant();

        Map<String, Object> sdk = new LinkedHashMap<>();
        sdk.put("name", SDK_NAME);
        sdk.put("version", SDK_VERSION);
        Map<String, Object> wire = new LinkedHashMap<>();
        wire.put("event_id", ulid.next());
        wire.put("event_name", name);
        wire.put("occurred_at", Events.formatTime(occurredAt));
        wire.put("platform", PLATFORM);
        wire.put("schema_version", SCHEMA_VERSION);
        wire.put("sdk", sdk);
        wire.put("consent", eventConsent.toMap());
        if (aid != null) {
            wire.put("anonymous_id", aid);
        }
        if (uid != null) {
            wire.put("user_id", uid);
        }
        if (sid != null) {
            wire.put("session_id", sid);
        }
        if (props != null && !props.isEmpty()) {
            wire.put("properties", props);
        }
        if (opts.context() != null) {
            Map<String, Object> ctx = opts.context().toMap();
            if (!ctx.isEmpty()) {
                wire.put("context", ctx);
            }
        }

        // Serileştirme kuyruğa eklemeden önce yapılır; bozuk bir olay batch'i zehirleyemez.
        byte[] raw;
        try {
            raw = Json.write(wire).getBytes(StandardCharsets.UTF_8);
        } catch (IllegalArgumentException exc) {
            throw new InvalidEventException("olay JSON'a dönüştürülemedi: " + exc.getMessage());
        }

        UtpEvent event = new UtpEvent(wire);
        boolean full;
        synchronized (lock) {
            if (closed) {
                throw new ClientClosedException("istemci kapatıldı");
            }
            // Doğrulama sürerken izin geri çekildiyse olay kuyruğa girmez.
            if (generation != purgeGeneration) {
                return Optional.empty();
            }
            queue.add(new QueuedEvent(event.eventId(), raw));
            onQueued.accept(event.eventId());
            int over = queue.size() - queueLimit;
            if (over > 0) {
                queue.subList(0, over).clear();
                dropped += over;
                LOG.log(Level.WARNING, "feralin: kuyruk sınırı aşıldı, en eski " + over + " olay atıldı");
            }
            full = queue.size() >= batchSize;
        }
        if (full && flushIntervalNanos > 0) {
            wake.release();
        }
        return Optional.of(event);
    }

    // Yalnız bu görünümün olayları atılır: istek başına izin geri çekilişi başka kullanıcının olayına dokunmaz.
    // Sabitlenmiş batch bu olayları içeriyorsa sabit kalkar, kalanlar yeni batch ve yeni anahtarla gider; izin geri
    // çekilmiş olayın yeniden gönderilmemesi mükerrer riskinden önceliklidir, mükerreri event_id eler.
    private void discard(Collection<String> ids) {
        Set<String> withdrawn = new HashSet<>(ids);
        synchronized (lock) {
            queue.removeIf(item -> withdrawn.contains(item.id));
            if (pinned != null && containsAny(pinned, withdrawn)) {
                pinned = null;
            }
            if (inFlight != null && containsAny(inFlight, withdrawn)) {
                inFlightWithdrawn = true;
            }
        }
    }

    private static boolean containsAny(List<QueuedEvent> batch, Set<String> ids) {
        for (QueuedEvent item : batch) {
            if (ids.contains(item.id)) {
                return true;
            }
        }
        return false;
    }

    private FlushResult flushBatches(Long deadlineNanos) {
        synchronized (sendLock) {
            int sent = 0;
            int accepted = 0;
            int rejected = 0;
            String batchId = null;
            int status = 0;
            DeliveryException error = null;
            // Üretici sürekli ekliyorsa döngü sonsuz olmasın: kuyruk sınırı kadar olay ve bir tur.
            int maxRounds = queueLimit / batchSize + 2;
            for (int round = 0; round < maxRounds; round++) {
                List<QueuedEvent> batch = peek();
                if (batch.isEmpty()) {
                    break;
                }
                Duration requestTimeout = timeout;
                if (deadlineNanos != null) {
                    long remaining = deadlineNanos - System.nanoTime();
                    if (remaining <= 0) {
                        error = new TemporaryException("kapanış zaman aşımı; olaylar gönderilemedi", 0);
                        break;
                    }
                    if (remaining < requestTimeout.toNanos()) {
                        requestTimeout = Duration.ofNanos(remaining);
                    }
                }
                FlushResult result = send(batch, requestTimeout);
                sent += result.sent();
                accepted += result.accepted();
                rejected += result.rejected();
                status = result.status();
                if (result.batchId() != null) {
                    batchId = result.batchId();
                }
                if (result.error() != null) {
                    error = result.error();
                    break;
                }
            }
            return new FlushResult(sent, accepted, rejected, batchId, status, queued(), error);
        }
    }

    private List<QueuedEvent> peek() {
        synchronized (lock) {
            List<QueuedEvent> batch = pinned != null ? pinned : new ArrayList<>(queue.subList(0, Math.min(batchSize, queue.size())));
            inFlight = batch;
            inFlightWithdrawn = false;
            return batch;
        }
    }

    private void acknowledge(List<QueuedEvent> batch) {
        Set<String> ids = new HashSet<>();
        for (QueuedEvent item : batch) {
            ids.add(item.id);
        }
        synchronized (lock) {
            pinned = null;
            inFlight = null;
            queue.removeIf(item -> ids.contains(item.id));
        }
    }

    // İstek sürerken izin geri çekildiyse olaylar çoktan silinmiştir, sabitlenmez.
    private void pin(List<QueuedEvent> batch) {
        synchronized (lock) {
            if (!inFlightWithdrawn) {
                pinned = batch;
            }
            inFlight = null;
        }
    }

    private FlushResult send(List<QueuedEvent> batch, Duration requestTimeout) {
        int count = batch.size();
        // Olaylar zaten serileştirilmiş; gövde bayt birleştirme ile kurulur.
        ByteArrayOutputStream bodyStream = new ByteArrayOutputStream();
        bodyStream.writeBytes(("{\"sent_at\":\"" + Events.formatTime(clock.instant()) + "\",\"events\":[").getBytes(StandardCharsets.UTF_8));
        List<String> ids = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            if (i > 0) {
                bodyStream.write(',');
            }
            bodyStream.writeBytes(batch.get(i).raw);
            ids.add(batch.get(i).id);
        }
        bodyStream.writeBytes("]}".getBytes(StandardCharsets.UTF_8));

        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Content-Type", "application/json");
        headers.put("Accept", "application/json, application/problem+json");
        headers.put("X-Feralin-Project-Key", projectKey);
        headers.put("Idempotency-Key", IdempotencyKeys.of(ids));
        headers.put("User-Agent", SDK_NAME + "/" + SDK_VERSION);

        Transport.Response response;
        try {
            response = transport.send(endpoint, bodyStream.toByteArray(), headers, requestTimeout);
        } catch (DeliveryException exc) {
            pin(batch);
            noteFailure(null);
            return new FlushResult(count, 0, 0, null, exc.status(), count, exc);
        } catch (RuntimeException exc) {
            // Özel taşıma ne fırlatırsa fırlatsın flush fırlatmaz; ileti anahtar taşıyabileceğinden yalnız tür yazılır.
            pin(batch);
            noteFailure(null);
            return new FlushResult(count, 0, 0, null, 0, count, new TemporaryException("taşıma hatası: " + exc.getClass().getName(), 0));
        }

        int status = response.status();
        if (status == 202) {
            Map<?, ?> ack = parseObject(response.body());
            acknowledge(batch);
            noteSuccess();
            Object batchId = ack.get("batch_id");
            FlushResult result = new FlushResult(
                    count,
                    integerOr(ack.get("accepted"), count),
                    integerOr(ack.get("rejected"), 0),
                    batchId instanceof String ? (String) batchId : null,
                    status,
                    0,
                    null);
            LOG.log(Level.DEBUG, "feralin: batch kabul edildi batch_id=" + result.batchId());
            return result;
        }

        if (status >= 400 && status < 500 && status != 429) {
            acknowledge(batch);
            String summary = problemSummary(response.body());
            LOG.log(Level.WARNING, "feralin: batch kalıcı olarak reddedildi status=" + status + " problem=" + summary);
            return new FlushResult(count, 0, count, null, status, 0, new RejectedException("HTTP " + status + ": " + summary, status, summary));
        }

        pin(batch);
        noteFailure(response.header("Retry-After"));
        return new FlushResult(count, 0, 0, null, status, count, new TemporaryException("HTTP " + status + "; olaylar kuyrukta tutuldu", status));
    }

    // Üstel geri çekilme 1 sn ile 30 sn arası; Retry-After verilmişse en az o kadar beklenir.
    // Yarım jitter: aynı anda yeniden başlayan süreçler toplayıcıya birlikte yüklenmez.
    private void noteFailure(String retryAfter) {
        synchronized (lock) {
            double next = Math.max(backoffSeconds * 2, MIN_BACKOFF_SECONDS);
            double floor = 0;
            if (retryAfter != null) {
                try {
                    int seconds = Integer.parseInt(retryAfter.trim());
                    if (seconds > 0) {
                        floor = Math.min(seconds, MAX_BACKOFF_SECONDS);
                        next = Math.max(next, seconds);
                    }
                } catch (NumberFormatException exc) {
                    LOG.log(Level.DEBUG, "feralin: Retry-After saniye değil, yok sayıldı");
                }
            }
            next = Math.min(next, MAX_BACKOFF_SECONDS);
            backoffSeconds = next;
            double wait = Math.max(floor, next * (0.5 + ThreadLocalRandom.current().nextDouble() * 0.5));
            backoffUntilNanos = System.nanoTime() + (long) (wait * 1_000_000_000L);
        }
    }

    private void noteSuccess() {
        synchronized (lock) {
            backoffSeconds = 0;
            backoffUntilNanos = 0;
        }
    }

    private static Map<?, ?> parseObject(byte[] raw) {
        try {
            Object parsed = Json.parse(new String(raw, StandardCharsets.UTF_8));
            return parsed instanceof Map ? (Map<?, ?>) parsed : Map.of();
        } catch (IllegalArgumentException exc) {
            return Map.of();
        }
    }

    private static int integerOr(Object value, int fallback) {
        return value instanceof Long ? ((Long) value).intValue() : fallback;
    }

    // RFC 7807 gövdesinden kısa, loglanabilir özet; ham gövde sızdırılmaz.
    private static String problemSummary(byte[] raw) {
        Map<?, ?> problem = parseObject(raw);
        StringBuilder out = new StringBuilder();
        for (String key : List.of("title", "detail")) {
            Object value = problem.get(key);
            if (value != null && !value.toString().trim().isEmpty()) {
                if (out.length() > 0) {
                    out.append(' ');
                }
                out.append(value.toString().trim());
            }
        }
        if (out.length() == 0) {
            return "problem+json yok";
        }
        return out.length() > MAX_PROBLEM_SUMMARY ? out.substring(0, MAX_PROBLEM_SUMMARY) : out.toString();
    }

    private static void requireConsent(Consent value) {
        if (value == null) {
            throw new InvalidEventException("consent null olamaz");
        }
    }

    private static final class QueuedEvent {
        final String id;
        final byte[] raw;

        QueuedEvent(String id, byte[] raw) {
            this.id = id;
            this.raw = raw;
        }
    }

    /** Paylaşılan kuyruk üzerinde izni ve kimliği kendine ait görünüm. */
    private final class Scoped implements Feralin {
        private final ArrayDeque<String> queuedIds = new ArrayDeque<>();
        private Consent viewConsent;
        private String viewUser;

        Scoped(Consent initial) {
            viewConsent = initial;
        }

        @Override
        public synchronized Optional<UtpEvent> track(String eventName, Map<String, ?> properties, TrackOptions options) {
            return enqueue(eventName, properties, options, viewConsent, viewUser, this::remember);
        }

        // Kuyrukta en fazla queueLimit olay bulunabildiğinden uzun ömürlü görünümde de kimlik listesi büyümez.
        private void remember(String id) {
            queuedIds.addLast(id);
            if (queuedIds.size() > queueLimit) {
                queuedIds.removeFirst();
            }
        }

        @Override
        public synchronized void identify(String value) {
            viewUser = Events.validateIdentifier(value, "user_id");
        }

        @Override
        public Optional<UtpEvent> captureError(Throwable error, TrackOptions options) {
            return capture(error, options, this);
        }

        @Override
        public synchronized void setConsent(Consent value) {
            requireConsent(value);
            viewConsent = value;
            if (!value.analytics()) {
                discard(queuedIds);
                queuedIds.clear();
            }
        }

        @Override
        public FlushResult flush() {
            return FeralinClient.this.flush();
        }

        @Override
        public int queued() {
            return FeralinClient.this.queued();
        }

        @Override
        public synchronized Map<String, Object> status() {
            return statusFor(viewConsent, viewUser);
        }
    }

    /** {@link FeralinClient} kurucusu. */
    public static final class Builder {
        private final String projectKey;
        private final String collectUrl;
        private Consent consent;
        private Duration flushInterval = DEFAULT_FLUSH_INTERVAL;
        private int batchSize = DEFAULT_BATCH_SIZE;
        private int queueLimit = DEFAULT_QUEUE_LIMIT;
        private Duration timeout = DEFAULT_TIMEOUT;
        private Transport transport;
        private Clock clock;
        private String appVersion;
        private double errorSampleRate = 1.0;

        private Builder(String projectKey, String collectUrl) {
            this.projectKey = projectKey;
            this.collectUrl = collectUrl;
        }

        /**
         * @param value başlangıç izni; varsayılan hiçbir izin yok
         * @return bu kurucu
         */
        public Builder consent(Consent value) {
            consent = value;
            return this;
        }

        /**
         * @param value arka plan gönderim aralığı; sıfır arka plan göndericiyi kapatır
         * @return bu kurucu
         */
        public Builder flushInterval(Duration value) {
            flushInterval = value;
            return this;
        }

        /**
         * @param value batch boyutu; 1 ile 500 arasına çekilir
         * @return bu kurucu
         */
        public Builder batchSize(int value) {
            batchSize = value;
            return this;
        }

        /**
         * @param value kuyruk sınırı; aşılınca en eski olay atılır
         * @return bu kurucu
         */
        public Builder queueLimit(int value) {
            queueLimit = value;
            return this;
        }

        /**
         * @param value istek süre sınırı; pozitif olmalı
         * @return bu kurucu
         */
        public Builder timeout(Duration value) {
            timeout = value;
            return this;
        }

        /**
         * @param value özel taşıma
         * @return bu kurucu
         */
        public Builder transport(Transport value) {
            transport = value;
            return this;
        }

        /**
         * @param value saat kaynağı
         * @return bu kurucu
         */
        public Builder clock(Clock value) {
            clock = value;
            return this;
        }

        /**
         * @param value {@code fr_error} olayına yazılan uygulama sürümü (en çok 32 karakter; uzunsa gönderilmez)
         * @return bu kurucu
         */
        public Builder appVersion(String value) {
            appVersion = value;
            return this;
        }

        /**
         * @param value hata olaylarının örnekleme oranı (0..1, varsayılan 1)
         * @return bu kurucu
         */
        public Builder errorSampleRate(double value) {
            errorSampleRate = value;
            return this;
        }

        /**
         * İstemciyi kurar ve aralık pozitifse arka plan göndericiyi başlatır.
         *
         * @return yeni istemci
         * @throws ConfigurationException anahtar, adres veya seçenek geçersizse
         */
        public FeralinClient build() {
            FeralinClient client = new FeralinClient(this);
            client.startFlusher();
            return client;
        }
    }
}
