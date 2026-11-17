# Feralin PHP SDK

Sunucu tarafından `POST /v1/batch` ucuna UTP v1 olayı gönderen Composer paketi. PHP 8.1 ve üstü, çalışma zamanı bağımlılığı yok. `ext-curl` varsa onu, yoksa PHP akış sarmalayıcısını kullanır.

## Durum

| Konu | Durum |
|---|---|
| `php -l`, PHPUnit | Geçiyor: PHP 8.3, WSL Ubuntu (`bash scripts/sdk-e2e/php-suite.sh`; Windows'ta `scripts/ci-local.sh --only sdk-php` WSL içinde koşar) |
| Temiz kurulum + gerçek `services/collect` (`tests/e2e-consumer.php`) | `node scripts/sdk-e2e/run.mjs php` ile geçti: 202, outbox satırı, izinsiz red, 401, idempotency |
| PHP 8.1 ve 8.2 | `composer.json` izin verir, sınanmadı |
| Packagist yayını | `BLOCKED_EXTERNAL`: hesap gerekir, yayın yapılmadı |

## Kurulum

Packagist yayını olmadığından Composer yerel path deposundan kurar (`symlink: false` gerçek kopya alır):

```bash
# uygulamanızın dizininde (DEPO: deponun yolu)
composer config repositories.feralin-php '{"type": "path", "url": "DEPO/sdks/php", "options": {"symlink": false}}'
composer require "feralin/feralin-php:*@dev"
```

Geliştirme ve testler:

```bash
cd sdks/php
composer install
composer test
```

## Kullanım

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

## Kurallar

Web SDK ile aynıdır: varsayılan `analytics=false`; `fr_click` yalnız `advertising === true` iken gider; anahtar yalnız `x-feralin-project-key` başlığında; `sk_` kurucuda reddedilir; idempotency anahtarı sıralı tüm `event_id` değerlerinin FNV-1a 64 özeti ve sayıdır; `202` ve kalıcı `4xx` kuyruktan siler, `429`, `5xx` ve ağ hatası aynı içerik ve anahtarla denenir; çalışma zamanında hiçbir metot fırlatmaz, yapılandırma hatası kurucuda fırlar.

PHP-FPM'de süreç isteğin sonunda biter. Yanıt kaybolursa bellekteki yeniden deneme olmaz; `exportPending()` çıktısını kalıcı bir yere yazıp sonraki süreçte `importPending()` ile geri alın. WordPress eklentisi bunu WP-Cron ile yapar.

## Kimlik yöntemleri (UTP §8.2)

```php
$feralin->setGlobalProperties(['app_release' => '2.4.0']);            // adı fr_ ile başlamayan her olaya eklenir; null anahtarı siler
$feralin->setUserProperties(['plan' => 'pro'], ['userId' => 'user_42']); // fr_user_properties; geçerli özellik yoksa null
$feralin->group('acme-team', ['plan' => 'team'], ['userId' => 'user_42']); // fr_group; geçersiz group_id → null
$feralin->clearGlobalProperties();
```

Kurallar bütün SDK'larda ve toplayıcıda aynıdır: anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, çağrı başına en çok 50 özellik; değer yalnız dizge (≤256 karakter, kontrol karakteri yok, e-posta biçiminde değil), sonlu sayı ya da mantıksal. Doğrulama alanları (`verified`, `receipt` vb.) ve kişisel veriye benzeyen anahtarlar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) istemcide düşer. Toplayıcı ayrıca projenin özellik izin listesini uygular: listede olmayan anahtar saklanmaz, liste boşsa olay sayılır ama hiçbir özellik saklanmaz. Olayın kendi özelliği aynı anahtardaki globali ezer; global en çok 50 anahtar tutar. `group_id` 1-128 karakterdir, `@` ve kontrol karakteri içeremez.

## Gelir ve hata

```php
// feralin_purchase: tutar küçük birimde tam sayı (49,99 TL → 4999), para birimi ISO 4217; geçersiz girdide null
$feralin->trackRevenue(['transactionId' => 'ord_1', 'amountMinor' => 4999, 'currency' => 'TRY', 'productId' => 'pro'], ['userId' => 'user_42']);

try {
    odemeAl();
} catch (Throwable $error) {
    $feralin->captureError($error, ['userId' => 'user_42']); // fr_error; fırlatmaz
}
```

`trackRevenue` kuralları Web, Node, Python, Go ve .NET SDK'larıyla aynıdır: `transactionId` 1-128, `amountMinor` 0..2^53-1 tam sayı (ondalık yok, `quantity` ile çarpılmaz), `quantity` 0-100000 (varsayılan 1), `purchaseType` `purchase|subscription_start|subscription_renew|subscription_cancel` (iptalde tutar 0), isteğe bağlı `receipt` (`apple|google|stripe`). İstemci beyanıdır, `verified` hiçbir zaman gönderilmez; satır yalnız sunucu makbuz doğrulayıcısı onaylarsa `REAL_VERIFIED` olur. SDK sözleşmesinde iade olayı yoktur.

`captureError` Android SDK'sıyla aynı `fr_error` gövdesini üretir: hata sınıfı adı, e-posta/URL/UUID/belirteç/uzun sayı temizlenmiş en çok 200 karakterlik mesaj, ilk beş uygulama çerçevesinin (`vendor/` dışı) SHA-256 parmak izi, üst çerçeve (`Sınıf.yöntem`) ve en çok 5 konum (yalnız dosya taban adı, satır, işlev). Ham yığın izi, dizin yolu ve bağımsız değişken değerleri gitmez. 60 saniyede en çok 20 olay, aynı parmak izi için en çok 3; `errorSampleRate` ve `appVersion` kurucu seçenekleridir. `origin`: `handled` (varsayılan), `manual`, `uncaught_exception`.

Bilinçli eksik: OTel.
