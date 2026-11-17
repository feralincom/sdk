<?php
/**
 * WordPress çekirdeği olmadan eklenti birim testleri için ince saplar. Çekirdek indirilmez; yalnız eklentinin çağırdığı
 * işlevler taklit edilir. Bu, gerçek WordPress/WooCommerce kurulumunda çalışmanın kanıtı DEĞİLDİR (BLOCKED_EXTERNAL).
 *
 * Eklenti geçici bir dizine kopyalanır ve `lib/feralin-php` ile `assets` build betiğindeki gibi yerleştirilir; böylece
 * gerçek dağıtım yerleşimi sınanır.
 */

declare(strict_types=1);

define('ABSPATH', sys_get_temp_dir() . '/');
define('HOUR_IN_SECONDS', 3600);
define('MINUTE_IN_SECONDS', 60);

$wp_root = dirname(__DIR__);
$work = sys_get_temp_dir() . '/feralin-wp-test-' . getmypid();
if (!is_dir($work)) {
    mkdir($work, 0700, true);
}
register_shutdown_function(static function () use ($work): void {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($work, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($it as $file) {
        $file->isDir() ? rmdir($file->getPathname()) : unlink($file->getPathname());
    }
    rmdir($work);
});

/** Dizini özyinelemeli kopyalar. */
function feralin_test_copy(string $from, string $to): void
{
    mkdir($to, 0700, true);
    foreach (new DirectoryIterator($from) as $entry) {
        if ($entry->isDot()) {
            continue;
        }
        $target = $to . '/' . $entry->getFilename();
        $entry->isDir() ? feralin_test_copy($entry->getPathname(), $target) : copy($entry->getPathname(), $target);
    }
}

feralin_test_copy($wp_root . '/feralin', $work . '/feralin');
feralin_test_copy(dirname($wp_root) . '/php/src', $work . '/feralin/lib/feralin-php');
mkdir($work . '/feralin/assets', 0700, true);
file_put_contents($work . '/feralin/assets/feralin.iife.js', '/* sap */');
define('FERALIN_TEST_PLUGIN_DIR', $work . '/feralin/');

/** WordPress durumu: seçenekler, kancalar, zamanlanmış olaylar, ayar hataları, kuyruktaki betikler. */
final class WpStub
{
    /** @var array<string, mixed> */
    public static array $options = [];
    /** @var array<string, list<callable>> */
    public static array $actions = [];
    /** @var array<string, list<callable>> */
    public static array $filters = [];
    /** @var list<array{hook: string, time: int}> */
    public static array $scheduled = [];
    /** @var list<string> */
    public static array $clearedHooks = [];
    /** @var list<array{code: string, message: string}> */
    public static array $settingErrors = [];
    /** @var list<array{handle: string, src: string, args: array<mixed>}> */
    public static array $scripts = [];
    /** @var list<array{handle: string, code: string}> */
    public static array $inline = [];
    /** @var array<string, list<callable>> */
    public static array $boot = [];
    public static bool $preview = false;
    public static bool $isAdmin = true;

    public static function reset(): void
    {
        self::$options = [];
        self::$actions = [];
        self::$filters = [];
        self::$scheduled = [];
        self::$clearedHooks = [];
        self::$settingErrors = [];
        self::$scripts = [];
        self::$inline = [];
        self::$preview = false;
        self::$isAdmin = true;
    }
}

function add_action(string $hook, callable $callback): void
{
    WpStub::$actions[$hook][] = $callback;
}

function do_action(string $hook, mixed ...$args): void
{
    foreach (WpStub::$actions[$hook] ?? [] as $callback) {
        $callback(...$args);
    }
}

function add_filter(string $hook, callable $callback): void
{
    WpStub::$filters[$hook][] = $callback;
}

function apply_filters(string $hook, mixed $value, mixed ...$args): mixed
{
    foreach (WpStub::$filters[$hook] ?? [] as $callback) {
        $value = $callback($value, ...$args);
    }
    return $value;
}

function get_option(string $name, mixed $default = false): mixed
{
    return WpStub::$options[$name] ?? $default;
}

function update_option(string $name, mixed $value, mixed $autoload = null): bool
{
    WpStub::$options[$name] = $value;
    return true;
}

function delete_option(string $name): bool
{
    unset(WpStub::$options[$name]);
    return true;
}

function plugin_dir_path(string $file): string
{
    return dirname($file) . '/';
}

function plugin_basename(string $file): string
{
    return basename(dirname($file)) . '/' . basename($file);
}

function plugins_url(string $path, string $plugin): string
{
    return 'https://site.test/wp-content/plugins/feralin/' . $path;
}

function load_plugin_textdomain(string $domain, mixed $deprecated, string $path): bool
{
    return true;
}

function register_deactivation_hook(string $file, callable $callback): void
{
    WpStub::$actions['deactivate'][] = $callback;
}

function __(string $text, string $domain = ''): string
{
    return $text;
}

function esc_html__(string $text, string $domain = ''): string
{
    return htmlspecialchars($text, ENT_QUOTES);
}

function esc_html(string $text): string
{
    return htmlspecialchars($text, ENT_QUOTES);
}

function esc_attr(string $text): string
{
    return htmlspecialchars($text, ENT_QUOTES);
}

function sanitize_text_field(string $text): string
{
    return trim(strip_tags($text));
}

function wp_unslash(string $text): string
{
    return stripslashes($text);
}

/** @param list<string> $protocols */
function esc_url_raw(string $url, array $protocols = []): string
{
    $scheme = parse_url($url, PHP_URL_SCHEME);
    return is_string($scheme) && in_array($scheme, $protocols, true) ? $url : '';
}

function wp_http_validate_url(string $url): string|false
{
    $host = parse_url($url, PHP_URL_HOST);
    // WordPress özel adresleri (127.0.0.1, localhost) reddeder; sap da aynısını yapar.
    return is_string($host) && !in_array($host, ['localhost', '127.0.0.1'], true) ? $url : false;
}

function untrailingslashit(string $text): string
{
    return rtrim($text, '/\\');
}

function add_settings_error(string $setting, string $code, string $message): void
{
    WpStub::$settingErrors[] = ['code' => $code, 'message' => $message];
}

function register_setting(string $group, string $name, array $args = []): void
{
    WpStub::$options['__registered_setting'] = $name;
}

function add_settings_section(string $id, string $title, callable|string $callback, string $page): void
{
}

function add_settings_field(string $id, string $title, callable $callback, string $page, string $section): void
{
}

function is_preview(): bool
{
    return WpStub::$preview;
}

function current_user_can(string $capability): bool
{
    return WpStub::$isAdmin;
}

/** @param array<mixed> $args */
function wp_enqueue_script(string $handle, string $src, array $deps = [], mixed $version = false, mixed $args = []): void
{
    WpStub::$scripts[] = ['handle' => $handle, 'src' => $src, 'args' => (array) $args];
}

function wp_add_inline_script(string $handle, string $code, string $position = 'after'): bool
{
    WpStub::$inline[] = ['handle' => $handle, 'code' => $code];
    return true;
}

function wp_json_encode(mixed $value, int $flags = 0): string|false
{
    return json_encode($value, $flags);
}

function wp_next_scheduled(string $hook): int|false
{
    foreach (WpStub::$scheduled as $item) {
        if ($item['hook'] === $hook) {
            return $item['time'];
        }
    }
    return false;
}

function wp_schedule_single_event(int $time, string $hook): bool
{
    WpStub::$scheduled[] = ['hook' => $hook, 'time' => $time];
    return true;
}

function wp_clear_scheduled_hook(string $hook): void
{
    WpStub::$clearedHooks[] = $hook;
    WpStub::$scheduled = array_values(array_filter(WpStub::$scheduled, static fn (array $item): bool => $item['hook'] !== $hook));
}

function wp_rand(int $min, int $max): int
{
    return $min;
}

function wp_salt(string $scheme): string
{
    return 'test-salt-' . $scheme;
}

function checked(mixed $value, mixed $current = true, bool $echo = true): string
{
    return $value === $current ? 'checked="checked"' : '';
}

/** WooCommerce sapı: tek sipariş, kaydedilmiş meta. */
final class FakeOrder
{
    /** @var array<string, mixed> */
    public array $meta = [];

    public function __construct(
        private int $id = 77,
        private float $total = 149.9,
        private string $currency = 'TRY',
        private int $items = 3,
        private int $userId = 0,
    ) {
    }

    public function get_id(): int
    {
        return $this->id;
    }

    public function get_total(): string
    {
        return (string) $this->total;
    }

    public function get_currency(): string
    {
        return $this->currency;
    }

    public function get_item_count(): int
    {
        return $this->items;
    }

    public function get_user_id(): int
    {
        return $this->userId;
    }

    public function update_meta_data(string $key, mixed $value): void
    {
        $this->meta[$key] = $value;
    }

    public function save_meta_data(): void
    {
    }

    public function get_meta(string $key): mixed
    {
        return $this->meta[$key] ?? '';
    }
}

final class FakeOrders
{
    /** @var array<int, FakeOrder> */
    public static array $orders = [];
}

function wc_get_order(int $id): FakeOrder|false
{
    return FakeOrders::$orders[$id] ?? false;
}

// WooCommerce'in varlığını `class_exists('WooCommerce')` denetimi için bildirir.
class WooCommerce
{
}

require FERALIN_TEST_PLUGIN_DIR . 'feralin.php';
// Eklenti dosyası yüklenirken kaydedilen kancalar (plugins_loaded, deactivate); testler arasında `reset` bunları siler.
WpStub::$boot = WpStub::$actions;
