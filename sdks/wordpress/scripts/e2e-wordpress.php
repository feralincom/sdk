<?php
/**
 * Gerçek WordPress + WooCommerce uçtan uca testinin PHP tarafı (scripts/sdk-e2e/targets/wordpress.mjs çağırır).
 *
 *   php e2e-wordpress.php install <wp_kökü> <site_adresi>
 *   php e2e-wordpress.php activate <wp_kökü>
 *   php e2e-wordpress.php settings <wp_kökü> <proje_anahtarı> <toplayıcı_adresi>
 *   php e2e-wordpress.php order <wp_kökü> <izin: yes|no>
 *
 * install: WordPress kurulur. activate: WooCommerce ve Feralin eklentisi gerçek etkinleştirme akışıyla açılır, ayarlar eklentinin kendi
 * Settings API temizleyicisinden geçerek yazılır (sk_ reddi de denenir). order: WooCommerce ürünü ve siparişi oluşturulur, ödeme anı
 * izni eklentinin `feralin_checkout_consent` süzgeciyle verilir, sipariş "tamamlandı" yapılır ve son satırda sipariş kimliği yazılır.
 * Olay eklentinin kendi kancasından (woocommerce_order_status_completed) PHP SDK ile toplayıcıya gider; betik olay göndermez.
 */

declare(strict_types=1);

[$self, $mode, $root] = array_pad($argv, 3, '');
if (!in_array($mode, ['install', 'activate', 'settings', 'order'], true) || !is_dir($root)) {
	fwrite(STDERR, "kullanım: php e2e-wordpress.php install|order <wp_kökü> ...\n");
	exit(2);
}

// Betik hataları WordPress'in WP_DEBUG_DISPLAY ayarından bağımsız olarak stderr'e yazılır.
set_exception_handler(static function (Throwable $e): void { fwrite(STDERR, 'HATA: ' . get_class($e) . ': ' . $e->getMessage() . ' @ ' . $e->getFile() . ':' . $e->getLine() . "
"); exit(1); });
register_shutdown_function(static function (): void { $e = error_get_last(); if ($e && in_array($e['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) fwrite(STDERR, "PHP: {$e['message']} @ {$e['file']}:{$e['line']}
"); });

function fail(string $message): never {
	fwrite(STDERR, "HATA: $message\n");
	exit(1);
}

if ($mode === 'install') {
	[, , , $siteUrl] = array_pad($argv, 4, '');
	define('WP_INSTALLING', true);
	require $root . '/wp-load.php';
	require_once ABSPATH . 'wp-admin/includes/upgrade.php';
	require_once ABSPATH . 'wp-admin/includes/plugin.php';
	// Test ortamında posta sunucusu yok: kurulum e-postası gönderilmez (pre_wp_mail kısa devresi), olay akışı etkilenmez.
	add_filter('pre_wp_mail', '__return_true');
	$password = bin2hex(random_bytes(16));
	$result = wp_install('Feralin E2E', 'feralin-e2e', 'e2e@example.test', true, '', $password, 'tr_TR');
	if (empty($result['user_id'])) fail('wp_install kullanıcı oluşturmadı');
	update_option('siteurl', $siteUrl);
	update_option('home', $siteUrl);
	echo "wordpress kuruldu\n";
	exit(0);
}

if ($mode === 'activate') {
	// Eklentiler kurulmuş sitede, normal yüklemede etkinleştirilir (yönetim panelindeki "Etkinleştir" ile aynı işlev).
	require $root . '/wp-load.php';
	require_once ABSPATH . 'wp-admin/includes/plugin.php';
	add_filter('pre_wp_mail', '__return_true');
	$admin = get_user_by('login', 'feralin-e2e');
	if (!$admin) fail('yönetici kullanıcı yok');
	wp_set_current_user($admin->ID);
	// WooCommerce şablon işlevlerini `after_setup_theme` sırasında yükler; eklenti o kancadan sonra etkinleştiği için ilk kurulum
	// olayındaki geri çağrı (wc_set_hooked_blocks_version) tanımsız kalır. Yalnız bu CLI akışında dosya kurulumdan önce yüklenir.
	add_action('woocommerce_newly_installed', static function (): void { require_once WC_ABSPATH . 'includes/wc-template-functions.php'; }, 1);
	foreach (['woocommerce/woocommerce.php', 'feralin/feralin.php'] as $plugin) {
		$error = activate_plugin($plugin);
		if (is_wp_error($error)) fail("$plugin etkinleşmedi: " . $error->get_error_message());
	}
	echo "eklentiler etkin\n";
	exit(0);
}

if ($mode === 'settings') {
	[, , , $projectKey, $collectUrl] = array_pad($argv, 5, '');
	// Etkinleştirmeden sonraki ayrı istek: eklentinin plugins_loaded kancaları bağlıdır; ayarlar Ayarlar > Feralin sayfasının
	// kaydettiği gibi register_setting temizleyicisinden geçer.
	require $root . '/wp-load.php';
	require_once ABSPATH . 'wp-admin/includes/template.php';
	// Ayarlar register_setting ile bağlanan temizleyiciden geçer: önce sk_ anahtarı reddedilmeli, sonra pk_ kabul edilmeli.
	// admin_init'in eklentiye bağladığı işlev; bütün admin_init kancaları tetiklenmez (WooCommerce'in yönetim kodu panel ister).
	Feralin_Settings::register_settings();
	update_option('feralin_settings', ['project_key' => 'sk_live_should_be_rejected', 'collect_url' => $collectUrl, 'frontend_enabled' => '1', 'woocommerce_enabled' => '1']);
	$saved = get_option('feralin_settings');
	if (($saved['project_key'] ?? '') !== '') fail('sk_ anahtarı ayarlara yazıldı');
	update_option('feralin_settings', ['project_key' => $projectKey, 'collect_url' => $collectUrl, 'frontend_enabled' => '1', 'woocommerce_enabled' => '1']);
	$saved = get_option('feralin_settings');
	if (($saved['project_key'] ?? '') !== $projectKey || ($saved['collect_url'] ?? '') !== rtrim($collectUrl, '/')) fail('ayarlar beklenen değerle kaydedilmedi: ' . wp_json_encode($saved));
	echo 'wordpress ' . get_bloginfo('version') . ', woocommerce ' . get_option('woocommerce_version') . ', feralin ' . FERALIN_PLUGIN_VERSION . "\n";
	exit(0);
}

$consent = ($argv[3] ?? '') === 'yes';
require $root . '/wp-load.php';
add_filter('pre_wp_mail', '__return_true');
if (!class_exists('WooCommerce') || !function_exists('wc_create_order')) fail('WooCommerce yüklenmedi');
if (!class_exists('Feralin_WooCommerce')) fail('Feralin eklentisi yüklenmedi');
if (!get_option('woocommerce_db_version')) {
	WC_Install::install();
}
update_option('woocommerce_currency', 'TRY');
// Ödeme anındaki izin aracının kararı (README'deki süzgeç örneği). null: karar yok, sipariş olayı gönderilmez.
add_filter('feralin_checkout_consent', static fn () => $consent ? ['analytics' => true, 'advertising' => false] : null);

$product = new WC_Product_Simple();
$product->set_name('Feralin E2E ürünü');
$product->set_regular_price('149.90');
$product->set_status('publish');
$product->save();

$order = wc_create_order();
$order->add_product($product, 2);
$order->set_currency('TRY');
$order->calculate_totals(false);
$order->save();
// WooCommerce ödeme anında bu kancayı çağırır; eklenti izni siparişe yazar.
do_action('woocommerce_checkout_order_created', $order);
$order = wc_get_order($order->get_id());
$order->update_status('completed');
echo $order->get_id() . "\n";
