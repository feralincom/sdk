# feralin/feralin-laravel

`feralin/feralin-php` üstünde Laravel entegrasyonu: servis sağlayıcı, `FeralinContext` ara katmanı ve `Feralin` facade.

## Durum

| Konu | Durum |
|---|---|
| PHPUnit (Orchestra Testbench) | Geçiyor: PHP 8.3, WSL Ubuntu (`bash scripts/sdk-e2e/php-suite.sh`; Windows'ta `scripts/ci-local.sh --only sdk-php`) |
| Boş Laravel uygulamasına kurulum + gerçek `services/collect` | `node scripts/sdk-e2e/run.mjs php-laravel` ile geçti: `composer create-project laravel/laravel` (Laravel 13), paket keşfi, `vendor:publish`, `config:cache`, ara katman ve facade ile gerçek HTTP isteği; olay `terminate` aşamasında toplayıcıya gitti, outbox'ta doğrulandı |
| Laravel 10, 11, 12 | `composer.json` izin verir; boş uygulama testi yalnız güncel sürümde koştu (`FERALIN_E2E_LARAVEL='^12.0'` ile başka sürüm seçilir) |
| Octane, kuyruk işleri | Sınanmadı |
| Packagist yayını | `BLOCKED_EXTERNAL`: hesap gerekir, yayın yapılmadı |

## Kurulum

Packagist yayını olmadığından Composer iki paketi yerel path deposundan kurar (`symlink: false` gerçek kopya alır):

```bash
# Laravel uygulamanızın dizininde (DEPO: deponun yolu)
composer config repositories.feralin-php '{"type": "path", "url": "DEPO/sdks/php", "options": {"symlink": false}}'
composer config repositories.feralin-laravel '{"type": "path", "url": "DEPO/sdks/php-laravel", "options": {"symlink": false}}'
composer require feralin/feralin-php:0.1.0 feralin/feralin-laravel:0.1.0
php artisan vendor:publish --tag=feralin-config
```

Geliştirme ve testler:

```bash
cd sdks/php-laravel
composer install
composer test
```

## Kullanım

```dotenv
FERALIN_PROJECT_KEY=pk_live_…
FERALIN_COLLECT_URL=https://collect.example.com
```

`config/feralin.php` içinde `'consent_resolver' => App\Feralin\Izin::class`, sonra rota veya grup ara katmanı olarak `Feralin\Laravel\Http\Middleware\FeralinContext` ekleyin.

```php
use Feralin\Consent;
use Feralin\Laravel\ConsentResolver;
use Feralin\Laravel\Facades\Feralin;
use Illuminate\Http\Request;

final class Izin implements ConsentResolver
{
    public function resolve(Request $request): ?Consent
    {
        return new Consent($request->cookie('izin') === 'evet');
    }
}

Feralin::track('order_completed', ['order_id' => 'ord_1']);
```

Laravel çerezleri varsayılan olarak şifreler; izin çerezini istemci tarafı (çerez aracı) yazıyorsa `bootstrap/app.php` içinde `$middleware->encryptCookies(except: ['izin'])` ile şifreleme dışında bırakın.

## İzin

Çözümleyici yoksa, `null` dönerse veya hata atarsa izin yok sayılır, olay üretilmez, istek düşmez. `fr_click` yalnız `advertising === true` iken gider. Anahtar veya adres boşsa entegrasyon kapalıdır; `sk_` anahtar istemci kurulurken reddedilir.

## Veri

IP, User-Agent ve çerez otomatik okunmaz. `page_url` sorgusuz, `referrer` yalnız origin. Yolda kişisel veri varsa `include_context` kapatın. Kuyruk yanıt gönderildikten sonra (`terminate`) boşaltılır.

## Desteklenmeyenler

Kuyruk işlerinde ve konsol komutlarında izin bilinmediği için facade olay üretmez; `Feralin\Client` doğrudan ve olay başına `consent` ile kullanılır. Üstel yeniden deneme uzun süren süreçte geçerlidir; PHP-FPM'de bkz. `sdks/php/README.md`. OTel yoktur. `trackRevenue`, `group`, `setUserProperties` ve `captureError` istek yüzeyinde ince geçiştir: bu isteğin izni ve kimliği eklenir, kurallar `sdks/php/README.md` içindedir; çatının hata işleyicisine otomatik bağlanmaz.
