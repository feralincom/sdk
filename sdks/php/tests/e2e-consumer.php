<?php

// Gerçek services/collect tüketicisi. PHP olan ortamda çalışır: bu makinede PHP yok, ÇALIŞTIRILMADI (BLOCKED_EXTERNAL).
//   FERALIN_E2E_COLLECT_URL=http://127.0.0.1:4701 FERALIN_E2E_PROJECT_KEY=pk_... FERALIN_E2E_CHECKS=checks.txt php tests/e2e-consumer.php
// Denetim satırları sdks/android/scripts/outbox_check.go ile PostgreSQL üzerinde doğrulanır.

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use Feralin\Client;
use Feralin\Consent;
use Feralin\Idempotency;
use Feralin\StreamTransport;
use Feralin\Transport;

$collectUrl = getenv('FERALIN_E2E_COLLECT_URL') ?: throw new RuntimeException('FERALIN_E2E_COLLECT_URL zorunlu');
$projectKey = getenv('FERALIN_E2E_PROJECT_KEY') ?: throw new RuntimeException('FERALIN_E2E_PROJECT_KEY zorunlu');
$checks = getenv('FERALIN_E2E_CHECKS') ?: throw new RuntimeException('FERALIN_E2E_CHECKS zorunlu');

$expect = static fn (string $line) => file_put_contents($checks, $line . "\n", FILE_APPEND);
$check = static function (bool $condition, string $message): void {
    if (!$condition) {
        throw new RuntimeException('KALDI: ' . $message);
    }
};
$report = static fn (string $name, array $detail) => print('  OK ' . $name . ': ' . json_encode($detail) . "\n");
$make = static fn (?Consent $consent, array $extra = [], ?string $key = null) => new Client($key ?? $projectKey, $collectUrl, $extra + ['consent' => $consent ?? new Consent(false), 'flushOnShutdown' => false, 'timeoutSeconds' => 10.0]);

// 202 + outbox satırı + fr_click reklam izniyle
$client = $make(new Consent(true, true));
$event = $client->track('order_completed', ['order_id' => 'ord_php_1', 'fr_click' => 'clk_php_1'], ['userId' => 'user_php_1']);
$result = $client->flush();
$check($result->status === 202 && $result->accepted === 1, '202 bekleniyordu');
$expect('frclick ' . $result->batchId);
$expect('once ' . $event['event_id']);
$report('202-outbox-frclick', ['status' => $result->status, 'batch_id' => $result->batchId]);

// Reklam izni yok: fr_click çıkarılır
$client = $make(new Consent(true, false));
$event = $client->track('order_completed', ['order_id' => 'ord_php_2', 'fr_click' => 'clk_php_2']);
$check(!isset($event['properties']['fr_click']), 'fr_click çıkarılmalıydı');
$result = $client->flush();
$check($result->status === 202, '202 bekleniyordu');
$expect('nofrclick ' . $result->batchId);
$report('frclick-izinsiz-cikarildi', ['status' => $result->status]);

// İzinsiz: SDK olay üretmez
$client = $make(null);
$check($client->track('order_completed') === null && $client->flush()->sent === 0, 'izinsiz olay üretilmemeliydi');
$report('izinsiz-sdk-uretmez', ['sent' => 0]);

// İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
$transport = new StreamTransport();
$id = str_pad('01JCPHP' . time(), 26, '0');
$raw = $transport->post($collectUrl . '/v1/batch', (string) json_encode(['events' => [[
    'event_id' => $id,
    'event_name' => 'denied_event',
    'occurred_at' => gmdate('Y-m-d\TH:i:s\Z'),
    'platform' => 'php',
    'schema_version' => 1,
    'consent' => ['analytics' => false],
]]]), ['Content-Type' => 'application/json', 'x-feralin-project-key' => $projectKey, 'Idempotency-Key' => Idempotency::keyFor([$id])], 10.0);
$body = json_decode($raw['body'], true);
$check($raw['status'] === 202 && $body['accepted'] === 0 && $body['rejected_reasons']['consent_denied'] === 1, 'toplayıcı izinsiz olayı reddetmeliydi');
$expect('absent ' . $id);
$report('izinsiz-toplayici-red', ['status' => $raw['status']]);

// Yanlış anahtar: 401, olay atılır, uygulama düşmez
$client = $make(new Consent(true), [], 'pk_test_wrong_key_000');
$event = $client->track('order_completed', ['order_id' => 'ord_php_wrong']);
$result = $client->flush();
$check($result->status === 401 && $result->rejected === 1 && $result->retained === 0, '401 bekleniyordu');
$expect('absent ' . $event['event_id']);
$report('yanlis-anahtar-401', ['status' => $result->status]);

// Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
$lossy = new class ($transport) implements Transport {
    public array $keys = [];
    private bool $first = true;

    public function __construct(private readonly Transport $inner)
    {
    }

    public function post(string $url, string $body, array $headers, float $timeoutSeconds): array
    {
        $this->keys[] = $headers['Idempotency-Key'];
        $response = $this->inner->post($url, $body, $headers, $timeoutSeconds);
        if ($this->first) {
            $this->first = false;
            return ['status' => 0, 'body' => '', 'retryAfter' => null];
        }
        return $response;
    }
};
$client = $make(new Consent(true), ['transport' => $lossy]);
$event = $client->track('order_completed', ['order_id' => 'ord_php_retry']);
$check($client->flush()->retained === 1, 'yanıt kaybı kuyrukta tutulmalıydı');
$next = $client->track('order_shipped', ['order_id' => 'ord_php_retry']);
$result = $client->flush();
$check($result->status === 202 && $result->retained === 0 && $lossy->keys[0] === $lossy->keys[1], 'aynı anahtar bekleniyordu');
$expect('once ' . $event['event_id']);
$expect('once ' . $next['event_id']);
$report('idempotency-tekrar', ['key' => $lossy->keys[0]]);

// Kimlik yöntemleri (UTP §8.2): global özellik her olaya, kullanıcı özelliği ve grup ayrı sistem olayı. Toplayıcı izin listesi plan,tier.
$profileChecks = getenv('FERALIN_E2E_PROFILE_CHECKS') ?: throw new RuntimeException('FERALIN_E2E_PROFILE_CHECKS zorunlu');
$expectProfile = static fn (string $line) => file_put_contents($profileChecks, $line . "\n", FILE_APPEND);
$who = ['anonymousId' => 'anon_php_profile'];
$client = $make(new Consent(true));
$client->setGlobalProperties(['app_release' => 'e2e']);
$tracked = $client->track('profile_e2e_page', [], $who);
$props = $client->setUserProperties(['plan' => 'pro', 'tier' => 2, 'secret_note' => 'x', 'email' => 'kisi@example.com'], $who);
$grouped = $client->group('acme-team', ['plan' => 'team'], $who);
$check($client->group('kisi@example.com') === null, 'e-posta biçimli grup kimliği reddedilmeliydi');
$check($tracked !== null && $props !== null && $grouped !== null, 'kimlik olayları üretilmeliydi');
$check(!isset($props['properties']['email']), 'kişisel veri anahtarı istemcide düşmeliydi');
$result = $client->flush();
$check($result->status === 202 && $result->accepted === 3, 'kimlik olayları 202 ile kabul edilmeliydi');
$expect('once ' . $tracked['event_id']);
$expectProfile('prop ' . $tracked['event_id'] . ' app_release="e2e"');
$expectProfile('name fr_user_properties:' . $props['event_id']);
$expectProfile('prop ' . $props['event_id'] . ' plan="pro"');
$expectProfile('prop ' . $props['event_id'] . ' tier=2');
$expectProfile('noprop ' . $props['event_id'] . ' secret_note');
$expectProfile('noprop ' . $props['event_id'] . ' app_release');
$expectProfile('name fr_group:' . $grouped['event_id']);
$expectProfile('prop ' . $grouped['event_id'] . ' group_id="acme-team"');
$expectProfile('prop ' . $grouped['event_id'] . ' plan="team"');
$report('kimlik-yontemleri', ['status' => $result->status, 'accepted' => $result->accepted]);

echo "php tüketici: tüm senaryolar geçti\n";
