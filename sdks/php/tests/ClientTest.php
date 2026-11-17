<?php

declare(strict_types=1);

namespace Feralin\Tests;

use Feralin\Client;
use Feralin\Consent;
use Feralin\ErrorCapture;
use Feralin\ErrorLimiter;
use Feralin\Idempotency;
use Feralin\ProfileRules;
use Feralin\Revenue;
use Feralin\Transport;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;
use RuntimeException;
use Throwable;

/** Sahte taşıma: yanıt sırası verilir, istekler kaydedilir. */
final class FakeTransport implements Transport
{
    /** @var list<array{url: string, body: string, headers: array<string, string>}> */
    public array $calls = [];

    /** @param list<array{status: int, body?: string, retryAfter?: string}|RuntimeException> $responses */
    public function __construct(public array $responses = [])
    {
    }

    public function post(string $url, string $body, array $headers, float $timeoutSeconds): array
    {
        $this->calls[] = ['url' => $url, 'body' => $body, 'headers' => $headers];
        $next = array_shift($this->responses) ?? ['status' => 202, 'body' => '{"batch_id":"b1","accepted":1,"rejected":0}'];
        if ($next instanceof RuntimeException) {
            throw $next;
        }
        return ['status' => $next['status'], 'body' => $next['body'] ?? '', 'retryAfter' => $next['retryAfter'] ?? null];
    }

    /** @return list<string> */
    public function eventIds(int $call): array
    {
        $body = json_decode($this->calls[$call]['body'], true);
        return array_map(static fn (array $event): string => $event['event_id'], $body['events']);
    }
}

/** Birim testleri. Gerçek toplayıcı testi tests/e2e-consumer.php içindedir. */
final class ClientTest extends TestCase
{
    private const KEY = 'pk_test_php_unit_0001';
    private const URL = 'http://collector.test';

    /** @param array<string, mixed> $options */
    private function client(FakeTransport $transport, array $options = []): Client
    {
        return new Client(self::KEY, self::URL, $options + [
            'transport' => $transport,
            'consent' => new Consent(true),
            'flushOnShutdown' => false,
            'random' => static fn (): float => 1.0,
        ]);
    }

    public function testYapilandirmaHatasiKurucudaFirlar(): void
    {
        foreach ([['sk_live_12345678', self::URL], ['abc_12345678', self::URL], [self::KEY, 'ftp://x'], [self::KEY, 'yol']] as [$key, $url]) {
            try {
                new Client($key, $url, ['flushOnShutdown' => false]);
                self::fail('hata bekleniyordu');
            } catch (InvalidArgumentException $error) {
                self::assertStringContainsString('feralin:', $error->getMessage());
            }
        }
    }

    public function testIzinYoksaOlayUretilmezVeIstekYapilmaz(): void
    {
        $transport = new FakeTransport();
        $client = new Client(self::KEY, self::URL, ['transport' => $transport, 'flushOnShutdown' => false]);
        self::assertNull($client->track('order_completed'));
        self::assertSame(0, $client->flush()->sent);
        self::assertSame([], $transport->calls);
    }

    public function testOlayBazliIzinVarsayilaniAsarAcikRetAsilamaz(): void
    {
        $client = $this->client(new FakeTransport(), ['consent' => new Consent(false)]);
        self::assertNotNull($client->track('a', [], ['consent' => new Consent(true)]));
        $client->optOut();
        self::assertSame(0, $client->getStatus()['queued']);
        self::assertNull($client->track('a', [], ['consent' => new Consent(true)]));
        $client->setConsent(new Consent(true));
        self::assertNotNull($client->track('a'));
    }

    public function testFrClickYalnizReklamIzniyleGider(): void
    {
        $client = $this->client(new FakeTransport());
        self::assertArrayNotHasKey('fr_click', $client->track('a', ['fr_click' => 'x', 'keep' => 1])['properties']);
        self::assertArrayNotHasKey('properties', $client->track('a', ['fr_click' => 'x'], ['consent' => new Consent(true, false)]));
        self::assertSame('x', $client->track('a', ['fr_click' => 'x'], ['consent' => new Consent(true, true)])['properties']['fr_click']);
    }

    public function testTelBicimiVeAnahtarYalnizBaslikta(): void
    {
        $transport = new FakeTransport();
        $client = $this->client($transport);
        $client->identify('user_42');
        $client->track('order_completed', ['order_id' => 'ord_1', 'geçersiz anahtar' => 1], [
            'occurredAtMs' => 1793700000123,
            'context' => [
                'page_url' => 'https://shop.example/odeme?token=gizli&utm_source=ads#x',
                'referrer' => 'https://google.example/search?q=gizli',
                'page_title' => 'Ödeme',
                'bilinmeyen' => 'x',
            ],
        ]);
        self::assertSame(202, $client->flush()->status);
        $call = $transport->calls[0];
        self::assertSame(self::URL . '/v1/batch', $call['url']);
        self::assertSame(self::KEY, $call['headers']['x-feralin-project-key']);
        self::assertStringNotContainsString(self::KEY, $call['body']);
        self::assertStringNotContainsString('gizli', $call['body']);
        $event = json_decode($call['body'], true)['events'][0];
        self::assertSame('php', $event['platform']);
        self::assertSame(1, $event['schema_version']);
        self::assertSame('user_42', $event['user_id']);
        self::assertSame(26, strlen($event['event_id']));
        self::assertMatchesRegularExpression('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.123Z$/', $event['occurred_at']);
        self::assertSame('https://shop.example/odeme', $event['context']['page_url']);
        self::assertSame('https://google.example', $event['context']['referrer']);
        self::assertSame('ads', $event['properties']['utm_source']);
        self::assertArrayNotHasKey('bilinmeyen', $event['context']);
        foreach (['tenant_id', 'project_id', 'verified'] as $banned) {
            self::assertArrayNotHasKey($banned, $event);
        }
    }

    /** Saldırgan başlıkları tek geçersiz alanla batch'i düşüremez: şema sınırı ve format: uri korunur. */
    public function testSaldirganBaglamSemadanGecer(): void
    {
        $client = $this->client(new FakeTransport());
        $long = $client->track('a', [], ['context' => ['page_url' => 'https://h.example.test/x', 'referrer' => 'https://' . str_repeat('r', 3000) . '.example.test/']])['context'];
        self::assertArrayNotHasKey('referrer', $long);
        self::assertSame('https://h.example.test/x', $long['page_url']);

        foreach (['a b', 'a<b>', 'h%zz', "h\xC3\xA9"] as $host) {
            $event = $client->track('a', [], ['context' => ['page_url' => 'http://' . $host . '/x', 'referrer' => 'http://' . $host . '/x']]);
            self::assertArrayNotHasKey('context', $event, $host);
        }
        $event = $client->track('a', [], ['context' => ['page_url' => 'http://[::1]:8080/x', 'referrer' => 'https://[::1]/x']]);
        self::assertSame('http://[::1]:8080/x', $event['context']['page_url']);
        self::assertSame('https://[::1]', $event['context']['referrer']);
        $event = $client->track('a', [], ['context' => ['page_url' => 'http://[zz]/x']]);
        self::assertArrayNotHasKey('context', $event);

        $event = $client->track('a', [], ['context' => ['page_url' => "https://h.example.test/100%/a b/\xC3\xA7/a%20b"]]);
        self::assertSame('https://h.example.test/100%25/a%20b/%C3%A7/a%20b', $event['context']['page_url']);
        $event = $client->track('a', [], ['context' => ['page_url' => 'https://h.example.test/' . str_repeat('a', 3000)]]);
        self::assertArrayNotHasKey('context', $event);

        $event = $client->track('a', [], ['context' => ['locale' => "\xB1\x31", 'timezone' => 'Europe/Istanbul']]);
        self::assertNotNull($event, 'bozuk UTF-8 yalnız alanı düşürmeli');
        self::assertArrayNotHasKey('locale', $event['context']);
        self::assertSame(16, strlen($client->track('a', [], ['context' => ['locale' => str_repeat('x', 40)]])['context']['locale']));
    }

    public function testGecersizGirdiFirlatmaz(): void
    {
        $warnings = [];
        $client = $this->client(new FakeTransport(), ['logger' => function (string $level, string $message) use (&$warnings): void {
            $warnings[] = $message;
        }]);
        self::assertNull($client->track('Geçersiz Ad'));
        self::assertNull($client->track('a', [], ['userId' => str_repeat('x', 129)]));
        self::assertNull($client->track('a', ['nan' => NAN]));
        self::assertNull($client->track('a', ['bozuk' => "\xB1\x31"]));
        self::assertSame(0, $client->getStatus()['queued']);
        self::assertGreaterThanOrEqual(3, count($warnings));
    }

    public function testIdempotencyAnahtariDigerSdklarlaAyni(): void
    {
        self::assertSame('8f95d6b736d56c98-2', Idempotency::keyFor(['01JC0000000000000000000002', '01JC0000000000000000000001']));
        $transport = new FakeTransport();
        $client = $this->client($transport);
        $a = $client->track('a');
        $b = $client->track('b');
        $client->flush();
        self::assertSame(Idempotency::keyFor([$a['event_id'], $b['event_id']]), $transport->calls[0]['headers']['Idempotency-Key']);
    }

    public function testSonucuBilinmeyenBatchAyniIcerikVeAnahtarlaDenenir(): void
    {
        $transport = new FakeTransport([new RuntimeException('ağ yok'), ['status' => 503], ['status' => 202, 'body' => '{}'], ['status' => 202, 'body' => '{}']]);
        $client = $this->client($transport);
        $first = $client->track('a');
        self::assertSame(1, $client->flush()->retained);
        $second = $client->track('b');
        self::assertSame(2, $client->flush()->retained);
        self::assertSame(0, $client->flush()->retained);
        self::assertSame($transport->calls[0]['headers']['Idempotency-Key'], $transport->calls[1]['headers']['Idempotency-Key']);
        self::assertSame($transport->calls[1]['headers']['Idempotency-Key'], $transport->calls[2]['headers']['Idempotency-Key']);
        self::assertSame([$first['event_id']], $transport->eventIds(2));
        self::assertSame([$second['event_id']], $transport->eventIds(3));
    }

    public function testKalici4xxAtar429TutarRetryAfterSuresinceIstekYapmaz(): void
    {
        $now = 1000000;
        $transport = new FakeTransport([['status' => 401, 'body' => '{"title":"Geçersiz"}'], ['status' => 429, 'retryAfter' => '60'], ['status' => 202, 'body' => '{}']]);
        $client = $this->client($transport, ['now' => static function () use (&$now): int {
            return $now;
        }]);
        $client->track('a');
        $rejected = $client->flush();
        self::assertSame([401, 1, 0], [$rejected->status, $rejected->rejected, $rejected->retained]);
        $client->track('b');
        self::assertSame(429, $client->flush()->status);
        self::assertSame(0, $client->flush()->sent);
        self::assertCount(2, $transport->calls);
        $now += 61000;
        self::assertSame(202, $client->flush()->status);
    }

    public function testGeriCekilmeUstelVeSinirli(): void
    {
        $failures = array_fill(0, 8, new RuntimeException('ağ yok'));
        $client = $this->client(new FakeTransport($failures), ['now' => static fn (): int => 1000]);
        $client->track('a');
        $delays = [];
        for ($i = 0; $i < 8; $i++) {
            $client->flush();
            $delays[] = $client->getStatus()['backoffMs'];
        }
        self::assertSame([1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000], $delays);
    }

    public function testKuyrukSiniriVeBatchUstSiniri(): void
    {
        $transport = new FakeTransport();
        $client = $this->client($transport, ['queueLimit' => 3, 'batchSize' => 2]);
        $ids = array_map(static fn (string $name) => $client->track($name)['event_id'], ['a', 'b', 'c', 'd']);
        self::assertSame(1, $client->getStatus()['dropped']);
        $client->flush();
        self::assertCount(2, $transport->eventIds(0));
        self::assertSame(array_slice($ids, 1), array_merge($transport->eventIds(0), $transport->eventIds(1)));
    }

    public function testExportVeImportAyniEventIdIleDevamEder(): void
    {
        $transport = new FakeTransport([new RuntimeException('ağ yok')]);
        $first = $this->client($transport);
        $event = $first->track('a');
        $first->flush();
        $pending = $first->exportPending();
        self::assertCount(1, $pending);
        self::assertSame(0, $first->getStatus()['queued']);

        $second = $this->client($transport);
        self::assertSame(1, $second->importPending([...$pending, 'bozuk json']));
        self::assertSame(202, $second->flush()->status);
        self::assertSame([$event['event_id']], $transport->eventIds(1));
    }

    public function testCloseSonrasiOlayUretilmezIkinciCagriGuvenli(): void
    {
        $transport = new FakeTransport();
        $client = $this->client($transport);
        $client->track('a');
        self::assertSame(202, $client->close()->status);
        self::assertNull($client->track('b'));
        self::assertSame(0, $client->close()->sent);
        self::assertCount(1, $transport->calls);
    }

    public function testSirLoglanmaz(): void
    {
        $lines = [];
        $transport = new FakeTransport([['status' => 401, 'body' => '{"detail":"gizli_govde"}'], new RuntimeException('ağ'), ['status' => 500]]);
        $client = $this->client($transport, ['logger' => function (string $level, string $message) use (&$lines): void {
            $lines[] = $message;
        }]);
        $client->identify('kullanici_gizli');
        $client->track('a', ['deger' => 'ozellik_gizli']);
        $client->flush();
        $client->track('b', ['deger' => 'ozellik_gizli']);
        $client->flush();
        $client->flush();
        $output = implode("\n", $lines);
        self::assertNotSame('', $output);
        foreach ([self::KEY, 'ozellik_gizli', 'kullanici_gizli', 'gizli_govde'] as $secret) {
            self::assertStringNotContainsString($secret, $output);
        }
        self::assertStringNotContainsString(self::KEY, (string) json_encode($client->getStatus()));
    }

    public function testLoggerHatasiUygulamayaYansimaz(): void
    {
        $client = $this->client(new FakeTransport(), ['logger' => static function (): void {
            throw new RuntimeException('logger');
        }]);
        self::assertNull($client->track('Geçersiz Ad'));
    }

    /** @return list<array<string, mixed>> Son gönderimdeki olaylar */
    private static function sentEvents(FakeTransport $transport): array
    {
        $body = json_decode($transport->calls[count($transport->calls) - 1]['body'], true);
        return $body['events'];
    }

    public function testKisiselVeriAnahtarKurali(): void
    {
        foreach (['email', 'userEmail', 'email_address', 'phone', 'phoneNumber', 'mobile', 'ip', 'userIP', 'ipv4', 'ip_address',
            'first_name', 'lastName', 'fullname', 'surname', 'ad_soyad', 'soyadi', 'name', 'userName', 'displayName',
            'isim', 'ad', 'home_address', 'tckn', 'ssn', 'password', 'birthdate', 'dob', 'iban', 'eposta', 'telefon_no'] as $key) {
            self::assertTrue(ProfileRules::isPiiLikeKey($key), $key);
        }
        foreach (['plan', 'tier', 'zip_code', 'hotel', 'membership', 'ad_network', 'plan_name', 'company_size'] as $key) {
            self::assertFalse(ProfileRules::isPiiLikeKey($key), $key);
        }
    }

    public function testOzellikTemizligi(): void
    {
        $clean = ProfileRules::sanitize([
            'plan' => 'pro', 'tier' => 2, 'ratio' => 0.5, 'beta' => true,
            'verified' => true, 'receipt' => 'x', 'email' => 'a@b.co', 'note' => 'iletişim a@b.co',
            'long' => str_repeat('x', 257), 'ok_long' => str_repeat('ş', 256), 'nested' => ['a' => 1], 'nothing' => null,
            'nan' => NAN, 'inf' => INF, 'ctrl' => "a\nb", '1bad' => 'x', 7 => 'sayi-anahtar',
        ]);
        self::assertSame(['plan' => 'pro', 'tier' => 2, 'ratio' => 0.5, 'beta' => true, 'ok_long' => str_repeat('ş', 256)], $clean);
        $many = [];
        for ($i = 0; $i < 60; $i++) {
            $many['k' . $i] = $i;
        }
        self::assertCount(ProfileRules::MAX_PROPERTIES, ProfileRules::sanitize($many));
    }

    public function testGrupVeKullaniciOzellikleri(): void
    {
        $transport = new FakeTransport();
        $client = $this->client($transport);
        self::assertNotNull($client->group('acme-team', ['plan' => 'team', 'email' => 'x@y.co', 'group_id' => 'baska'], ['userId' => 'u1']));
        foreach (['', '   ', str_repeat('a', 129), 'ali@example.com', "a\tb"] as $bad) {
            self::assertNull($client->group($bad), $bad);
        }
        self::assertNotNull($client->group(str_repeat('g', 128)));
        self::assertNull($client->setUserProperties(['email' => 'a@b.co', 'verified' => true]));
        self::assertNotNull($client->setUserProperties(['plan' => 'pro', 'tier' => 2, 'phone' => '555'], ['anonymousId' => 'anon_1']));
        $client->flush();
        $events = self::sentEvents($transport);
        self::assertCount(3, $events);
        self::assertSame('fr_group', $events[0]['event_name']);
        self::assertSame('u1', $events[0]['user_id']);
        self::assertSame(['plan' => 'team', 'group_id' => 'acme-team'], $events[0]['properties']);
        self::assertSame('fr_user_properties', $events[2]['event_name']);
        self::assertSame('anon_1', $events[2]['anonymous_id']);
        self::assertSame(['plan' => 'pro', 'tier' => 2], $events[2]['properties']);
    }

    public function testGlobalOzellikler(): void
    {
        $transport = new FakeTransport();
        $client = $this->client($transport);
        $client->setGlobalProperties(['app_release' => 'e2e', 'plan' => 'free', 'email' => 'a@b.co']);
        $client->track('page_view', ['plan' => 'pro']);
        $client->track('checkout');
        $client->setUserProperties(['tier' => 1]);
        $client->group('acme');
        $client->setGlobalProperties(['plan' => null]);
        $client->track('after_remove');
        $client->clearGlobalProperties();
        $client->track('after_clear');
        $client->flush();
        $events = self::sentEvents($transport);
        self::assertSame(['plan' => 'pro', 'app_release' => 'e2e'], $events[0]['properties']);
        self::assertSame(['app_release' => 'e2e', 'plan' => 'free'], $events[1]['properties']);
        // fr_ sistem olaylarına global eklenmez.
        self::assertSame(['tier' => 1], $events[2]['properties']);
        self::assertSame(['group_id' => 'acme'], $events[3]['properties']);
        self::assertSame(['app_release' => 'e2e'], $events[4]['properties']);
        self::assertArrayNotHasKey('properties', $events[5]);
    }

    public function testGlobalOzellikSiniri(): void
    {
        $transport = new FakeTransport();
        $client = $this->client($transport);
        $first = [];
        $second = [];
        for ($i = 0; $i < 40; $i++) {
            $first['g' . $i] = $i;
            $second['h' . $i] = $i;
        }
        $client->setGlobalProperties($first);
        $client->setGlobalProperties($second);
        $client->setGlobalProperties(['g0' => 'yeni']);
        $client->track('page_view');
        $client->flush();
        $props = self::sentEvents($transport)[0]['properties'];
        self::assertCount(ProfileRules::MAX_PROPERTIES, $props);
        self::assertSame('yeni', $props['g0']);
        self::assertArrayHasKey('h9', $props);
        self::assertArrayNotHasKey('h10', $props);
    }

    // --- Gelir (feralin_purchase) ------------------------------------------------------------------------------

    public function testGelirOlayiSozlesmesiVerifiedGonderilmez(): void
    {
        $transport = new FakeTransport();
        $client = $this->client($transport);
        $event = $client->trackRevenue([
            'transactionId' => 'GPA.1234-5678',
            'amountMinor' => 4999,
            'currency' => 'TRY',
            'productId' => 'pro_monthly',
            'quantity' => 2,
            'purchaseType' => 'subscription_start',
            'receipt' => ['provider' => 'google', 'token' => 'tok_1'],
            'properties' => ['verified' => true, 'receipt_provider' => 'apple', 'verification' => 'x', 'plan' => 'pro', 'amount_minor' => 1],
        ], ['userId' => 'u1']);
        self::assertNotNull($event);
        self::assertSame('feralin_purchase', Revenue::EVENT_NAME);
        $client->flush();
        $sent = self::sentEvents($transport)[0];
        self::assertSame('feralin_purchase', $sent['event_name']);
        self::assertSame('u1', $sent['user_id']);
        self::assertSame([
            'transaction_id' => 'GPA.1234-5678',
            'amount_minor' => 4999,
            'currency' => 'TRY',
            'quantity' => 2,
            'purchase_type' => 'subscription_start',
            'product_id' => 'pro_monthly',
            'receipt' => ['provider' => 'google', 'token' => 'tok_1'],
            'plan' => 'pro',
        ], $sent['properties']);
        self::assertStringNotContainsString('verified', $transport->calls[0]['body']);

        // Varsayılanlar: adet 1, tür purchase; abonelik iptali yalnız sıfır tutarla.
        $plain = $client->trackRevenue(['transactionId' => 't2', 'amountMinor' => 0, 'currency' => 'USD', 'purchaseType' => 'subscription_cancel']);
        self::assertSame(1, $plain['properties']['quantity']);
        self::assertSame('subscription_cancel', $plain['properties']['purchase_type']);
        self::assertSame('purchase', $client->trackRevenue(['transactionId' => 't3', 'amountMinor' => 100, 'currency' => 'EUR'])['properties']['purchase_type']);
    }

    public function testGecersizGelirGirdisiOlayUretmezFirlatmaz(): void
    {
        $transport = new FakeTransport();
        $client = $this->client($transport);
        $base = ['transactionId' => 't1', 'amountMinor' => 100, 'currency' => 'TRY'];
        $invalid = [
            ['transactionId' => ''], ['transactionId' => str_repeat('x', 129)], ['transactionId' => 12],
            ['amountMinor' => 49.99], ['amountMinor' => '4999'], ['amountMinor' => -1], ['amountMinor' => Revenue::MAX_AMOUNT_MINOR + 1], ['amountMinor' => true],
            ['currency' => 'try'], ['currency' => 'TRYY'], ['currency' => null],
            ['productId' => ''], ['productId' => str_repeat('p', 129)],
            ['quantity' => -1], ['quantity' => 100001], ['quantity' => 1.5],
            ['purchaseType' => 'refund'], ['purchaseType' => 'subscription_cancel'],
            ['receipt' => ['provider' => 'paypal', 'token' => 't']], ['receipt' => ['provider' => 'apple', 'token' => '']],
            ['receipt' => ['provider' => 'apple', 'token' => str_repeat('t', 8193)]], ['receipt' => 'apple'],
            ['properties' => 'x'],
        ];
        foreach ($invalid as $override) {
            self::assertNull($client->trackRevenue($override + $base), (string) json_encode($override));
        }
        self::assertNull($client->trackRevenue([]));
        self::assertSame(0, $client->flush()->sent);
        self::assertNotNull($client->trackRevenue(['amountMinor' => Revenue::MAX_AMOUNT_MINOR, 'quantity' => 100000] + $base));
    }

    // --- Hata yakalama (fr_error) ------------------------------------------------------------------------------

    private static function failingCall(string $message): Throwable
    {
        try {
            (static function () use ($message): void {
                throw new RuntimeException($message);
            })();
        } catch (Throwable $error) {
            return $error;
        }
        throw new \LogicException('ulaşılamaz');
    }

    public function testHataOlayiSozlesmesiHamYiginVeKisiselVeriGitmez(): void
    {
        $transport = new FakeTransport();
        $client = $this->client($transport, ['appVersion' => '1.4.2']);
        $error = self::failingCall('Sipariş 1234567 başarısız: ali@example.com https://shop.test/o?token=abc 9f8e7d6c5b4a39281706f5e4d3c2b1a0');
        $event = $client->captureError($error, ['userId' => 'u1']);
        self::assertNotNull($event);
        $client->flush();
        $body = str_replace('\\/', '/', $transport->calls[0]['body']);
        $sent = self::sentEvents($transport)[0];
        self::assertSame('fr_error', $sent['event_name']);
        self::assertSame('u1', $sent['user_id']);
        $props = $sent['properties'];
        self::assertSame('RuntimeException', $props['error_type']);
        self::assertSame('Sipariş [num] başarısız: [email] [url] [token]', $props['message']);
        self::assertMatchesRegularExpression('/^[0-9a-f]{32}$/', $props['fingerprint']);
        self::assertStringContainsString('{closure}', $props['top_frame']);
        self::assertGreaterThan(0, $props['frame_count']);
        self::assertSame('1.4.2', $props['app_version']);
        self::assertTrue($props['handled']);
        self::assertFalse($props['fatal']);
        self::assertSame('handled', $props['origin']);
        self::assertNotEmpty($props['frames']);
        self::assertLessThanOrEqual(5, count($props['frames']));
        foreach ($props['frames'] as $frame) {
            self::assertMatchesRegularExpression('/^[A-Za-z0-9._~-]{1,128}$/', $frame['file']);
            self::assertGreaterThanOrEqual(1, $frame['line']);
            self::assertSame(0, $frame['column']);
            self::assertLessThanOrEqual(60, mb_strlen($frame['function'] ?? ''));
        }
        self::assertSame('ClientTest.php', $props['frames'][0]['file']);
        // Sözleşme dışı alan yok: toplayıcının izin listesiyle aynı.
        self::assertSame([], array_diff(array_keys($props), ['error_type', 'message', 'fingerprint', 'top_frame', 'frame_count', 'app_version', 'handled', 'fatal', 'origin', 'frames']));
        foreach (['ali@example.com', 'shop.test', 'token=abc', str_replace('\\', '/', __DIR__), '/vendor/', '#0 '] as $leak) {
            self::assertStringNotContainsString($leak, $body, $leak);
        }
    }

    public function testHataParmakIziKararliVeMesajdanBagimsiz(): void
    {
        $client = $this->client(new FakeTransport());
        $first = $client->captureError(self::failingCall('kullanıcı 1 için hata'));
        $second = $client->captureError(self::failingCall('kullanıcı 2 için hata'));
        self::assertSame($first['properties']['fingerprint'], $second['properties']['fingerprint']);
        $other = $client->captureError(new \InvalidArgumentException('başka'));
        self::assertNotSame($first['properties']['fingerprint'], $other['properties']['fingerprint']);
        self::assertSame('InvalidArgumentException', $other['properties']['error_type']);
    }

    public function testHataSiniriParmakIziBasinaVePencereBasina(): void
    {
        $now = 1_700_000_000_000;
        $transport = new FakeTransport();
        $client = $this->client($transport, ['now' => static function () use (&$now): int {
            return $now;
        }]);
        $error = self::failingCall('aynı');
        $accepted = 0;
        for ($i = 0; $i < 5; $i++) {
            $accepted += $client->captureError($error) !== null ? 1 : 0;
        }
        self::assertSame(3, $accepted, 'aynı parmak izi için en çok 3');
        $now += 60_000;
        self::assertNotNull($client->captureError($error), 'yeni pencerede yeniden izin');

        // Toplam sınır: pencere başına en çok 20 olay (farklı parmak izleri).
        $limiter = new ErrorLimiter();
        $allowed = 0;
        for ($i = 0; $i < 30; $i++) {
            $allowed += $limiter->allow('fp' . $i, 1000, 0.0) ? 1 : 0;
        }
        self::assertSame(20, $allowed);
        self::assertTrue($limiter->allow('fp_yeni', 61_000, 0.0));
    }

    public function testHataIzinOrneklemeVeKaynak(): void
    {
        $transport = new FakeTransport();
        $denied = new Client(self::KEY, self::URL, ['transport' => $transport, 'flushOnShutdown' => false]);
        self::assertNull($denied->captureError(new RuntimeException('x')));

        $client = $this->client($transport);
        self::assertNull($client->captureError(new RuntimeException('x'), ['origin' => 'window_onerror']));
        $fatal = $client->captureError(new RuntimeException('x'), ['origin' => 'uncaught_exception']);
        self::assertTrue($fatal['properties']['fatal']);
        self::assertFalse($fatal['properties']['handled']);
        self::assertSame('uncaught_exception', $fatal['properties']['origin']);
        self::assertTrue($client->captureError(new \LogicException('y'), ['origin' => 'manual'])['properties']['handled']);

        // Örnekleme: rastgele değer orandan büyükse olay üretilmez.
        $sampled = $this->client($transport, ['errorSampleRate' => 0.5, 'random' => static fn (): float => 0.9]);
        self::assertNull($sampled->captureError(new RuntimeException('z')));
    }

    public function testHataMesajiTemizligiToplayiciylaAyni(): void
    {
        self::assertSame('[email] yazdı', ErrorCapture::scrub('ali.veli@example.com yazdı'));
        self::assertSame('bkz [url]', ErrorCapture::scrub("bkz   https://x.test/a?b=c\n"));
        self::assertSame('kimlik [id]', ErrorCapture::scrub('kimlik 123e4567-e89b-12d3-a456-426614174000'));
        self::assertSame('sürüm 1.4.2 tel [num]', ErrorCapture::scrub('sürüm 1.4.2 tel +90 (555) 123-4567'));
        self::assertSame('UnsupportedOperationExceptionHandler', ErrorCapture::scrub('UnsupportedOperationExceptionHandler'));
        self::assertSame(200, mb_strlen(ErrorCapture::scrub(str_repeat('ğ', 500))));
        self::assertSame('bozuk ?', ErrorCapture::scrub("bozuk \xff"));
    }

    public function testAnonimSinifAdiYolTasimaz(): void
    {
        $error = new class ('x') extends RuntimeException {
        };
        $props = ErrorCapture::properties($error, ErrorCapture::ORIGIN_HANDLED, false);
        self::assertSame('RuntimeException@anonymous', $props['error_type']);
        self::assertStringNotContainsString(str_replace('\\', '/', __DIR__), str_replace('\\', '/', (string) json_encode($props, JSON_UNESCAPED_SLASHES)));
    }
}
