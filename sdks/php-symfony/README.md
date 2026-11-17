# feralin/feralin-symfony

`feralin/feralin-php` üstünde Symfony paketi: yapılandırma, istek olay dinleyicisi ve `RequestFeralin` denetleyici argümanı.

## Durum

| Konu | Durum |
|---|---|
| PHPUnit | Geçiyor: PHP 8.3, WSL Ubuntu (`bash scripts/sdk-e2e/php-suite.sh`; Windows'ta `scripts/ci-local.sh --only sdk-php`) |
| Boş Symfony uygulamasına kurulum + gerçek `services/collect` | `node scripts/sdk-e2e/run.mjs php-symfony` ile geçti: `composer create-project symfony/skeleton` (7.4 LTS), `bundles.php`, `config/packages/feralin.yaml`, çözümleyici servisi, prod kabı ve `RequestFeralin` argümanıyla gerçek HTTP isteği; olay `kernel.terminate` aşamasında toplayıcıya gitti, outbox'ta doğrulandı |
| Symfony 6.4 | `composer.json` izin verir; boş uygulama testi koşmadı (`FERALIN_E2E_SYMFONY='6.4.*'` ile seçilir) |
| Symfony 8 | Desteklenmiyor: paket kısıtı `^6.4 \|\| ^7.0`; Symfony 8 PHP 8.4 ister, test makinesinde PHP 8.3 var |
| Packagist yayını | `BLOCKED_EXTERNAL`: hesap gerekir, yayın yapılmadı |

## Kurulum

Packagist yayını olmadığından Composer iki paketi yerel path deposundan kurar (`symlink: false` gerçek kopya alır):

```bash
# Symfony uygulamanızın dizininde (DEPO: deponun yolu)
composer config repositories.feralin-php '{"type": "path", "url": "DEPO/sdks/php", "options": {"symlink": false}}'
composer config repositories.feralin-symfony '{"type": "path", "url": "DEPO/sdks/php-symfony", "options": {"symlink": false}}'
composer require feralin/feralin-php:0.1.0 feralin/feralin-symfony:0.1.0
```

Geliştirme ve testler:

```bash
cd sdks/php-symfony
composer install
composer test
```

## Kullanım

`config/bundles.php` içine `Feralin\Symfony\FeralinBundle::class => ['all' => true]` ekleyin: paketin Symfony Flex tarifi yoktur, Flex otomatik eklemez (boş uygulama testinde de elle eklendi).

```yaml
# config/packages/feralin.yaml
feralin:
    project_key: '%env(FERALIN_PROJECT_KEY)%' # yalnız pk_ anahtarı
    collect_url: '%env(FERALIN_COLLECT_URL)%'
    consent_resolver: App\Feralin\Izin
```

```php
use Feralin\Consent;
use Feralin\Symfony\ConsentResolverInterface;
use Feralin\Symfony\RequestFeralin;
use Symfony\Component\HttpFoundation\Request;

final class Izin implements ConsentResolverInterface
{
    public function resolve(Request $request): ?Consent
    {
        return new Consent($request->cookies->get('izin') === 'evet');
    }
}

public function siparis(RequestFeralin $feralin): Response
{
    $feralin->track('order_completed', ['order_id' => 'ord_1']);
    return new Response(status: 201);
}
```

## İzin

Çözümleyici yoksa, `null` dönerse veya hata atarsa izin yok sayılır, olay üretilmez, istek düşmez. `fr_click` yalnız `advertising === true` iken gider. `sk_` anahtar istemci kurulurken reddedilir.

## Veri

IP, User-Agent ve çerez otomatik okunmaz. `page_url` sorgusuz, `referrer` yalnız origin. Yolda kişisel veri varsa `include_context: false` verin. Kuyruk `kernel.terminate` olayında boşaltılır.

## Desteklenmeyenler

Messenger işlerinde ve konsol komutlarında istek yüzeyi yoktur; `Feralin\Client` doğrudan ve olay başına `consent` ile kullanılır. Üstel yeniden deneme uzun süren süreçte geçerlidir; PHP-FPM'de bkz. `sdks/php/README.md`. OTel yoktur. `trackRevenue`, `group`, `setUserProperties` ve `captureError` istek yüzeyinde ince geçiştir: bu isteğin izni ve kimliği eklenir, kurallar `sdks/php/README.md` içindedir; çatının hata işleyicisine otomatik bağlanmaz.
