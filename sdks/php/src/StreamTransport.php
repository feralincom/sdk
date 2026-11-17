<?php

declare(strict_types=1);

namespace Feralin;

/** Varsayılan taşıma: ext-curl varsa cURL, yoksa PHP akış sarmalayıcısı. TLS doğrulaması açıktır. */
final class StreamTransport implements Transport
{
    private const MAX_RESPONSE_BYTES = 65536;

    public function post(string $url, string $body, array $headers, float $timeoutSeconds): array
    {
        return function_exists('curl_init')
            ? $this->viaCurl($url, $body, $headers, $timeoutSeconds)
            : $this->viaStream($url, $body, $headers, $timeoutSeconds);
    }

    /**
     * @param array<string, string> $headers
     * @return array{status: int, body: string, retryAfter: ?string}
     */
    private function viaCurl(string $url, string $body, array $headers, float $timeoutSeconds): array
    {
        $handle = curl_init($url);
        if ($handle === false) {
            return ['status' => 0, 'body' => '', 'retryAfter' => null];
        }
        $lines = [];
        foreach ($headers as $name => $value) {
            $lines[] = $name . ': ' . $value;
        }
        $retryAfter = null;
        curl_setopt_array($handle, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $body,
            CURLOPT_HTTPHEADER => $lines,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_TIMEOUT_MS => (int) ($timeoutSeconds * 1000),
            CURLOPT_CONNECTTIMEOUT_MS => (int) (min($timeoutSeconds, 2.0) * 1000),
            CURLOPT_HEADERFUNCTION => static function ($unused, string $line) use (&$retryAfter): int {
                if (stripos($line, 'retry-after:') === 0) {
                    $retryAfter = trim(substr($line, 12));
                }
                return strlen($line);
            },
        ]);
        $response = curl_exec($handle);
        $status = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
        curl_close($handle);
        if (!is_string($response)) {
            return ['status' => 0, 'body' => '', 'retryAfter' => null];
        }
        return ['status' => $status, 'body' => substr($response, 0, self::MAX_RESPONSE_BYTES), 'retryAfter' => $retryAfter];
    }

    /**
     * @param array<string, string> $headers
     * @return array{status: int, body: string, retryAfter: ?string}
     */
    private function viaStream(string $url, string $body, array $headers, float $timeoutSeconds): array
    {
        $lines = '';
        foreach ($headers as $name => $value) {
            $lines .= $name . ': ' . $value . "\r\n";
        }
        $context = stream_context_create(['http' => [
            'method' => 'POST',
            'header' => $lines,
            'content' => $body,
            'timeout' => $timeoutSeconds,
            'ignore_errors' => true,
            'follow_location' => 0,
        ]]);
        // Bağlantı hatası uyarısı uygulama çıktısına karışmasın; sonuç durum 0 ile bildirilir.
        $response = @file_get_contents($url, false, $context, 0, self::MAX_RESPONSE_BYTES);
        if (!is_string($response) || !isset($http_response_header) || !is_array($http_response_header)) {
            return ['status' => 0, 'body' => '', 'retryAfter' => null];
        }
        $status = 0;
        $retryAfter = null;
        foreach ($http_response_header as $line) {
            if (preg_match('#^HTTP/\S+\s+(\d{3})#', $line, $match) === 1) {
                $status = (int) $match[1];
            } elseif (stripos($line, 'retry-after:') === 0) {
                $retryAfter = trim(substr($line, 12));
            }
        }
        return ['status' => $status, 'body' => $response, 'retryAfter' => $retryAfter];
    }
}
