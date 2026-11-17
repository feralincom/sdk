<?php

declare(strict_types=1);

namespace Feralin\Symfony\Tests;

use Feralin\Client;
use Feralin\Consent;
use Feralin\Symfony\ConsentResolverInterface;
use Feralin\Symfony\EventSubscriber\FeralinSubscriber;
use Feralin\Symfony\IdentityResolverInterface;
use Feralin\Symfony\RequestFeralin;
use Feralin\Symfony\ValueResolver\RequestFeralinResolver;
use Feralin\Transport;
use PHPUnit\Framework\TestCase;
use RuntimeException;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\ControllerMetadata\ArgumentMetadata;

final class RecordingTransport implements Transport
{
    /** @var list<array{url: string, body: string, headers: array<string, string>}> */
    public array $calls = [];

    public function post(string $url, string $body, array $headers, float $timeoutSeconds): array
    {
        $this->calls[] = ['url' => $url, 'body' => $body, 'headers' => $headers];
        return ['status' => 202, 'body' => '{"batch_id":"b1","accepted":1,"rejected":0}'];
    }
}

/** PHP bu makinede yok: bu test dosyası yazıldı, ÇALIŞTIRILMADI. */
final class FeralinSubscriberTest extends TestCase
{
    private RecordingTransport $transport;
    private Client $client;

    protected function setUp(): void
    {
        $this->transport = new RecordingTransport();
        $this->client = new Client('pk_test_symfony_unit_01', 'http://collector.test', ['transport' => $this->transport, 'flushOnShutdown' => false]);
    }

    private function consentFromHeader(): ConsentResolverInterface
    {
        return new class () implements ConsentResolverInterface {
            public function resolve(Request $request): ?Consent
            {
                return new Consent($request->headers->get('X-Izin') === 'evet', $request->headers->get('X-Reklam') === 'evet');
            }
        };
    }

    public function testIzinYokkenOlayUretilmez(): void
    {
        $subscriber = new FeralinSubscriber($this->client, $this->consentFromHeader());
        $this->assertNull($subscriber->forRequest(Request::create('/siparis'))->track('order_completed'));
        $this->client->flush();
        $this->assertSame([], $this->transport->calls);
    }

    public function testCozumleyiciYoksaIzinYok(): void
    {
        $subscriber = new FeralinSubscriber($this->client);
        $this->assertNull($subscriber->forRequest(Request::create('/siparis'))->track('order_completed'));
    }

    public function testIzinKimlikVeTemizBaglamGecer(): void
    {
        $identity = new class () implements IdentityResolverInterface {
            public function resolve(Request $request): array
            {
                return ['userId' => 'user_42'];
            }
        };
        $subscriber = new FeralinSubscriber($this->client, $this->consentFromHeader(), $identity);
        $request = Request::create('https://uygulama.example.test/siparis?token=GIZLI', 'GET', [], [], [], ['HTTP_X_IZIN' => 'evet', 'HTTP_X_REKLAM' => 'evet', 'HTTP_REFERER' => 'https://ref.example.test/a?b=GIZLI', 'HTTP_ACCEPT_LANGUAGE' => 'tr-TR,tr;q=0.9']);
        $event = $subscriber->forRequest($request)->track('order_completed', ['fr_click' => 'clk_1']);
        $this->assertSame('clk_1', $event['properties']['fr_click']);
        $this->assertSame('user_42', $event['user_id']);
        $this->assertSame('https://uygulama.example.test/siparis', $event['context']['page_url']);
        $this->assertSame('https://ref.example.test', $event['context']['referrer']);
        $this->assertSame('tr-TR', $event['context']['locale']);
        $this->assertStringNotContainsString('GIZLI', json_encode($event));
    }

    public function testSaldirganBaslikBatchDusurmezIstekEtkilenmez(): void
    {
        $subscriber = new FeralinSubscriber($this->client, $this->consentFromHeader());
        $long = Request::create('https://uygulama.example.test/siparis', 'GET', [], [], [], ['HTTP_X_IZIN' => 'evet', 'HTTP_REFERER' => 'https://' . str_repeat('r', 3000) . '.example.test/']);
        $event = $subscriber->forRequest($long)->track('order_completed');
        $this->assertArrayNotHasKey('referrer', $event['context']);
        $this->assertSame('https://uygulama.example.test/siparis', $event['context']['page_url']);

        $badHost = Request::create('/siparis', 'GET', [], [], [], ['HTTP_X_IZIN' => 'evet']);
        $badHost->headers->set('host', 'a b');
        $event = $subscriber->forRequest($badHost)->track('order_completed');
        // Request::create varsayılan Accept-Language ekler; yalnız adres düşmeli.
        $this->assertNotNull($event);
        $this->assertArrayNotHasKey('page_url', $event['context'] ?? []);
    }

    public function testReklamIzniYoksaFrClickCikarilir(): void
    {
        $subscriber = new FeralinSubscriber($this->client, $this->consentFromHeader());
        $request = Request::create('/siparis', 'GET', [], [], [], ['HTTP_X_IZIN' => 'evet']);
        $event = $subscriber->forRequest($request)->track('order_completed', ['fr_click' => 'clk_1', 'order_id' => 'o1']);
        $this->assertSame(['order_id' => 'o1'], $event['properties']);
    }

    public function testCozumleyiciHatasiIzinYokSayilir(): void
    {
        $broken = new class () implements ConsentResolverInterface {
            public function resolve(Request $request): ?Consent
            {
                throw new RuntimeException('CMP yok');
            }
        };
        $subscriber = new FeralinSubscriber($this->client, $broken);
        $this->assertFalse($subscriber->forRequest(Request::create('/'))->consent->analytics);
    }

    public function testGelirGrupKullaniciOzelligiVeHataIsteginIzniVeKimligiyleGider(): void
    {
        $identity = new class () implements IdentityResolverInterface {
            public function resolve(Request $request): array
            {
                return ['userId' => 'user_42'];
            }
        };
        $subscriber = new FeralinSubscriber($this->client, $this->consentFromHeader(), $identity);
        $feralin = $subscriber->forRequest(Request::create('/odeme', 'GET', [], [], [], ['HTTP_X_IZIN' => 'evet']));
        $revenue = $feralin->trackRevenue(['transactionId' => 'ord_1', 'amountMinor' => 4999, 'currency' => 'TRY']);
        $this->assertSame('feralin_purchase', $revenue['event_name']);
        $this->assertSame('user_42', $revenue['user_id']);
        $this->assertSame(4999, $revenue['properties']['amount_minor']);
        $this->assertNull($feralin->trackRevenue(['transactionId' => 'ord_1', 'amountMinor' => 49.99, 'currency' => 'TRY']));
        $this->assertSame('fr_group', $feralin->group('acme', ['plan' => 'team'])['event_name']);
        $this->assertSame(['plan' => 'pro'], $feralin->setUserProperties(['plan' => 'pro', 'email' => 'a@b.co'])['properties']);
        $error = $feralin->captureError(new RuntimeException('hata'));
        $this->assertSame('fr_error', $error['event_name']);
        $this->assertSame('user_42', $error['user_id']);

        // İzinsiz istek: hiçbiri olay üretmez.
        $denied = $subscriber->forRequest(Request::create('/odeme'));
        $this->assertNull($denied->trackRevenue(['transactionId' => 'ord_2', 'amountMinor' => 1, 'currency' => 'TRY']));
        $this->assertNull($denied->captureError(new RuntimeException('hata')));
    }

    public function testDenetleyiciArgumaniCozulur(): void
    {
        $subscriber = new FeralinSubscriber($this->client, $this->consentFromHeader());
        $resolver = new RequestFeralinResolver($subscriber);
        $argument = new ArgumentMetadata('feralin', RequestFeralin::class, false, false, null);
        $values = [...$resolver->resolve(Request::create('/'), $argument)];
        $this->assertInstanceOf(RequestFeralin::class, $values[0]);
        $other = new ArgumentMetadata('x', 'string', false, false, null);
        $this->assertSame([], [...$resolver->resolve(Request::create('/'), $other)]);
    }
}
