<?php

declare(strict_types=1);

namespace Feralin\WordPress\Tests;

use FakeOrder;
use FakeOrders;
use Feralin_Frontend;
use Feralin_Settings;
use Feralin_WooCommerce;
use PHPUnit\Framework\TestCase;
use WpStub;

/**
 * Eklenti birim testleri (WordPress çekirdeği yok, ince saplar). Sipariş olayı gerçek PHP SDK'sı ve yerel sahte toplayıcıyla
 * (php -S) uçtan uca koşar. Gerçek WordPress/WooCommerce kurulumunda çalıştığını KANITLAMAZ.
 */
final class PluginTest extends TestCase
{
    /** @var resource|null */
    private $server = null;
    private string $log = '';
    private string $mode = '';
    private string $collectUrl = '';

    protected function setUp(): void
    {
        WpStub::reset();
        FakeOrders::$orders = [];
        $this->log = tempnam(sys_get_temp_dir(), 'feralin-log') ?: '';
        $this->mode = tempnam(sys_get_temp_dir(), 'feralin-mode') ?: '';
        file_put_contents($this->mode, '202');
    }

    protected function tearDown(): void
    {
        if (is_resource($this->server)) {
            proc_terminate($this->server);
            proc_close($this->server);
            $this->server = null;
        }
        foreach ([$this->log, $this->mode] as $file) {
            if ($file !== '' && file_exists($file)) {
                unlink($file);
            }
        }
    }

    /** Sahte toplayıcıyı boş bir portta başlatır. */
    private function startCollector(): void
    {
        $probe = stream_socket_server('tcp://127.0.0.1:0');
        $name = stream_socket_get_name($probe, false);
        fclose($probe);
        $port = (int) substr((string) strrchr((string) $name, ':'), 1);
        $this->collectUrl = 'http://127.0.0.1:' . $port;
        $env = ['FERALIN_FAKE_LOG' => $this->log, 'FERALIN_FAKE_MODE' => $this->mode] + (array) getenv();
        $process = proc_open([PHP_BINARY, '-S', '127.0.0.1:' . $port, __DIR__ . '/collector-router.php'], [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes, null, $env);
        $this->assertIsResource($process);
        $this->server = $process;
        for ($i = 0; $i < 50; $i++) {
            $socket = @fsockopen('127.0.0.1', $port, $errno, $error, 0.1);
            if ($socket) {
                fclose($socket);
                return;
            }
            usleep(100_000);
        }
        $this->fail('sahte toplayıcı açılmadı');
    }

    /** @return list<array{path: string, key: string, body: string}> */
    private function received(): array
    {
        $lines = file($this->log, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
        return array_map(static fn (string $line): array => json_decode($line, true), $lines);
    }

    /** @param array<string, mixed> $overrides */
    private function configure(array $overrides = []): void
    {
        WpStub::$options['feralin_settings'] = $overrides + [
            'project_key' => 'pk_test_wordpress_0001',
            'collect_url' => $this->collectUrl ?: 'http://127.0.0.1:9',
            'frontend_enabled' => true,
            'woocommerce_enabled' => true,
        ];
    }

    // --- Ayarlar -----------------------------------------------------------------------------------------------

    public function testVarsayilanlarKapali(): void
    {
        $settings = Feralin_Settings::get();
        $this->assertSame('', $settings['project_key']);
        $this->assertFalse($settings['frontend_enabled']);
        $this->assertFalse($settings['woocommerce_enabled']);
    }

    public function testGizliAnahtarReddedilirOncekiDegerKorunur(): void
    {
        WpStub::$options['feralin_settings'] = ['project_key' => 'pk_test_onceki_01', 'collect_url' => 'https://collect.example.com'];
        $saved = Feralin_Settings::sanitize(['project_key' => 'sk_live_gizli_anahtar', 'collect_url' => 'https://collect.example.com']);
        $this->assertSame('pk_test_onceki_01', $saved['project_key']);
        $this->assertSame('feralin_secret_key', WpStub::$settingErrors[0]['code']);
        $this->assertStringNotContainsString('sk_live', json_encode($saved));
    }

    public function testGecersizAnahtarVeAdresKaydedilmez(): void
    {
        $saved = Feralin_Settings::sanitize(['project_key' => 'abc', 'collect_url' => 'ftp://x.example.com']);
        $this->assertSame('', $saved['project_key']);
        $this->assertSame('', $saved['collect_url']);
        $this->assertSame(['feralin_invalid_key'], array_column(WpStub::$settingErrors, 'code'));
    }

    public function testGecerliAnahtarVeAdresKaydedilirSonEgikCizgiKirpilir(): void
    {
        $saved = Feralin_Settings::sanitize(['project_key' => ' pk_live_abc123 ', 'collect_url' => 'https://collect.example.com/', 'frontend_enabled' => '1']);
        $this->assertSame('pk_live_abc123', $saved['project_key']);
        $this->assertSame('https://collect.example.com', $saved['collect_url']);
        $this->assertTrue($saved['frontend_enabled']);
        $this->assertFalse($saved['woocommerce_enabled']);
        $this->assertSame([], WpStub::$settingErrors);
        // Yerel geliştirme adresi kabul edilir.
        $local = Feralin_Settings::sanitize(['project_key' => 'pk_test_abc123', 'collect_url' => 'http://127.0.0.1:4701']);
        $this->assertSame('http://127.0.0.1:4701', $local['collect_url']);
    }

    public function testYonetimBildirimiYalnizYoneticiyeVeEksikDosyadaGorunur(): void
    {
        WpStub::$isAdmin = false;
        ob_start();
        Feralin_Settings::vendor_notice();
        $this->assertSame('', ob_get_clean());
        WpStub::$isAdmin = true;
        ob_start();
        Feralin_Settings::vendor_notice();
        $this->assertSame('', ob_get_clean(), 'paketlenmiş dosyalar varken bildirim yok');
        unlink(FERALIN_TEST_PLUGIN_DIR . 'assets/feralin.iife.js');
        ob_start();
        Feralin_Settings::vendor_notice();
        $this->assertStringContainsString('notice-error', (string) ob_get_clean());
        file_put_contents(FERALIN_TEST_PLUGIN_DIR . 'assets/feralin.iife.js', '/* sap */');
    }

    // --- Kanca kaydı -------------------------------------------------------------------------------------------

    public function testEklentiKancalariPluginsLoadedIleBaglanir(): void
    {
        // Eklenti dosyası yüklenirken yalnız plugins_loaded ve devre dışı bırakma kancası kaydedilir; gerisi o olayda bağlanır.
        $this->assertSame(['plugins_loaded', 'deactivate'], array_keys(WpStub::$boot));
        WpStub::$actions = WpStub::$boot;
        $this->configure();
        do_action('plugins_loaded');
        foreach (['admin_init', 'admin_menu', 'admin_notices', 'wp_enqueue_scripts', 'feralin_retry_pending', 'woocommerce_checkout_order_created', 'woocommerce_store_api_checkout_order_processed', 'woocommerce_order_status_completed'] as $hook) {
            $this->assertArrayHasKey($hook, WpStub::$actions, $hook);
        }
        $this->assertArrayHasKey('deactivate', WpStub::$actions);
    }

    public function testWooCommerceKapaliysaSiparisKancalariBaglanmaz(): void
    {
        WpStub::reset();
        $this->configure(['woocommerce_enabled' => false]);
        Feralin_WooCommerce::register();
        $this->assertArrayNotHasKey('woocommerce_order_status_completed', WpStub::$actions);
        $this->assertArrayHasKey('feralin_retry_pending', WpStub::$actions);
    }

    public function testKapatmaZamanlanmisDenemeyiKaldirir(): void
    {
        WpStub::$scheduled[] = ['hook' => 'feralin_retry_pending', 'time' => time() + 60];
        Feralin_WooCommerce::unschedule();
        $this->assertSame(['feralin_retry_pending'], WpStub::$clearedHooks);
        $this->assertFalse(wp_next_scheduled('feralin_retry_pending'));
    }

    // --- Ön yüz ------------------------------------------------------------------------------------------------

    public function testOnYuzVarsayilanOlarakBetikEklemez(): void
    {
        Feralin_Frontend::enqueue();
        $this->assertSame([], WpStub::$scripts);
    }

    public function testOnYuzAyarlarTamsaBetikVeBaslangicKodunuEkler(): void
    {
        $this->configure(['collect_url' => 'https://collect.example.com']);
        Feralin_Frontend::enqueue();
        $this->assertCount(1, WpStub::$scripts);
        $this->assertSame('feralin-web', WpStub::$scripts[0]['handle']);
        $this->assertSame('defer', WpStub::$scripts[0]['args']['strategy']);
        $code = WpStub::$inline[0]['code'];
        $this->assertStringContainsString('"projectKey":"pk_test_wordpress_0001"', $code);
        $this->assertStringContainsString('"collectUrl":"https://collect.example.com"', $code);
        // Karar yoksa izin verilmez: yalnız WP Consent API varsa consent okunur.
        $this->assertStringContainsString('wp_has_consent', $code);
        $this->assertStringNotContainsString('analytics: true', $code);
    }

    public function testOnYuzOnizlemedeVeAnahtarsizdaYuklenmez(): void
    {
        $this->configure(['collect_url' => 'https://collect.example.com']);
        WpStub::$preview = true;
        Feralin_Frontend::enqueue();
        $this->assertSame([], WpStub::$scripts);
        WpStub::$preview = false;
        $this->configure(['project_key' => '']);
        Feralin_Frontend::enqueue();
        $this->assertSame([], WpStub::$scripts);
    }

    public function testOnYuzPaketlenmisBetikYoksaSessizceYuklemez(): void
    {
        $this->configure(['collect_url' => 'https://collect.example.com']);
        unlink(FERALIN_TEST_PLUGIN_DIR . 'assets/feralin.iife.js');
        Feralin_Frontend::enqueue();
        file_put_contents(FERALIN_TEST_PLUGIN_DIR . 'assets/feralin.iife.js', '/* sap */');
        $this->assertSame([], WpStub::$scripts);
    }

    // --- Sipariş olayı -----------------------------------------------------------------------------------------

    public function testOdemeAnindakiIzinSiparisteSaklanirYoksaYazilmaz(): void
    {
        $this->configure();
        $order = new FakeOrder();
        Feralin_WooCommerce::record_consent($order);
        $this->assertSame([], $order->meta, 'izin kaynağı yoksa hiçbir şey yazılmaz');

        add_filter('feralin_checkout_consent', static fn ($consent) => ['analytics' => true, 'advertising' => false]);
        Feralin_WooCommerce::record_consent($order);
        $this->assertSame(['analytics' => true, 'advertising' => false], $order->meta['_feralin_consent']);
    }

    public function testIzinYoksaSiparisOlayiGonderilmezVeAgaCikilmaz(): void
    {
        $this->startCollector();
        $this->configure();
        FakeOrders::$orders[77] = new FakeOrder();
        Feralin_WooCommerce::order_completed(77);
        $this->assertSame([], $this->received());
        $this->assertArrayNotHasKey('_feralin_tracked', FakeOrders::$orders[77]->meta);

        FakeOrders::$orders[78] = new FakeOrder(78);
        FakeOrders::$orders[78]->meta['_feralin_consent'] = ['analytics' => false, 'advertising' => false];
        Feralin_WooCommerce::order_completed(78);
        $this->assertSame([], $this->received());
    }

    public function testIzinliSiparisBirKezGonderilirKisiselVeriYoktur(): void
    {
        $this->startCollector();
        $this->configure();
        $order = new FakeOrder(91, 249.5, 'TRY', 2, 15);
        $order->meta['_feralin_consent'] = ['analytics' => true, 'advertising' => false];
        FakeOrders::$orders[91] = $order;
        add_filter('feralin_order_event_properties', static fn (array $properties) => $properties + ['fr_click' => 'clk_wp_1']);

        Feralin_WooCommerce::order_completed(91);
        $requests = $this->received();
        $this->assertCount(1, $requests);
        $this->assertSame('pk_test_wordpress_0001', $requests[0]['key']);
        $this->assertSame('/v1/batch', $requests[0]['path']);
        $payload = json_decode($requests[0]['body'], true);
        $event = $payload['events'][0];
        $this->assertSame('feralin_purchase', $event['event_name']);
        // Gelir sözleşmesi (trackRevenue): küçük birimde tam sayı, webhook ile aynı işlem kimliği, doğrulama alanı yok.
        $this->assertSame('woo:order:91', $event['properties']['transaction_id']);
        $this->assertSame(24950, $event['properties']['amount_minor']);
        $this->assertSame('TRY', $event['properties']['currency']);
        $this->assertSame(2, $event['properties']['quantity']);
        $this->assertSame('purchase', $event['properties']['purchase_type']);
        $this->assertSame('91', $event['properties']['order_id']);
        $this->assertSame('woocommerce', $event['properties']['source']);
        $this->assertArrayNotHasKey('value', $event['properties']);
        $this->assertStringNotContainsString('verified', $requests[0]['body']);
        // Reklam izni yok: SDK fr_click'i çıkarır.
        $this->assertArrayNotHasKey('fr_click', $event['properties']);
        // Ham WordPress kullanıcı kimliği değil, site tuzuyla türetilmiş takma ad.
        $this->assertMatchesRegularExpression('/^wp_[0-9a-f]{32}$/', $event['user_id']);
        $this->assertStringNotContainsString('"15"', $requests[0]['body']);
        foreach (['email', 'first_name', 'address', 'phone'] as $pii) {
            $this->assertStringNotContainsString($pii, $requests[0]['body']);
        }
        $this->assertNotEmpty($order->meta['_feralin_tracked']);

        // Aynı sipariş ikinci kez gönderilmez.
        Feralin_WooCommerce::order_completed(91);
        $this->assertCount(1, $this->received());
    }

    public function testReklamIzniVarsaTiklamaKimligiTasinir(): void
    {
        $this->startCollector();
        $this->configure();
        $order = new FakeOrder(92);
        $order->meta['_feralin_consent'] = ['analytics' => true, 'advertising' => true];
        FakeOrders::$orders[92] = $order;
        add_filter('feralin_order_event_properties', static fn (array $properties) => $properties + ['fr_click' => 'clk_wp_2']);
        Feralin_WooCommerce::order_completed(92);
        $event = json_decode($this->received()[0]['body'], true)['events'][0];
        $this->assertSame('clk_wp_2', $event['properties']['fr_click']);
    }

    public function testSiparisTutariParaBirimiBasamagiylaKucukBirimeCevrilirGecersizseOlayYok(): void
    {
        $this->startCollector();
        $this->configure();
        $cases = [
            [101, 1500.0, 'JPY', 1500],
            [102, 12.345, 'KWD', 12345],
            [103, 0.1 + 0.2, 'USD', 30],
            [104, 19.99, 'EUR', 1999],
        ];
        foreach ($cases as [$id, $total, $currency, $expected]) {
            $order = new FakeOrder($id, $total, $currency, 1);
            $order->meta['_feralin_consent'] = ['analytics' => true, 'advertising' => false];
            FakeOrders::$orders[$id] = $order;
            Feralin_WooCommerce::order_completed($id);
            $requests = $this->received();
            $event = json_decode($requests[count($requests) - 1]['body'], true)['events'][0];
            $this->assertSame($expected, $event['properties']['amount_minor'], $currency);
            $this->assertSame($currency, $event['properties']['currency']);
        }
        $count = count($this->received());
        foreach ([[110, -5.0, 'TRY'], [111, 10.0, 'TL'], [112, 10.0, '']] as [$id, $total, $currency]) {
            $order = new FakeOrder($id, $total, $currency);
            $order->meta['_feralin_consent'] = ['analytics' => true, 'advertising' => false];
            FakeOrders::$orders[$id] = $order;
            Feralin_WooCommerce::order_completed($id);
            $this->assertArrayNotHasKey('_feralin_tracked', $order->meta);
        }
        $this->assertCount($count, $this->received());
    }

    public function testSuzgecGelirSozlesmesiniVeDogrulamaAlaniniDegistiremez(): void
    {
        $this->startCollector();
        $this->configure();
        $order = new FakeOrder(120, 10.0, 'TRY', 1);
        $order->meta['_feralin_consent'] = ['analytics' => true, 'advertising' => false];
        FakeOrders::$orders[120] = $order;
        add_filter('feralin_order_event_properties', static fn (array $properties) => ['amount_minor' => 1, 'transaction_id' => 'x', 'verified' => true, 'kampanya' => 'yaz'] + $properties);
        Feralin_WooCommerce::order_completed(120);
        $event = json_decode($this->received()[0]['body'], true)['events'][0];
        $this->assertSame(1000, $event['properties']['amount_minor']);
        $this->assertSame('woo:order:120', $event['properties']['transaction_id']);
        $this->assertSame('yaz', $event['properties']['kampanya']);
        $this->assertArrayNotHasKey('verified', $event['properties']);
    }

    public function testGeciciHatadaOlayBekleyenSecenegeYazilirVeCronKurulurSonraAyniKimlikleGonderilir(): void
    {
        $this->startCollector();
        $this->configure();
        file_put_contents($this->mode, '503');
        $order = new FakeOrder(93);
        $order->meta['_feralin_consent'] = ['analytics' => true, 'advertising' => false];
        FakeOrders::$orders[93] = $order;

        Feralin_WooCommerce::order_completed(93);
        $first = json_decode($this->received()[0]['body'], true)['events'][0];
        $pending = WpStub::$options['feralin_pending_events'] ?? [];
        $this->assertCount(1, $pending);
        $this->assertNotFalse(wp_next_scheduled('feralin_retry_pending'));
        $this->assertSame(1, WpStub::$options['feralin_retry_attempt']);

        // Toplayıcı düzelir; cron aynı event_id ile yeniden dener ve bekleyen kayıt temizlenir.
        file_put_contents($this->mode, '202');
        Feralin_WooCommerce::retry_pending();
        $requests = $this->received();
        $this->assertCount(2, $requests);
        $second = json_decode($requests[1]['body'], true)['events'][0];
        $this->assertSame($first['event_id'], $second['event_id']);
        $this->assertArrayNotHasKey('feralin_pending_events', WpStub::$options);
        $this->assertArrayNotHasKey('feralin_retry_attempt', WpStub::$options);
    }

    public function testToplayiciYoksaSiparisAkisiHatayaDusmez(): void
    {
        $this->configure(['collect_url' => 'http://127.0.0.1:9']);
        $order = new FakeOrder(94);
        $order->meta['_feralin_consent'] = ['analytics' => true, 'advertising' => false];
        FakeOrders::$orders[94] = $order;
        Feralin_WooCommerce::order_completed(94);
        $this->assertNotFalse(wp_next_scheduled('feralin_retry_pending'));
        // Anahtarsız ayar: SDK istemcisi kurulmaz, hiçbir şey olmaz.
        WpStub::reset();
        $this->configure(['project_key' => '']);
        Feralin_WooCommerce::order_completed(94);
        $this->assertSame([], WpStub::$scheduled);
    }

    public function testBekleyenKuyrukSinirlidir(): void
    {
        $this->configure(['collect_url' => 'http://127.0.0.1:9']);
        for ($id = 200; $id < 203; $id++) {
            $order = new FakeOrder($id);
            $order->meta['_feralin_consent'] = ['analytics' => true, 'advertising' => false];
            FakeOrders::$orders[$id] = $order;
            Feralin_WooCommerce::order_completed($id);
        }
        $this->assertLessThanOrEqual(500, count(WpStub::$options['feralin_pending_events']));
        // Cron aynı anda tek kez kurulur.
        $this->assertCount(1, array_filter(WpStub::$scheduled, static fn (array $item): bool => $item['hook'] === 'feralin_retry_pending'));
    }

    public function testKaldirmaYalnizKendiSecenekleriniSiler(): void
    {
        WpStub::$options = ['feralin_settings' => ['x' => 1], 'feralin_pending_events' => ['a'], 'baska_eklenti' => 'kalir'];
        define('WP_UNINSTALL_PLUGIN', true);
        require FERALIN_TEST_PLUGIN_DIR . 'uninstall.php';
        $this->assertSame(['baska_eklenti' => 'kalir'], WpStub::$options);
    }
}
