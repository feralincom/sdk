<?php

declare(strict_types=1);

namespace Feralin;

use Throwable;

/**
 * `fr_error` sözleşmesi (X4): hata sınıfı adı, temizlenmiş kısa mesaj, normalize edilmiş çerçevelerin özeti olan parmak izi ve en
 * üst çerçeve. Ham yığın izi, dizin yolu, bağımsız değişken değerleri ve kullanıcı verisi GİTMEZ. Sembolleştirme için uygulama
 * çerçevelerinin konumu ayrıca gider (`frames`: en çok 5; yalnız dosya taban adı, satır, işlev adı). Kurallar Android, Flutter ve
 * Web SDK'larıyla aynıdır (sdks/android/.../internal/ErrorEvent.kt); toplayıcı mesajı ayrıca temizler.
 */
final class ErrorCapture
{
    public const EVENT_NAME = 'fr_error';
    public const ORIGIN_HANDLED = 'handled';
    public const ORIGIN_MANUAL = 'manual';
    public const ORIGIN_UNCAUGHT = 'uncaught_exception';
    public const ORIGINS = [self::ORIGIN_HANDLED, self::ORIGIN_MANUAL, self::ORIGIN_UNCAUGHT];
    public const MAX_MESSAGE = 200;
    public const MAX_TYPE = 64;
    public const MAX_FRAME = 160;

    private const FINGERPRINT_FRAMES = 5;
    private const MAX_LOCATIONS = 5;
    private const MAX_FUNCTION = 60;
    private const MAX_APP_VERSION = 32;
    private const MAX_FRAME_COUNT = 1000;
    private const MAX_LINE = 10000000;
    // Toplayıcının `frames[].file` kuralı: yalnız taban ad, dizin ve sorgu yok.
    private const LOCATION_FILE = '/^[A-Za-z0-9._~-]{1,128}$/D';

    /** Mesajdan URL, e-posta, UUID, uzun belirteç ve uzun sayıları çıkarır; 200 karaktere kırpar. Sıra toplayıcıyla aynıdır. */
    public static function scrub(string $message): string
    {
        $text = mb_scrub($message, 'UTF-8');
        $text = (string) preg_replace('~\b[a-z][a-z0-9+.\-]*://[^\s"\'<>]+~iu', '[url]', $text);
        $text = (string) preg_replace('/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/u', '[email]', $text);
        $text = (string) preg_replace('/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/iu', '[id]', $text);
        // Uzun belirteç: 24+ karakter ve en az bir rakam; rakamsız uzun sınıf adları bozulmaz.
        $text = (string) preg_replace_callback(
            '~\b[A-Za-z0-9_\-+/=]{24,}\b~u',
            static fn (array $match): string => preg_match('/[0-9]/', $match[0]) === 1 ? '[token]' : $match[0],
            $text,
        );
        // Telefon, kart, kimlik numarası benzeri: ayraçlar dahil en az 7 rakam; kısa sürüm dizgeleri (1.4.2) bozulmaz.
        $text = (string) preg_replace_callback(
            '/\+?[0-9][0-9\s\-().]{5,}[0-9]/u',
            static fn (array $match): string => preg_match_all('/[0-9]/', $match[0]) >= 7 ? '[num]' : $match[0],
            $text,
        );
        $text = (string) preg_replace('/\s+/u', ' ', trim($text));
        return mb_substr($text, 0, self::MAX_MESSAGE, 'UTF-8');
    }

    /**
     * Yığını çerçevelere çevirir. PHP izinde her kayıt çağrılan işlevi ve çağrı yerini taşır; çerçevenin kendi konumu bir önceki
     * kaydın çağrı yeridir (ilk çerçeve için fırlatma yeri).
     *
     * @return list<array{label: string, function: string, file: string, line: int, app: bool}>
     */
    public static function frames(Throwable $error): array
    {
        $frames = [];
        $file = $error->getFile();
        $line = $error->getLine();
        foreach ($error->getTrace() as $entry) {
            $function = self::normalizeFunction((string) ($entry['function'] ?? ''));
            $class = self::normalizeClass((string) ($entry['class'] ?? ''));
            $frames[] = self::frame($class, $function, $file, $line);
            $file = (string) ($entry['file'] ?? '');
            $line = (int) ($entry['line'] ?? 0);
        }
        if ($file !== '') {
            $frames[] = self::frame('', '{main}', $file, $line);
        }
        return $frames;
    }

    /** Parmak izi: tür ve ilk beş uygulama çerçevesinin SHA-256 özetinin ilk 16 baytı (32 onaltılık karakter). */
    public static function fingerprint(string $type, array $labels, string $message): string
    {
        $basis = $labels !== []
            ? implode('|', array_slice($labels, 0, self::FINGERPRINT_FRAMES))
            : (string) preg_replace('/[0-9]+/', '#', $message);
        return substr(hash('sha256', $type . '|' . $basis), 0, 32);
    }

    /**
     * Hata gövdesi; sözleşme alanlarının tamamı. `appVersion` 1-32 karakterse eklenir.
     *
     * @return array<string, mixed>
     */
    public static function properties(Throwable $error, string $origin, bool $fatal, ?string $appVersion = null): array
    {
        $type = mb_substr(self::shortClassName(get_class($error)), 0, self::MAX_TYPE, 'UTF-8');
        if ($type === '') {
            $type = 'Error';
        }
        $message = self::scrub($error->getMessage());
        $all = self::frames($error);
        $app = array_values(array_filter($all, static fn (array $frame): bool => $frame['app']));
        // Uygulama çerçevesi yoksa (hata tamamen kütüphane içinde) bütün çerçeveler kullanılır.
        $labels = array_map(static fn (array $frame): string => $frame['label'], $app !== [] ? $app : $all);

        $out = ['error_type' => $type];
        if ($message !== '') {
            $out['message'] = $message;
        }
        $out['fingerprint'] = self::fingerprint($type, $labels, $message);
        if ($labels !== []) {
            $out['top_frame'] = mb_substr($labels[0], 0, self::MAX_FRAME, 'UTF-8');
        }
        $out['frame_count'] = min(count($labels), self::MAX_FRAME_COUNT);
        if ($appVersion !== null && $appVersion !== '' && mb_strlen($appVersion, 'UTF-8') <= self::MAX_APP_VERSION) {
            $out['app_version'] = $appVersion;
        }
        $out['handled'] = $origin === self::ORIGIN_HANDLED || $origin === self::ORIGIN_MANUAL;
        $out['fatal'] = $fatal;
        $out['origin'] = $origin;
        $locations = self::locations($app);
        if ($locations !== []) {
            $out['frames'] = $locations;
        }
        return $out;
    }

    /**
     * Sembolleştirme konumları: uygulama çerçevelerinin ilk beşi; dosya taban adı, satır ve işlev adı. Satırı bilinmeyen ya da
     * toplayıcı kuralına sığmayan çerçeve listeye girmez.
     *
     * @param list<array{label: string, function: string, file: string, line: int, app: bool}> $frames
     * @return list<array<string, mixed>>
     */
    private static function locations(array $frames): array
    {
        $out = [];
        foreach ($frames as $frame) {
            if (count($out) >= self::MAX_LOCATIONS) {
                break;
            }
            $base = basename(str_replace('\\', '/', $frame['file']));
            if ($frame['line'] < 1 || preg_match(self::LOCATION_FILE, $base) !== 1) {
                continue;
            }
            $location = ['file' => $base, 'line' => min($frame['line'], self::MAX_LINE), 'column' => 0];
            if ($frame['function'] !== '' && mb_strlen($frame['function'], 'UTF-8') <= self::MAX_FUNCTION) {
                $location['function'] = $frame['function'];
            }
            $out[] = $location;
        }
        return $out;
    }

    /** @return array{label: string, function: string, file: string, line: int, app: bool} */
    private static function frame(string $class, string $function, string $file, int $line): array
    {
        $path = str_replace('\\', '/', $file);
        return [
            // Çerçeve: `sınıf.yöntem`; satır ve dosya yok, böylece aynı hata kod kaydığında da aynı parmak izini üretir.
            'label' => $class !== '' ? $class . '.' . $function : $function,
            'function' => $function,
            'file' => $file,
            'line' => $line,
            // Composer bağımlılıkları ve dosyasız (dahili işlev) çerçeveler uygulama çerçevesi sayılmaz.
            'app' => $path !== '' && !str_contains($path, '/vendor/'),
        ];
    }

    /** PHP 8.4 kapanış adı dosya yolu ve satır taşır (`{closure:/yol/dosya.php:12}`); yol gönderilmez. */
    private static function normalizeFunction(string $function): string
    {
        return (string) preg_replace('/\{closure[^}]*\}/', '{closure}', $function);
    }

    /** Anonim sınıf adı dosya yolu ve boş bayt taşır (`class@anonymous\0/yol/dosya.php:12$0`); yol gönderilmez. */
    private static function normalizeClass(string $class): string
    {
        return (string) preg_replace('/@anonymous.*$/s', '@anonymous', $class);
    }

    private static function shortClassName(string $class): string
    {
        $class = self::normalizeClass($class);
        $position = strrpos($class, '\\');
        return $position === false ? $class : substr($class, $position + 1);
    }
}
