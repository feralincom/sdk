<?php

declare(strict_types=1);

namespace Feralin;

use InvalidArgumentException;
use Throwable;

/**
 * Feralin PHP server SDK. İlkeler Web SDK ile aynıdır: izin yoksa olay üretilmez, at-least-once gönderim, tüm event_id'lerin
 * özetinden idempotency anahtarı, anahtar yalnız x-feralin-project-key başlığında. Yapılandırma hatası kurucuda fırlar;
 * çalışma zamanındaki hiçbir metot uygulamaya hata fırlatmaz.
 *
 * Kuyruk süreç belleğindedir. PHP-FPM isteği bitince bekleyen olaylar için flushOnShutdown açıktır. Yeniden deneme uzun süren
 * süreçte geri çekilme ile, kısa süreçte exportPending/importPending ile dışarıda saklanarak yapılır.
 */
final class Client
{
    public const SDK_NAME = 'feralin-php';
    public const SDK_VERSION = '0.1.0';

    private const MAX_BATCH_EVENTS = 500;
    // Toplayıcı gövdeyi 1 MiB ile sınırlar; zarf için pay bırakılır.
    private const MAX_BODY_BYTES = 921600;
    private const MIN_BACKOFF_MS = 1000;
    private const MAX_BACKOFF_MS = 30000;
    private const MAX_RETRY_AFTER_MS = 300000;
    private const JSON_FLAGS = JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE;

    private string $projectKey;
    private string $endpoint;
    private Consent $consent;
    private Transport $transport;
    private int $batchSize;
    private int $queueLimit;
    private float $timeoutSeconds;
    /** @var null|callable(string, string): void */
    private $logger;
    /** @var callable(): int */
    private $now;
    /** @var callable(): float */
    private $random;

    /** @var list<array{id: string, json: string, bytes: int}> */
    private array $queue = [];
    /**
     * Sonucu bilinmeyen batch aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda kaybolduysa
     * araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
     *
     * @var null|list<array{id: string, json: string, bytes: int}>
     */
    private ?array $pinned = null;
    private bool $optedOut = false;
    private ?string $userId = null;
    /** @var array<string, mixed> Adı fr_ ile başlamayan her olaya eklenen global özellikler; olayın kendi özelliği önceliklidir. */
    private array $globals = [];
    private bool $closed = false;
    private int $dropped = 0;
    private int $failures = 0;
    private int $notBeforeMs = 0;
    private int $serverNotBeforeMs = 0;
    private ?string $appVersion;
    private float $errorSampleRate;
    /** İlk captureError çağrısında kurulur; WordPress eklentisi gibi otomatik yükleyicisiz kullanımda sınıf erken yüklenmez. */
    private ?ErrorLimiter $errorLimiter = null;

    /**
     * @param array{
     *   consent?: Consent,
     *   batchSize?: int,
     *   queueLimit?: int,
     *   timeoutSeconds?: float,
     *   transport?: Transport,
     *   logger?: callable(string, string): void,
     *   flushOnShutdown?: bool,
     *   now?: callable(): int,
     *   random?: callable(): float,
     *   appVersion?: string,
     *   errorSampleRate?: float,
     * } $options appVersion fr_error olayına yazılır (en çok 32 karakter); errorSampleRate hata olaylarının örnekleme oranıdır (0..1). logger için anahtar, özellik değeri ve kimlik yazılmaz; yalnız sayaç ve durum kodu gelir.
     * @throws InvalidArgumentException Anahtar veya adres geçersizse.
     */
    public function __construct(string $projectKey, string $collectUrl, array $options = [])
    {
        $key = trim($projectKey);
        if (str_starts_with($key, 'sk_')) {
            throw new InvalidArgumentException("feralin: gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin");
        }
        if (!str_starts_with($key, 'pk_') || strlen($key) < 8) {
            throw new InvalidArgumentException('feralin: proje anahtarı pk_ ile başlamalı');
        }
        $url = trim($collectUrl);
        $parts = parse_url($url);
        if ($parts === false || !isset($parts['scheme'], $parts['host']) || !in_array($parts['scheme'], ['http', 'https'], true)) {
            throw new InvalidArgumentException('feralin: collectUrl http veya https şemalı mutlak adres olmalı');
        }

        $this->projectKey = $key;
        $this->endpoint = rtrim($url, '/') . '/v1/batch';
        $this->consent = $options['consent'] ?? new Consent(false);
        $this->batchSize = max(1, min(self::MAX_BATCH_EVENTS, (int) ($options['batchSize'] ?? 100)));
        $this->queueLimit = max(1, (int) ($options['queueLimit'] ?? 1000));
        // Web isteğini uzun süre tutmamak için varsayılan kısadır.
        $this->timeoutSeconds = max(0.1, (float) ($options['timeoutSeconds'] ?? 3.0));
        $this->transport = $options['transport'] ?? new StreamTransport();
        $this->logger = $options['logger'] ?? null;
        $this->now = $options['now'] ?? static fn (): int => (int) floor(microtime(true) * 1000);
        $this->random = $options['random'] ?? static fn (): float => mt_rand() / mt_getrandmax();
        $this->appVersion = isset($options['appVersion']) && is_string($options['appVersion']) ? $options['appVersion'] : null;
        $this->errorSampleRate = max(0.0, min(1.0, (float) ($options['errorSampleRate'] ?? 1.0)));

        if ($options['flushOnShutdown'] ?? true) {
            register_shutdown_function(function (): void {
                $this->close();
            });
        }
    }

    /** Varsayılan izni günceller. analytics=false: bekleyen olaylar silinir, olay bazlı izin de geçersiz olur. */
    public function setConsent(Consent $consent): void
    {
        $this->consent = $consent;
        $this->optedOut = !$consent->analytics;
        if ($this->optedOut) {
            $this->clearQueue();
        }
    }

    public function optOut(): void
    {
        $this->setConsent(new Consent(false));
    }

    /** Varsayılan user_id; boş değer varsayılanı kaldırır. 128 karakteri aşan değer yok sayılır. */
    public function identify(?string $userId): void
    {
        if ($userId !== null && strlen($userId) > EventRules::MAX_IDENTIFIER_LENGTH) {
            $this->log('warning', 'geçersiz user_id yok sayıldı');
            return;
        }
        $this->userId = $userId === '' ? null : $userId;
    }

    /**
     * Global özellikleri birleştirir: null değer anahtarı siler. Kimlik yöntemleriyle aynı temizlik kuralları uygulanır (kişisel
     * veriye benzeyen anahtar, doğrulama alanı, uzun değer düşer); toplam en çok 50 anahtar. Adı `fr_` ile başlamayan her olaya
     * eklenir; olayın aynı anahtardaki özelliği globali ezer.
     *
     * @param array<string, mixed> $properties
     */
    public function setGlobalProperties(array $properties): void
    {
        $this->globals = ProfileRules::mergeGlobals($this->globals, $properties, $dropped);
        if ($dropped > 0) {
            $this->log('warning', 'global özelliklerin bir kısmı sözleşmeye ya da sınıra uymadığı için düştü');
        }
    }

    /** Bütün global özellikleri siler. */
    public function clearGlobalProperties(): void
    {
        $this->globals = [];
    }

    /**
     * Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve temizlenmiş özellikler. Grup kimliği
     * 1-128 karakter olmalı, `@` ve kontrol karakteri içermemelidir; uymazsa olay üretilmez ve null döner. Toplayıcı yalnız
     * projenin izin listesindeki özellikleri saklar.
     *
     * @param array<string, mixed> $traits
     * @param array<string, mixed> $options track ile aynı (userId, anonymousId, sessionId, occurredAtMs, consent)
     * @return array<string, mixed>|null
     */
    public function group(string $groupId, array $traits = [], array $options = []): ?array
    {
        if (!ProfileRules::validGroupId($groupId)) {
            $this->log('warning', 'fr_group: geçersiz group_id, olay üretilmedi');
            return null;
        }
        $properties = ProfileRules::sanitize($traits);
        $properties['group_id'] = $groupId;
        return $this->track(ProfileRules::GROUP_EVENT_NAME, $properties, $options);
    }

    /**
     * Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Geçerli özellik kalmazsa olay üretilmez ve null döner.
     * Toplayıcı yalnız projenin izin listesindeki anahtarları saklar (liste boşsa olay sayılır, özellik saklanmaz).
     *
     * @param array<string, mixed> $properties
     * @param array<string, mixed> $options track ile aynı
     * @return array<string, mixed>|null
     */
    public function setUserProperties(array $properties, array $options = []): ?array
    {
        $clean = ProfileRules::sanitize($properties);
        if ($clean === []) {
            $this->log('warning', 'fr_user_properties: geçerli özellik yok, olay üretilmedi');
            return null;
        }
        return $this->track(ProfileRules::USER_PROPERTIES_EVENT_NAME, $clean, $options);
    }

    /**
     * Satın alma ya da abonelik beyanı (`feralin_purchase`). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa
     * REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez. Sözleşme dışı girdide olay
     * üretilmez ve null döner, fırlatmaz.
     *
     * @param array{
     *   transactionId: string,
     *   amountMinor: int,
     *   currency: string,
     *   productId?: string,
     *   quantity?: int,
     *   purchaseType?: string,
     *   receipt?: array{provider: string, token: string},
     *   properties?: array<string, mixed>,
     * } $revenue amountMinor küçük birimde satır toplamıdır (49,99 TL için 4999); quantity ile çarpılmaz, abonelik iptalinde 0.
     * @param array<string, mixed> $options track ile aynı
     * @return array<string, mixed>|null
     */
    public function trackRevenue(array $revenue, array $options = []): ?array
    {
        $properties = Revenue::properties($revenue);
        if ($properties === null) {
            $this->log('warning', 'geçersiz gelir girdisi, olay üretilmedi');
            return null;
        }
        return $this->track(Revenue::EVENT_NAME, $properties, $options);
    }

    /**
     * Yakalanan bir hatayı `fr_error` olarak bildirir. Ham yığın izi gitmez: hata sınıfı adı, temizlenmiş mesaj, çerçeve özeti olan
     * parmak izi ve sembolleştirme için en çok 5 uygulama çerçevesinin konumu (dosya taban adı, satır, işlev) gider. 60 saniyede en
     * çok 20 olay, aynı parmak izi için en çok 3 olay; sınır dolduysa, izin yoksa ya da girdi geçersizse null döner, fırlatmaz.
     *
     * @param array<string, mixed> $options track seçeneklerine ek olarak origin (handled|manual|uncaught_exception, varsayılan
     *   handled), fatal (varsayılan origin uncaught_exception ise true) ve appVersion (istemci seçeneğini ezer)
     * @return array<string, mixed>|null
     */
    public function captureError(Throwable $error, array $options = []): ?array
    {
        try {
            $origin = $options['origin'] ?? ErrorCapture::ORIGIN_HANDLED;
            if (!in_array($origin, ErrorCapture::ORIGINS, true)) {
                $this->log('warning', 'fr_error: geçersiz origin, olay üretilmedi');
                return null;
            }
            $fatal = (bool) ($options['fatal'] ?? $origin === ErrorCapture::ORIGIN_UNCAUGHT);
            $appVersion = isset($options['appVersion']) && is_string($options['appVersion']) ? $options['appVersion'] : $this->appVersion;
            unset($options['origin'], $options['fatal'], $options['appVersion']);

            $properties = ErrorCapture::properties($error, $origin, $fatal, $appVersion);
            $this->errorLimiter ??= new ErrorLimiter(sampleRate: $this->errorSampleRate);
            if (!$this->errorLimiter->allow($properties['fingerprint'], ($this->now)(), ($this->random)())) {
                $this->log('debug', 'fr_error: hata sınırı ya da örnekleme, olay üretilmedi');
                return null;
            }
            return $this->track(ErrorCapture::EVENT_NAME, $properties, $options);
        } catch (Throwable $failure) {
            $this->log('warning', 'fr_error üretilemedi: ' . get_class($failure));
            return null;
        }
    }

    /** Çıkış: varsayılan kimlik ve kuyruk silinir. */
    public function reset(): void
    {
        $this->userId = null;
        $this->clearQueue();
    }

    /**
     * Olayı doğrular ve kuyruğa ekler; ağ çağrısı yapmaz. İzin yoksa veya girdi geçersizse null döner, fırlatmaz.
     * fr_click yalnız consent.advertising === true iken gönderilir, aksi halde çıkarılır.
     *
     * @param array<string, mixed> $properties
     * @param array{
     *   userId?: string,
     *   anonymousId?: string,
     *   sessionId?: string,
     *   occurredAtMs?: int,
     *   context?: array<string, mixed>,
     *   consent?: Consent,
     * } $options
     * @return array<string, mixed>|null Tel üzerindeki olay.
     */
    public function track(string $eventName, array $properties = [], array $options = []): ?array
    {
        try {
            return $this->buildAndEnqueue($eventName, $properties, $options);
        } catch (Throwable $error) {
            // JSON'a dönüştürülemeyen değer (NAN, bozuk UTF-8, derin yapı) dahil hiçbir girdi uygulamayı düşürmez.
            $this->log('warning', 'olay üretilemedi: ' . get_class($error));
            return null;
        }
    }

    /**
     * @param array<string, mixed> $properties
     * @param array<string, mixed> $options
     * @return array<string, mixed>|null
     */
    private function buildAndEnqueue(string $eventName, array $properties, array $options): ?array
    {
        if ($this->closed || $this->optedOut) {
            return null;
        }
        /** @var Consent $consent */
        $consent = $options['consent'] ?? $this->consent;
        if (!$consent->analytics) {
            $this->log('debug', 'izin yok, olay üretilmedi');
            return null;
        }
        if (!EventRules::validEventName($eventName)) {
            $this->log('warning', 'geçersiz olay adı');
            return null;
        }
        $userId = $options['userId'] ?? $this->userId;
        foreach ([$userId, $options['anonymousId'] ?? null, $options['sessionId'] ?? null] as $identifier) {
            if ($identifier !== null && (!is_string($identifier) || strlen($identifier) > EventRules::MAX_IDENTIFIER_LENGTH)) {
                $this->log('warning', 'geçersiz kimlik alanı, olay üretilmedi');
                return null;
            }
        }

        $props = EventRules::sanitizeProperties($properties);
        $context = EventRules::normalizeContext(is_array($options['context'] ?? null) ? $options['context'] : [], $props);
        if ($consent->advertising !== true) {
            unset($props[EventRules::CLICK_PROPERTY]);
        }
        // Global özellikler sistem olaylarına (fr_) eklenmez: toplayıcı onların gövdesini kapalı sözleşmeyle denetler.
        if ($this->globals !== [] && !str_starts_with($eventName, ProfileRules::SYSTEM_EVENT_PREFIX)) {
            foreach ($this->globals as $key => $value) {
                if (!array_key_exists($key, $props) && count($props) < EventRules::MAX_PROPERTIES) {
                    $props[$key] = $value;
                }
            }
        }

        $nowMs = ($this->now)();
        $event = [
            'event_id' => EventRules::ulid($nowMs),
            'event_name' => $eventName,
            'occurred_at' => self::formatTime((int) ($options['occurredAtMs'] ?? $nowMs)),
            'platform' => 'php',
            'schema_version' => 1,
            'sdk' => ['name' => self::SDK_NAME, 'version' => self::SDK_VERSION],
            'consent' => $consent->toArray(),
        ];
        if (!empty($options['anonymousId'])) {
            $event['anonymous_id'] = $options['anonymousId'];
        }
        if (!empty($userId)) {
            $event['user_id'] = $userId;
        }
        if (!empty($options['sessionId'])) {
            $event['session_id'] = $options['sessionId'];
        }
        if ($props !== []) {
            $event['properties'] = $props;
        }
        if ($context !== []) {
            $event['context'] = $context;
        }

        // Serileştirme kuyruktan önce yapılır; bozuk bir olay batch'i zehirleyemez.
        $json = json_encode($event, self::JSON_FLAGS);
        $bytes = strlen($json);
        if ($bytes > self::MAX_BODY_BYTES) {
            $this->log('warning', 'olay boyut sınırını aşıyor, atıldı');
            return null;
        }
        $this->queue[] = ['id' => $event['event_id'], 'json' => $json, 'bytes' => $bytes];
        $over = count($this->queue) + count($this->pinned ?? []) - $this->queueLimit;
        if ($over > 0) {
            $removed = min($over, count($this->queue));
            array_splice($this->queue, 0, $removed);
            $this->dropped += $removed;
            $this->log('warning', 'kuyruk sınırı aşıldı, en eski olaylar atıldı');
        }
        return $event;
    }

    /**
     * Kuyruğu gönderir; fırlatmaz. 202 → silinir; 4xx (429 hariç) → atılır; 429, 5xx ve ağ hatası → aynı içerik ve aynı
     * anahtarla sonra denenir. Sunucunun Retry-After süresi dolmadan açık çağrı da istek yapmaz.
     */
    public function flush(): FlushResult
    {
        if (($this->now)() < $this->serverNotBeforeMs) {
            return new FlushResult(retained: $this->queued());
        }
        return $this->drain();
    }

    /** Kalanı son kez göndermeyi dener, sonra olay üretilmez. Birden çok çağrı güvenlidir. */
    public function close(): FlushResult
    {
        if ($this->closed) {
            return new FlushResult(retained: $this->queued());
        }
        $this->closed = true;
        return $this->drain();
    }

    /**
     * Gönderilemeyen olayları dışarıda saklamak için döndürür ve bellekteki kuyruğu boşaltır (WordPress seçeneği, Redis).
     * Olaylar gizli anahtar içermez, ancak müşteri verisi taşıyabilir: erişimi kısıtlı yerde saklayın.
     *
     * @return list<string> Olayların JSON satırları; önceki batch sırası korunur.
     */
    public function exportPending(): array
    {
        $items = array_merge($this->pinned ?? [], $this->queue);
        $this->pinned = null;
        $this->queue = [];
        return array_map(static fn (array $item): string => $item['json'], $items);
    }

    /**
     * exportPending çıktısını kuyruğa geri alır. Bozuk satır atılır. Aynı event_id korunur; toplayıcı tarafı tekilleştirir.
     *
     * @param list<string> $events
     */
    public function importPending(array $events): int
    {
        if ($this->closed || $this->optedOut) {
            return 0;
        }
        $restored = 0;
        foreach ($events as $json) {
            try {
                $event = is_string($json) ? json_decode($json, true, 64, JSON_THROW_ON_ERROR) : null;
            } catch (Throwable) {
                continue;
            }
            if (is_array($event) && is_string($event['event_id'] ?? null) && strlen($json) <= self::MAX_BODY_BYTES) {
                $this->queue[] = ['id' => $event['event_id'], 'json' => $json, 'bytes' => strlen($json)];
                $restored++;
            }
        }
        return $restored;
    }

    /** @return array<string, mixed> Anlık durum (tanı amaçlı); anahtar döndürülmez. */
    public function getStatus(): array
    {
        return [
            'sdk' => self::SDK_NAME,
            'version' => self::SDK_VERSION,
            'queued' => $this->queued(),
            'dropped' => $this->dropped,
            'consent' => $this->consent->toArray(),
            'optedOut' => $this->optedOut,
            'closed' => $this->closed,
            'backoffMs' => max(0, max($this->notBeforeMs, $this->serverNotBeforeMs) - ($this->now)()),
            'endpoint' => $this->endpoint,
        ];
    }

    private function drain(): FlushResult
    {
        $sent = $accepted = $rejected = $status = 0;
        $batchId = null;
        // Üretici sürekli ekliyorsa döngü sonsuz olmasın.
        $rounds = (int) ceil($this->queueLimit / $this->batchSize) + 2;
        for ($round = 0; $round < $rounds; $round++) {
            $batch = $this->nextBatch();
            if ($batch === null) {
                break;
            }
            $result = $this->send($batch);
            $sent += $result->sent;
            $accepted += $result->accepted;
            $rejected += $result->rejected;
            $status = $result->status;
            $batchId = $result->batchId ?? $batchId;
            if ($result->retained > 0) {
                break;
            }
        }
        return new FlushResult($sent, $accepted, $rejected, $status, $this->queued(), $batchId);
    }

    /** @return null|list<array{id: string, json: string, bytes: int}> */
    private function nextBatch(): ?array
    {
        if ($this->pinned !== null) {
            return $this->pinned;
        }
        if ($this->queue === []) {
            return null;
        }
        $count = 0;
        $bytes = 0;
        foreach ($this->queue as $item) {
            if ($count >= $this->batchSize || ($count > 0 && $bytes + $item['bytes'] > self::MAX_BODY_BYTES)) {
                break;
            }
            $count++;
            $bytes += $item['bytes'] + 1;
        }
        $this->pinned = array_splice($this->queue, 0, $count);
        return $this->pinned;
    }

    /** @param list<array{id: string, json: string, bytes: int}> $batch */
    private function send(array $batch): FlushResult
    {
        $size = count($batch);
        $ids = array_map(static fn (array $item): string => $item['id'], $batch);
        $body = '{"sent_at":"' . self::formatTime(($this->now)()) . '","events":['
            . implode(',', array_map(static fn (array $item): string => $item['json'], $batch)) . ']}';
        try {
            $response = $this->transport->post($this->endpoint, $body, [
                'Content-Type' => 'application/json',
                'Accept' => 'application/json, application/problem+json',
                'x-feralin-project-key' => $this->projectKey,
                'Idempotency-Key' => Idempotency::keyFor($ids),
                'User-Agent' => self::SDK_NAME . '/' . self::SDK_VERSION,
            ], $this->timeoutSeconds);
        } catch (Throwable $error) {
            $this->noteFailure(null);
            $this->log('debug', 'taşıma hatası, olaylar kuyrukta: ' . get_class($error));
            return new FlushResult(sent: $size, retained: $size);
        }

        $status = $response['status'];
        if ($status === 202) {
            $this->pinned = null;
            $this->failures = 0;
            $this->notBeforeMs = 0;
            $this->serverNotBeforeMs = 0;
            $ack = json_decode($response['body'], true);
            $ack = is_array($ack) ? $ack : [];
            $this->log('debug', 'batch kabul edildi');
            return new FlushResult(
                sent: $size,
                accepted: is_int($ack['accepted'] ?? null) ? $ack['accepted'] : $size,
                rejected: is_int($ack['rejected'] ?? null) ? $ack['rejected'] : 0,
                status: 202,
                batchId: is_string($ack['batch_id'] ?? null) ? $ack['batch_id'] : null,
            );
        }
        if ($status >= 400 && $status < 500 && $status !== 429) {
            $this->pinned = null;
            $this->log('warning', 'batch kalıcı olarak reddedildi: HTTP ' . $status);
            return new FlushResult(sent: $size, rejected: $size, status: $status);
        }
        $this->noteFailure($response['retryAfter'] ?? null);
        $this->log('debug', 'geçici hata, olaylar kuyrukta: HTTP ' . $status);
        return new FlushResult(sent: $size, status: $status, retained: $size);
    }

    private function noteFailure(?string $retryAfter): void
    {
        $this->failures++;
        $ceiling = min(self::MAX_BACKOFF_MS, self::MIN_BACKOFF_MS * (2 ** min($this->failures - 1, 10)));
        $now = ($this->now)();
        // Yarım jitter: aynı anda yeniden başlayan süreçler toplayıcıya birlikte yüklenmez.
        $this->notBeforeMs = $now + (int) round($ceiling * (0.5 + (($this->random)() * 0.5)));
        if ($retryAfter !== null && ctype_digit(trim($retryAfter)) && (int) trim($retryAfter) > 0) {
            $this->serverNotBeforeMs = $now + min(self::MAX_RETRY_AFTER_MS, (int) trim($retryAfter) * 1000);
        }
    }

    private function queued(): int
    {
        return count($this->queue) + count($this->pinned ?? []);
    }

    private function clearQueue(): void
    {
        $this->queue = [];
        $this->pinned = null;
        $this->failures = 0;
        $this->notBeforeMs = 0;
        $this->serverNotBeforeMs = 0;
    }

    private function log(string $level, string $message): void
    {
        if ($this->logger === null) {
            return;
        }
        try {
            ($this->logger)($level, $message);
        } catch (Throwable) {
            // Uygulamanın log hatası SDK akışını kesmez.
        }
    }

    private static function formatTime(int $ms): string
    {
        $seconds = (int) floor($ms / 1000);
        return gmdate('Y-m-d\TH:i:s', $seconds) . sprintf('.%03dZ', $ms - ($seconds * 1000));
    }
}
