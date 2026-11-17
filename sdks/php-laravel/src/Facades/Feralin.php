<?php

declare(strict_types=1);

namespace Feralin\Laravel\Facades;

use Feralin\Laravel\RequestFeralin;
use Illuminate\Support\Facades\Facade;

/**
 * @method static array|null track(string $eventName, array $properties = [], array $options = [])
 * @method static array|null trackRevenue(array $revenue, array $options = [])
 * @method static array|null group(string $groupId, array $traits = [], array $options = [])
 * @method static array|null setUserProperties(array $properties, array $options = [])
 * @method static array|null captureError(\Throwable $error, array $options = [])
 * @method static \Feralin\FlushResult|null flush()
 */
final class Feralin extends Facade
{
    /** Önbellek kapalı: Octane'de önceki isteğin izni facade üzerinde kalmasın. */
    protected static $cached = false;

    protected static function getFacadeAccessor(): string
    {
        return RequestFeralin::class;
    }
}
