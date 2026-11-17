<?php

declare(strict_types=1);

namespace Feralin;

/** HTTP katmanı; test, proxy veya framework istemcisi için değiştirilebilir. Ağ hatasında durum 0 döner, fırlatmaz. */
interface Transport
{
    /**
     * @param array<string, string> $headers
     * @return array{status: int, body: string, retryAfter: ?string}
     */
    public function post(string $url, string $body, array $headers, float $timeoutSeconds): array;
}
