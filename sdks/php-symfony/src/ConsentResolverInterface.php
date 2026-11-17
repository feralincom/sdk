<?php

declare(strict_types=1);

namespace Feralin\Symfony;

use Feralin\Consent;
use Symfony\Component\HttpFoundation\Request;

/** Bu isteğin son kullanıcısının izni. null veya hata: izin yok. */
interface ConsentResolverInterface
{
    public function resolve(Request $request): ?Consent;
}
