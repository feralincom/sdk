<?php

declare(strict_types=1);

namespace Feralin\Symfony;

use Feralin\Client;
use Feralin\Consent;
use Feralin\FlushResult;
use Throwable;

/** O isteğe bağlı yüzey: izin, kimlik ve bağlam her olaya otomatik eklenir. */
final class RequestFeralin
{
    /** @param array<string, mixed> $defaults Client::track seçenekleri */
    public function __construct(
        private readonly Client $client,
        public readonly Consent $consent,
        private readonly array $defaults = [],
    ) {
    }

    /**
     * @param array<string, mixed> $properties
     * @param array<string, mixed> $options
     * @return array<string, mixed>|null
     */
    public function track(string $eventName, array $properties = [], array $options = []): ?array
    {
        return $this->client->track($eventName, $properties, $this->withRequest($options));
    }

    /**
     * `feralin_purchase` gelir beyanı (Client::trackRevenue); bu isteğin izni ve kimliği eklenir.
     *
     * @param array<string, mixed> $revenue
     * @param array<string, mixed> $options
     * @return array<string, mixed>|null
     */
    public function trackRevenue(array $revenue, array $options = []): ?array
    {
        return $this->client->trackRevenue($revenue, $this->withRequest($options));
    }

    /**
     * `fr_group` (Client::group); bu isteğin izni ve kimliği eklenir.
     *
     * @param array<string, mixed> $traits
     * @param array<string, mixed> $options
     * @return array<string, mixed>|null
     */
    public function group(string $groupId, array $traits = [], array $options = []): ?array
    {
        return $this->client->group($groupId, $traits, $this->withRequest($options));
    }

    /**
     * `fr_user_properties` (Client::setUserProperties); bu isteğin izni ve kimliği eklenir.
     *
     * @param array<string, mixed> $properties
     * @param array<string, mixed> $options
     * @return array<string, mixed>|null
     */
    public function setUserProperties(array $properties, array $options = []): ?array
    {
        return $this->client->setUserProperties($properties, $this->withRequest($options));
    }

    /**
     * `fr_error` (Client::captureError); bu isteğin izni ve kimliği eklenir.
     *
     * @param array<string, mixed> $options
     * @return array<string, mixed>|null
     */
    public function captureError(Throwable $error, array $options = []): ?array
    {
        return $this->client->captureError($error, $this->withRequest($options));
    }

    public function flush(): FlushResult
    {
        return $this->client->flush();
    }

    /**
     * Olay başına seçenek önceliklidir; sonra bu isteğin izni, sonra ara katmanın bağlamı ve kimliği.
     *
     * @param array<string, mixed> $options
     * @return array<string, mixed>
     */
    private function withRequest(array $options): array
    {
        return $options + ['consent' => $this->consent] + $this->defaults;
    }
}
