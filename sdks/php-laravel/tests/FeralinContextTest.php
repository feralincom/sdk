<?php

declare(strict_types=1);

namespace Feralin\Laravel\Tests;

use Feralin\Client;
use Feralin\Consent;
use Feralin\Laravel\ConsentResolver;
use Feralin\Laravel\Facades\Feralin;
use Feralin\Laravel\FeralinServiceProvider;
use Feralin\Laravel\Http\Middleware\FeralinContext;
use Feralin\Laravel\IdentityResolver;
use Feralin\Laravel\RequestFeralinFactory;
use Feralin\Transport;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use Orchestra\Testbench\TestCase;
use RuntimeException;

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

final class HeaderConsent implements ConsentResolver
{
    public function resolve(Request $request): ?Consent
    {
        return new Consent($request->header('X-Izin') === 'evet', $request->header('X-Reklam') === 'evet');
    }
}

final class BrokenConsent implements ConsentResolver
{
    public function resolve(Request $request): ?Consent
    {
        throw new RuntimeException('CMP yok');
    }
}

final class HeaderIdentity implements IdentityResolver
{
    public function resolve(Request $request): array
    {
        return ['userId' => (string) $request->header('X-Kullanici')];
    }
}

/** PHP bu makinede yok: bu test dosyası yazıldı, ÇALIŞTIRILMADI. */
final class FeralinContextTest extends TestCase
{
    private RecordingTransport $transport;

    protected function getPackageProviders($app): array
    {
        return [FeralinServiceProvider::class];
    }

    protected function defineEnvironment($app): void
    {
        $this->transport = new RecordingTransport();
        $app['config']->set('feralin.project_key', 'pk_test_laravel_unit_01');
        $app['config']->set('feralin.collect_url', 'http://collector.test');
        $app['config']->set('feralin.consent_resolver', HeaderConsent::class);
        $app['config']->set('feralin.identity_resolver', HeaderIdentity::class);
        $app['config']->set('feralin.client', ['transport' => $this->transport, 'flushOnShutdown' => false]);
    }

    protected function defineRoutes($router): void
    {
        Route::middleware(FeralinContext::class)->get('/siparis', static fn () => response()->json([
            'event' => Feralin::track('order_completed', ['order_id' => 'o1', 'fr_click' => 'clk_1']),
        ]));
        Route::middleware(FeralinContext::class)->get('/odeme', static fn () => response()->json([
            'revenue' => Feralin::trackRevenue(['transactionId' => 'ord_1', 'amountMinor' => 4999, 'currency' => 'TRY']),
            'invalid' => Feralin::trackRevenue(['transactionId' => 'ord_1', 'amountMinor' => 49.99, 'currency' => 'TRY']),
            'group' => Feralin::group('acme', ['plan' => 'team']),
            'user' => Feralin::setUserProperties(['plan' => 'pro', 'email' => 'a@b.co']),
            'error' => Feralin::captureError(new RuntimeException('hata')),
        ]));
    }

    public function testIzinYokkenOlayUretilmez(): void
    {
        $this->getJson('/siparis')->assertOk()->assertJson(['event' => null]);
        $this->assertSame([], $this->transport->calls);
    }

    public function testIzinKimlikVeTemizBaglamGecer(): void
    {
        $response = $this->getJson('/siparis?token=GIZLI', ['X-Izin' => 'evet', 'X-Reklam' => 'evet', 'X-Kullanici' => 'user_42', 'Referer' => 'https://ref.example.test/a?b=GIZLI']);
        $event = $response->assertOk()->json('event');
        $this->assertSame('clk_1', $event['properties']['fr_click']);
        $this->assertSame('user_42', $event['user_id']);
        $this->assertSame('https://ref.example.test', $event['context']['referrer']);
        $this->assertStringNotContainsString('GIZLI', json_encode($event));
    }

    public function testReklamIzniYoksaFrClickCikarilir(): void
    {
        $event = $this->getJson('/siparis', ['X-Izin' => 'evet'])->json('event');
        $this->assertArrayNotHasKey('fr_click', $event['properties']);
    }

    public function testKuyrukGonderilir(): void
    {
        $this->getJson('/siparis', ['X-Izin' => 'evet'])->assertOk();
        $this->app->make(Client::class)->flush();
        $this->assertCount(1, $this->transport->calls);
        $this->assertSame('http://collector.test/v1/batch', $this->transport->calls[0]['url']);
    }

    public function testAnahtarBoskenEntegrasyonKapaliIstekEtkilenmez(): void
    {
        foreach (['', null] as $key) {
            $this->app['config']->set('feralin.project_key', $key);
            $this->app->forgetInstance(Client::class);
            $this->app->forgetInstance(RequestFeralinFactory::class);
            $this->getJson('/siparis', ['X-Izin' => 'evet'])->assertOk()->assertJson(['event' => null]);
            // terminate istemci kurmaya çalışıp InvalidArgumentException atmamalı.
            $this->app->make(FeralinContext::class)->terminate(Request::create('/siparis'), response('ok'));
            $this->assertFalse($this->app->resolved(Client::class));
        }
        $this->assertSame([], $this->transport->calls);
    }

    public function testTerminateKuyruguGonderir(): void
    {
        $this->getJson('/siparis', ['X-Izin' => 'evet'])->assertOk();
        $this->app->make(FeralinContext::class)->terminate(Request::create('/siparis'), response('ok'));
        $this->assertCount(1, $this->transport->calls);
    }

    public function testSaldirganBaslikBatchDusurmezIstekEtkilenmez(): void
    {
        $event = $this->getJson('/siparis', ['X-Izin' => 'evet', 'Referer' => 'https://' . str_repeat('r', 3000) . '.example.test/'])->assertOk()->json('event');
        $this->assertArrayNotHasKey('referrer', $event['context']);
        $this->assertArrayHasKey('page_url', $event['context']);
    }

    public function testGelirGrupKullaniciOzelligiVeHataIsteginIzniVeKimligiyleGider(): void
    {
        $json = $this->getJson('/odeme', ['X-Izin' => 'evet', 'X-Kullanici' => 'user_42'])->assertOk()->json();
        $this->assertSame('feralin_purchase', $json['revenue']['event_name']);
        $this->assertSame('user_42', $json['revenue']['user_id']);
        $this->assertSame(4999, $json['revenue']['properties']['amount_minor']);
        $this->assertNull($json['invalid']);
        $this->assertSame('fr_group', $json['group']['event_name']);
        $this->assertSame(['plan' => 'pro'], $json['user']['properties']);
        $this->assertSame('fr_error', $json['error']['event_name']);
        $this->assertSame('user_42', $json['error']['user_id']);

        $denied = $this->getJson('/odeme')->assertOk()->json();
        $this->assertNull($denied['revenue']);
        $this->assertNull($denied['error']);
    }

    public function testCozumleyiciHatasiIzinYokSayilir(): void
    {
        $this->app['config']->set('feralin.consent_resolver', BrokenConsent::class);
        $this->app->forgetInstance(RequestFeralinFactory::class);
        $this->getJson('/siparis', ['X-Izin' => 'evet'])->assertOk()->assertJson(['event' => null]);
    }
}
