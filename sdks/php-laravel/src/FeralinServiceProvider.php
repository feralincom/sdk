<?php

declare(strict_types=1);

namespace Feralin\Laravel;

use Feralin\Client;
use Feralin\Consent;
use Illuminate\Contracts\Foundation\Application;
use Illuminate\Support\ServiceProvider;

final class FeralinServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->mergeConfigFrom(__DIR__ . '/../config/feralin.php', 'feralin');

        // Ayar closure'lar içinde okunur: testler ve config:cache kayıt sırasına bağlı kalmaz.
        $this->app->singleton(Client::class, static function (): Client {
            // sk_ anahtar ve geçersiz adres burada InvalidArgumentException atar.
            return new Client((string) config('feralin.project_key'), (string) config('feralin.collect_url'), (array) config('feralin.client', []));
        });

        $this->app->singleton(RequestFeralinFactory::class, static function (Application $app): RequestFeralinFactory {
            $consent = config('feralin.consent_resolver');
            $identity = config('feralin.identity_resolver');
            return new RequestFeralinFactory(
                self::enabled() ? $app->make(Client::class) : null,
                is_string($consent) ? $app->make($consent) : null,
                is_string($identity) ? $app->make($identity) : null,
                (bool) config('feralin.include_context', true),
            );
        });

        // Ara katman çalışmadıysa (konsol komutu, kuyruk işi) olay üretmeyen yüzey: izin bilinmiyor.
        $this->app->bind(RequestFeralin::class, static fn (Application $app): RequestFeralin => new RequestFeralin(
            self::enabled() ? $app->make(Client::class) : null,
            new Consent(false),
        ));
    }

    public function boot(): void
    {
        $this->publishes([__DIR__ . '/../config/feralin.php' => $this->app->configPath('feralin.php')], 'feralin-config');
    }

    private static function enabled(): bool
    {
        $key = config('feralin.project_key');
        $url = config('feralin.collect_url');
        return is_string($key) && $key !== '' && is_string($url) && $url !== '';
    }
}
