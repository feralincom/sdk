<?php

declare(strict_types=1);

namespace Feralin\Laravel\Http\Middleware;

use Closure;
use Feralin\Laravel\RequestFeralin;
use Feralin\Laravel\RequestFeralinFactory;
use Illuminate\Contracts\Container\Container;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;
use Throwable;

/** İstek yüzeyini kapsayıcıya bağlar; yanıt gönderildikten sonra kuyruğu boşaltır (Octane'de süreç bitmediği için gerekir). */
final class FeralinContext
{
    public function __construct(
        private readonly Container $container,
        private readonly RequestFeralinFactory $factory,
    ) {
    }

    public function handle(Request $request, Closure $next): Response
    {
        $this->container->instance(RequestFeralin::class, $this->factory->forRequest($request));
        return $next($request);
    }

    public function terminate(Request $request, Response $response): void
    {
        try {
            // Anahtar veya adres boşsa entegrasyon kapalıdır: yüzeyin istemcisi yoktur, flush bir şey yapmaz.
            $this->container->make(RequestFeralin::class)->flush();
        } catch (Throwable) {
            // Yanıt gönderildi; sk_ gibi yapılandırma hatası handle aşamasında zaten görünür oldu, burada tekrar fırlatılmaz.
        } finally {
            // Octane: sonraki isteğe bu kullanıcının izni kalmasın.
            $this->container->forgetInstance(RequestFeralin::class);
        }
    }
}
