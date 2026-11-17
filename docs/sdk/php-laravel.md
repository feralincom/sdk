<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Laravel: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/php-laravel/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | PHP |
| Paket | `feralin/feralin-laravel` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/php-laravel` |
| Registry | Packagist: **BLOCKED_EXTERNAL** (gereken: Packagist hesabı ve public Git deposu; feralin/feralin-php yayını) |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `Packagist` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
# Laravel uygulamanızın dizininde (DEPO: deponun yolu)
composer config repositories.feralin-php '{"type": "path", "url": "DEPO/sdks/php", "options": {"symlink": false}}'
composer config repositories.feralin-laravel '{"type": "path", "url": "DEPO/sdks/php-laravel", "options": {"symlink": false}}'
composer require feralin/feralin-php:0.1.0 feralin/feralin-laravel:0.1.0
php artisan vendor:publish --tag=feralin-config
```

```bash
cd sdks/php-laravel
composer install
composer test
```

## İlk kullanım

```dotenv
FERALIN_PROJECT_KEY=pk_live_…
FERALIN_COLLECT_URL=https://collect.example.com
```

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız; gerçek toplayıcıyla sınandı) |
| batch | PARTIAL (bellek içi kuyruk; exportPending ve importPending ile dışarı alınır, kalıcı değil) |
| consent | SUPPORTED (yayınsız; istemci düzeyinde, fr_click reklam iznine bağlı) |
| identity | PARTIAL (yayınsız; identify, reset, group → fr_group, setUserProperties → fr_user_properties, setGlobalProperties/clearGlobalProperties; PHPUnit testli; WSL e2e tüketicisi ve outbox denetimi geçti, kimlik denetim satırları önceden derlenmiş araçla ci-local sdk-php adımında doğrulanır) |
| attribution | N/A |
| deeplink | N/A |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; PHPUnit testli, gerçek toplayıcı e2e yok) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; PHPUnit testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS | composer install (path deposu ../php, orchestra/testbench ile) geçici kopyada kuruldu. |
| test | PASS | PHPUnit 8 test, Laravel 13.42 ve Orchestra Testbench 11.3 üzerinde (PHP 8.3.6, WSL Ubuntu; scripts/sdk-e2e/php-suite.sh). Laravel 10-12 kısıtta, bu koşuda sınanmadı. |
| registry | BLOCKED_EXTERNAL | Packagist hesabı yok. |
| clean_install | PASS | scripts/sdk-e2e/run.mjs php-laravel: composer create-project laravel/laravel (Laravel 13.42, WSL PHP 8.3.6) boş uygulamasına yerel path deposundan (Packagist değil) kuruldu; paket keşfi, vendor:publish ve config:cache geçti. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs php-laravel: PHP yerleşik sunucusunda Laravel ön denetleyicisine gerçek HTTP; FeralinContext ve facade, olay terminate aşamasında gerçek toplayıcıya: izinli olay outbox'ta bir kez, reklam izni yokken fr_click yok, izinsiz istekte olay yok. Octane ve kuyruk işleri sınanmadı. |
| documentation | PASS | docs/sdk/php-laravel.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
