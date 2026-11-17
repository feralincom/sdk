<?php

declare(strict_types=1);

namespace Feralin\Laravel;

use Illuminate\Http\Request;

/** Uygulamanın kendi kimlikleri. E-posta veya telefon döndürmeyin. */
interface IdentityResolver
{
    /** @return array{userId?: string, anonymousId?: string, sessionId?: string} */
    public function resolve(Request $request): array;
}
