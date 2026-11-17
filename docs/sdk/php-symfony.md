<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Symfony: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/php-symfony/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | PHP |
| Paket | `feralin/feralin-symfony` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/php-symfony` |
| Registry | Packagist: **BLOCKED_EXTERNAL** (gereken: Packagist hesabı ve public Git deposu; feralin/feralin-php yayını) |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `Packagist` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
# Symfony uygulamanızın dizininde (DEPO: deponun yolu)
composer config repositories.feralin-php '{"type": "path", "url": "DEPO/sdks/php", "options": {"symlink": false}}'
composer config repositories.feralin-symfony '{"type": "path", "url": "DEPO/sdks/php-symfony", "options": {"symlink": false}}'
composer require feralin/feralin-php:0.1.0 feralin/feralin-symfony:0.1.0
```

```bash
cd sdks/php-symfony
composer install
composer test
```

## İlk kullanım

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
| build | PASS | composer install (path deposu ../php, symfony 6.4/7 bileşenleri) geçici kopyada kuruldu. |
| test | PASS | PHPUnit 7 test, Symfony 7.4 bileşenleri üzerinde (PHP 8.3.6, WSL Ubuntu; scripts/sdk-e2e/php-suite.sh). Symfony 6.4 kısıtta, bu koşuda sınanmadı; Symfony 8 kısıt dışı (PHP 8.4 ister). |
| registry | BLOCKED_EXTERNAL | Packagist hesabı yok. |
| clean_install | PASS | scripts/sdk-e2e/run.mjs php-symfony: composer create-project symfony/skeleton 7.4 (http-kernel 7.4.23, WSL PHP 8.3.6) boş uygulamasına yerel path deposundan (Packagist değil) kuruldu; Flex paketi bundles.php'ye eklemedi, README'deki gibi elle eklendi; prod kabı derlendi. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs php-symfony: prod ortamında PHP yerleşik sunucusuna gerçek HTTP; RequestFeralin argümanı, olay kernel.terminate aşamasında gerçek toplayıcıya: izinli olay outbox'ta bir kez, reklam izni yokken fr_click yok, izinsiz istekte olay yok. Messenger ve konsol sınanmadı. |
| documentation | PASS | docs/sdk/php-symfony.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
