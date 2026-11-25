<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# PHP: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/php/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | PHP |
| Paket | `feralin/feralin-php` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | REGISTRY_VERIFIED |
| Kaynak dizin | `sdks/php` |
| Registry | Packagist: **PUBLISHED** (sonraki adım: Packagist hesabı ve public Git deposu) |

## Kurulum

```bash
# uygulamanızın dizininde (DEPO: deponun yolu)
composer config repositories.feralin-php '{"type": "path", "url": "DEPO/sdks/php", "options": {"symlink": false}}'
composer require "feralin/feralin-php:*@dev"
```

```bash
cd sdks/php
composer install
composer test
```

## İlk kullanım

```php
use Feralin\Client;
use Feralin\Consent;

$feralin = new Client(getenv('FERALIN_PROJECT_KEY'), 'https://collect.example.com');

// İzin kararı son kullanıcınındır; uygulamadan olay başına geçirilir.
$feralin->track('order_completed', ['order_id' => 'ord_1', 'fr_click' => $click], [
    'userId' => 'user_42',
    'consent' => new Consent(analytics: true, advertising: $reklamIzni),
]);
// İstek sonunda bekleyen olaylar otomatik gönderilir; uzun süren işçide flush() çağırın.
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
| build | PASS | composer install (path deposu, symlink'siz kopya) çalışma zamanı bağımlılığı olmadan autoload üretti. |
| test | PASS | PHPUnit 10.5, 16 test (PHP 8.3.6, WSL Ubuntu 24.04; scripts/sdk-e2e/php-suite.sh). Windows'ta PHP yok. |
| registry | PASS | Packagist'te yayımlandı: feralin/feralin-php:0.1.0 (19 Kasım 2026; ayrı depo github.com/feralincom/feralin-php, etiket v0.1.0, commit 4f77d27; Packagist hesabı GitHub ile). Geri okuma: repo.packagist.org/p2/feralin/feralin-php.json sürüm 0.1.0, kaynak etiketli GitHub zipball. Composer ile temiz kurulum bu makinede koşulmadı (composer yok). Otomatik güncelleme kancası kurulmadı: yeni sürümde Packagist paket sayfasında Update. |
| clean_install | PASS | Composer path deposundan boş tüketiciye kuruldu; yalnız feralin/feralin-php, çalışma zamanı bağımlılığı yok. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs php (gerçek toplayıcı, WSL): 202=6 ve 401=1, outbox'ta 7 satır doğrulandı; fr_click izne bağlı, izinsiz SDK olay üretmez, idempotency. |
| documentation | PASS | docs/sdk/php.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
