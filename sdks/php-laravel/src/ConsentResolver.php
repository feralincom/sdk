<?php

declare(strict_types=1);

namespace Feralin\Laravel;

use Feralin\Consent;
use Illuminate\Http\Request;

/** Bu isteğin son kullanıcısının izni. null veya hata: izin yok. */
interface ConsentResolver
{
    public function resolve(Request $request): ?Consent;
}
