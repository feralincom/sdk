<?php

declare(strict_types=1);

namespace Feralin;

/** Şema sınırları istemcide uygulanır, çünkü tek geçersiz alan toplayıcıda tüm batch'i 400 ile düşürür. */
final class EventRules
{
    public const MAX_PROPERTIES = 100;
    public const MAX_IDENTIFIER_LENGTH = 128;
    public const CLICK_PROPERTY = 'fr_click';

    private const UTM_KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content'];
    private const MAX_UTM_LENGTH = 256;
    private const MAX_URL_LENGTH = 2048;
    private const ULID_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

    public static function validEventName(string $name): bool
    {
        return $name !== '' && strlen($name) <= 100 && preg_match('/^[a-z][a-z0-9_]*$/D', $name) === 1;
    }

    /**
     * @param array<array-key, mixed> $properties
     * @return array<string, mixed> Geçersiz anahtar atılır; 100 anahtardan sonrası alınmaz.
     */
    public static function sanitizeProperties(array $properties): array
    {
        $out = [];
        foreach ($properties as $key => $value) {
            if (count($out) >= self::MAX_PROPERTIES) {
                break;
            }
            if (is_string($key) && preg_match('/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/D', $key) === 1 && !is_resource($value)) {
                $out[$key] = $value;
            }
        }
        return $out;
    }

    /**
     * Bağlamı şemaya indirger; bilinmeyen alan ve ayrıştırılamayan URL gönderilmez, sorgu dizgisi hiç çıkmaz. Host ve Referer
     * saldırgan denetimindedir: şema sınırını aşan adres kırpılmaz, gönderilmez, çünkü tek geçersiz alan toplayıcıda tüm batch'i
     * 400 ile düşürür ve başka kullanıcıların olayları da gider.
     *
     * @param array<string, mixed> $context page_url, page_title, referrer, locale, timezone, screen, app
     * @param array<string, mixed> $properties utm_* değerleri buraya taşınır; açıkça verilen değer ezilmez
     * @return array<string, mixed>
     */
    public static function normalizeContext(array $context, array &$properties): array
    {
        $out = [];
        $page = self::parseUrl($context['page_url'] ?? null);
        if ($page !== null) {
            parse_str($page['query'] ?? '', $query);
            foreach (self::UTM_KEYS as $key) {
                if (isset($query[$key]) && is_string($query[$key]) && trim($query[$key]) !== '' && !array_key_exists($key, $properties) && count($properties) < self::MAX_PROPERTIES) {
                    $properties[$key] = substr(trim($query[$key]), 0, self::MAX_UTM_LENGTH);
                }
            }
            $clean = self::origin($page) . self::encodePath((string) ($page['path'] ?? '/'));
            if (strlen($clean) <= self::MAX_URL_LENGTH) {
                $out['page_url'] = $clean;
            }
        }
        foreach (['page_title' => 512, 'locale' => 16, 'timezone' => 64] as $field => $max) {
            // Bozuk UTF-8 olayı JSON aşamasında düşürürdü; yalnız bu alan atılır.
            if (isset($context[$field]) && is_string($context[$field]) && $context[$field] !== '' && mb_check_encoding($context[$field], 'UTF-8')) {
                $out[$field] = mb_substr($context[$field], 0, $max, 'UTF-8');
            }
        }
        $referrer = self::parseUrl($context['referrer'] ?? null);
        if ($referrer !== null) {
            $origin = self::origin($referrer);
            if (strlen($origin) <= self::MAX_URL_LENGTH) {
                $out['referrer'] = $origin;
            }
        }
        if (isset($context['screen']) && is_array($context['screen'])) {
            $screen = [];
            foreach (['width', 'height'] as $field) {
                if (isset($context['screen'][$field]) && is_int($context['screen'][$field]) && $context['screen'][$field] >= 0) {
                    $screen[$field] = $context['screen'][$field];
                }
            }
            if ($screen !== []) {
                $out['screen'] = $screen;
            }
        }
        if (isset($context['app']) && is_array($context['app'])) {
            $app = [];
            foreach (['version', 'build'] as $field) {
                if (isset($context['app'][$field]) && is_string($context['app'][$field]) && $context['app'][$field] !== '') {
                    $app[$field] = substr($context['app'][$field], 0, 32);
                }
            }
            if ($app !== []) {
                $out['app'] = $app;
            }
        }
        return $out;
    }

    /** 26 karakter Crockford base32: 48 bit zaman, 80 bit güvenli rastgele. */
    public static function ulid(int $nowMs): string
    {
        $chars = str_split(self::ULID_ALPHABET);
        $time = '';
        $remaining = max(0, $nowMs);
        for ($i = 0; $i < 10; $i++) {
            $time = $chars[$remaining % 32] . $time;
            $remaining = intdiv($remaining, 32);
        }
        $random = '';
        foreach (str_split(random_bytes(16)) as $byte) {
            $random .= $chars[ord($byte) % 32];
        }
        return $time . $random;
    }

    /** @return array<string, int|string>|null */
    private static function parseUrl(mixed $raw): ?array
    {
        if (!is_string($raw) || $raw === '') {
            return null;
        }
        $parts = parse_url($raw);
        if ($parts === false || !isset($parts['scheme'], $parts['host']) || !in_array(strtolower($parts['scheme']), ['http', 'https'], true)) {
            return null;
        }
        return self::validHost($parts['host']) ? $parts : null;
    }

    /** parse_url host'u doğrulamaz; toplayıcının format: uri denetimi (Go net/url) `a b` gibi değerde batch'i reddeder. */
    private static function validHost(string $host): bool
    {
        if (str_starts_with($host, '[') && str_ends_with($host, ']')) {
            return filter_var(substr($host, 1, -1), FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false;
        }
        return preg_match('/^[A-Za-z0-9._~-]+$/D', $host) === 1;
    }

    /** Ham istek yolundaki URI dışı baytlar ve kaçış sanılan açıkta % kodlanır; geçerli kaçış olduğu gibi kalır. */
    private static function encodePath(string $path): string
    {
        return (string) preg_replace_callback(
            '~%(?![0-9A-Fa-f]{2})|[^A-Za-z0-9\-._\~!$&\'()*+,;=:@/%]~',
            static fn (array $match): string => rawurlencode($match[0]),
            $path,
        );
    }

    /** @param array<string, int|string> $parts */
    private static function origin(array $parts): string
    {
        $port = isset($parts['port']) ? ':' . $parts['port'] : '';
        return strtolower((string) $parts['scheme']) . '://' . $parts['host'] . $port;
    }
}
