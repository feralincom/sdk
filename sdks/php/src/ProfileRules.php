<?php

declare(strict_types=1);

namespace Feralin;

/**
 * UTP §8.2 kimlik yöntemleri: group (`fr_group`), setUserProperties (`fr_user_properties`) ve global özellikler.
 *
 * Kurallar bütün SDK'larda ve toplayıcıda (services/collect/internal/httpapi/profile_filter.go) aynıdır:
 * - Anahtar ^[a-zA-Z][a-zA-Z0-9_]{0,63}$; çağrı başına en çok 50 özellik.
 * - Değer dizge (en çok 256 karakter, kontrol karakteri yok, e-posta biçiminde değil), sonlu sayı ya da bool; dizi, nesne ve null düşer.
 * - Doğrulama alanları (verified, receipt vb.) düşer: istemci doğrulama beyan edemez.
 * - Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) düşer.
 * Toplayıcı ayrıca projenin izin listesini uygular; liste boşsa olay sayılır ama özellik saklanmaz.
 */
final class ProfileRules
{
    public const GROUP_EVENT_NAME = 'fr_group';
    public const USER_PROPERTIES_EVENT_NAME = 'fr_user_properties';
    public const SYSTEM_EVENT_PREFIX = 'fr_';
    public const MAX_PROPERTIES = 50;
    public const MAX_VALUE_LENGTH = 256;
    public const MAX_GROUP_ID_LENGTH = 128;

    private const RESERVED_KEYS = ['verified', 'verification', 'verification_source', 'receipt_provider', 'receipt_digest', 'receipt'];
    // Toplayıcıdaki piiTokens, piiFragments ve piiExact listeleriyle birebir.
    private const PII_TOKENS = [
        'email', 'mail', 'phone', 'tel', 'telephone', 'mobile', 'msisdn', 'gsm',
        'ip', 'ipv4', 'ipv6', 'ssn', 'tckn', 'passport', 'password', 'iban',
        'address', 'adres', 'eposta', 'telefon', 'soyad', 'surname', 'firstname',
        'lastname', 'fullname', 'birthdate', 'birthday', 'dob',
    ];
    private const PII_FRAGMENTS = ['email', 'phonenumber', 'ipaddress', 'firstname', 'lastname', 'fullname', 'surname', 'soyad', 'eposta', 'telefon', 'password', 'birthdate'];
    private const PII_EXACT = ['name', 'username', 'displayname', 'isim', 'ad'];

    /** Anahtar kişisel veriye benziyor mu: sözcüklere bölünür (alt çizgi ve küçük harf/rakam → büyük harf geçişi). */
    public static function isPiiLikeKey(string $key): bool
    {
        $snake = strtolower((string) preg_replace('/(?<=[a-z0-9])(?=[A-Z])/', '_', $key));
        $tokens = array_values(array_filter(explode('_', $snake), static fn (string $token): bool => $token !== ''));
        foreach ($tokens as $token) {
            if (in_array($token, self::PII_TOKENS, true)) {
                return true;
            }
        }
        $joined = implode('', $tokens);
        if (in_array($joined, self::PII_EXACT, true)) {
            return true;
        }
        foreach (self::PII_FRAGMENTS as $fragment) {
            if (str_contains($joined, $fragment)) {
                return true;
            }
        }
        return false;
    }

    public static function validKey(mixed $key): bool
    {
        return is_string($key)
            && preg_match('/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/D', $key) === 1
            && !in_array($key, self::RESERVED_KEYS, true)
            && !self::isPiiLikeKey($key);
    }

    public static function validValue(mixed $value): bool
    {
        if (is_bool($value) || is_int($value)) {
            return true;
        }
        if (is_float($value)) {
            return is_finite($value);
        }
        if (is_string($value)) {
            return mb_check_encoding($value, 'UTF-8')
                && mb_strlen($value, 'UTF-8') <= self::MAX_VALUE_LENGTH
                && preg_match('/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u', $value) !== 1
                && preg_match('/[^\s@]+@[^\s@]+\.[^\s@]+/u', $value) !== 1;
        }
        return false;
    }

    /**
     * @param array<array-key, mixed> $properties
     * @return array<string, mixed> Geçersiz anahtar ve değer düşer; 50 özellikten sonrası alınmaz.
     */
    public static function sanitize(array $properties, ?int &$dropped = null): array
    {
        $out = [];
        $dropped = 0;
        foreach ($properties as $key => $value) {
            if (count($out) >= self::MAX_PROPERTIES || !self::validKey($key) || !self::validValue($value)) {
                $dropped++;
                continue;
            }
            $out[(string) $key] = $value;
        }
        return $out;
    }

    /** Grup kimliği 1-128 karakter, boşluktan ibaret değil; `@` ve kontrol karakteri içermez. */
    public static function validGroupId(mixed $groupId): bool
    {
        return is_string($groupId)
            && trim($groupId) !== ''
            && mb_check_encoding($groupId, 'UTF-8')
            && mb_strlen($groupId, 'UTF-8') <= self::MAX_GROUP_ID_LENGTH
            && !str_contains($groupId, '@')
            && preg_match('/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u', $groupId) !== 1;
    }

    /**
     * Global haritaya birleştirir: null değer anahtarı siler; toplam en çok 50 anahtar, fazlası yok sayılır.
     *
     * @param array<string, mixed> $current
     * @param array<array-key, mixed> $update
     * @return array<string, mixed>
     */
    public static function mergeGlobals(array $current, array $update, ?int &$dropped = null): array
    {
        $additions = [];
        foreach ($update as $key => $value) {
            if ($value === null) {
                unset($current[(string) $key]);
                continue;
            }
            $additions[$key] = $value;
        }
        $dropped = 0;
        foreach (self::sanitize($additions, $invalid) as $key => $value) {
            if (!array_key_exists($key, $current) && count($current) >= self::MAX_PROPERTIES) {
                $dropped++;
                continue;
            }
            $current[$key] = $value;
        }
        $dropped += $invalid ?? 0;
        return $current;
    }
}
